#!/usr/bin/env bash
# ChuanqiCut — 改动 → 窄检路由（INFRA-043，ADR-0046 决定 4）
#
# 要解决的问题：**开发会话跑全量是因为不知道该跑什么**。门禁 18 步、跨 4 套配置树、
# 6 个 SPM 包 + 2 个 Pod，而"改了 X 该验 Y"只存在于老手脑子里（P78：合并后 P1 分派
# 从未编译过；P129：macOS 的 swift test 整文件跳过 #if os(iOS)）。没有路由，
# 保守的人就全跑 —— 一趟 7 分钟，一天十几次。
#
# 三条硬约束（写在行为里，不只是写在注释里）：
#   1. **只读**：本脚本不跑任何构建/测试，只打印该跑的命令。跑不跑由人决定，
#      账由 run_gate.sh 记 —— 这样才敢在任意脏工作树状态下随手调它。
#   2. **判不准一律升一档**：命中规则之外的任何文件 → 建议全量（L3）。
#      漏跑一次的代价（坏代码进 main）远大于多跑一趟窄检。
#   3. **每条规则带案底**：`Pxx / ADR / 红线` 指回它为什么在这档，防下一个人"看着多余就删"。
#
# 用法：
#   tools/ci/gate_scope.sh                      # 路由工作树相对 HEAD 的改动（含未跟踪文件）
#   tools/ci/gate_scope.sh --range=HEAD~3..HEAD # 合并快检：路由刚拉进来的那几个提交
#   tools/ci/gate_scope.sh --files a.cpp b.mm   # 手工给清单（建卡前先问一版射程）
#
# 退出码恒 0（参数错误除外）。它是建议器不是门禁 —— 让它非零会让人去改**判据**
# 而不是改自己的行为，那是 P163 那类"判据把自己判红"的起点。
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR" || exit 0

RANGE=""
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --range=*) RANGE="${1#*=}" ;;
        --files)
            shift
            while [ $# -gt 0 ]; do FILES+=("$1"); shift; done
            continue ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
    shift
done

CHANGED=()
# **必须用 -z**：git 默认 core.quotepath=true，非 ASCII 路径会回成
# "docs/decisions/ADR-0046-\347\211\210..." 这种带引号的八进制串 → 每条 `docs/*` 模式
# 都不匹配 → 路由**假阴**，判成"未归类 → 跑全量"。本仓 ADR/任务卡文件名全是中文，
# 第一次自测就撞上了（7 个中文文件里 2 个漏归类）。用 NUL 分隔 + read -d '' 才是稳的。
git_paths() {  # $@ = 传给 git diff/ls-files 的参数
    git -c core.quotepath=off "$@" 2>/dev/null
}
if [ "${#FILES[@]}" -gt 0 ]; then
    CHANGED=("${FILES[@]}")
elif [ -n "${RANGE}" ]; then
    while IFS= read -r -d '' f; do [ -n "$f" ] && CHANGED+=("$f"); done < <(git_paths diff --name-only -z "$RANGE")
else
    # 已跟踪改动 **+ 未跟踪新文件**。漏掉未跟踪 = 路由说"只改了文档"，
    # 而那个新文件其实从没编译过 —— P78 的形状，所以两趟都要。
    while IFS= read -r -d '' f; do [ -n "$f" ] && CHANGED+=("$f"); done < \
        <(git_paths diff --name-only -z HEAD; git_paths ls-files --others --exclude-standard -z)
fi

if [ "${#CHANGED[@]}" -eq 0 ]; then
    echo "gate_scope: 工作树相对 HEAD 无改动 → 无需验证。"
    exit 0
fi

CMDS=(); REASONS=(); TAGS=(); UNCLASSIFIED=()
NEED_FULL=0
# 区分两种升档原因：① 规则**自己**要求全量（如 R12 改全库风格基线）；② 兜底发现有文件
# 没有任何规则覆盖。②才需要"把路径加进规则里"这句提醒——混在一起会让读日志的人去修一个
# 已经正确的路由（R12 落地当天实测：未归类清单空了，脚本却照旧打印那句提醒）。
UNCLASSIFIED_FULL=0

tag()     { TAGS+=("$1"); }
add_why() { REASONS+=("$1"); }

# add_cmd 去重：R1/R2/R7/R8/R10 会各自要求"跑 Debug 档"，原样列出来是 5 条同一行 ——
# 看着像要跑 5 遍，实际是 1 遍。清单要能直接当 checklist 用，重复即噪音。
# （bash 3.2 无关联数组，只能线性查；清单长度是个位数。）
add_cmd() {
    local c="$1" e
    for e in ${CMDS[@]+"${CMDS[@]}"}; do
        [ "$e" = "$c" ] && return 0
    done
    CMDS+=("$c")
}

# 命中某路径前缀（case 的 * 在 bash 模式匹配里**跨 /**，所以 engine/* 覆盖整棵子树）
hits() {
    local pat="$1" f
    for f in "${CHANGED[@]}"; do
        # shellcheck disable=SC2254  # pat 必须是裸的才会做模式匹配
        case "$f" in ${pat}) return 0 ;; esac
    done
    return 1
}

# ---- R1 内核 CMake 图 / 公共 ABI 头 ----
if hits 'CMakeLists.txt' || hits 'cmake/*' || hits 'engine/core/cq/cq_sdk.h'; then
    tag R1
    add_cmd 'tools/build/build_core.sh --platform=apple --config=Debug --test --skip-label=heavy'
    add_cmd 'python3 tools/docs/gen_api_reference.py --check'
    add_why 'R1 动了 CMake 图或 ABI 头 → Debug 档 ctest + api-doc 判据（P151：公共接口参考曾在两个批次里过期 4 天）'
fi

# ---- R2 内核实现 / 其单测 ----
if hits 'engine/core/*' || hits 'tests/*'; then
    tag R2
    add_cmd 'tools/build/build_core.sh --platform=apple --config=Debug --test --skip-label=heavy'
    # heavy 14 例**只在 Release 跑**（ADR-0046 决定 3）→ 动了内核就必须补这一条，
    # 否则"窄检全绿"会变成媒体链路从未被验过的遮羞布。
    add_cmd 'tools/build/build_core.sh --platform=apple --config=Release --test'
    add_why 'R2 动了内核或其单测 → Debug 跑纯 CPU 档（跳 heavy）+ Release 跑全例（heavy 的唯一覆盖点）；例数以 ctest 日志为准，别抄脚本里的数'
fi

# ---- R3 Apple 平台层 / Swift 绑定 ----
if hits 'engine/platform/*' || hits 'api/swift/*'; then
    tag R3
    add_cmd 'tools/ci/check_ios_compile.sh --prime --config=Release'
    add_cmd "(cd api/swift && swift test --disable-sandbox --scratch-path '${ROOT_DIR}/build/spm/bindings')"
    add_why 'R3 动了 Apple 平台层/绑定 → iOS 切片真编译（P129：本机 macOS 的 swift test 整文件跳过 #if os(iOS)，SPM 全绿不是 UIKit 证据）'
fi

# ---- R4 SPM 包（ui/ 六包，逐包只跑自己）----
# **无 Tests 目标的包只能 `swift build`**：`swift test` 在这类包上是 rc=1 真失败
# （实测 ui/ChuanqiCutDraft：`error: no tests found; create a target in the 'Tests' directory`），
# 不是"没有用例所以通过"。判"某包该跑 build 还是 test"要对着包目录看有没有 Tests，别按包名猜。
CQ_BUILD_ONLY_PKGS="SharedUI ChuanqiCutDraft"
for pkg in SharedUI ChuanqiCutPlayer ChuanqiCutCamera ChuanqiCutImport ChuanqiCutEditor ChuanqiCutDraft; do
    if hits "ui/${pkg}/*"; then
        tag "R4:${pkg}"
        case " ${CQ_BUILD_ONLY_PKGS} " in
            *" ${pkg} "*) act='swift build' ;;
            *)           act='swift test' ;;
        esac
        add_cmd "(cd ui/${pkg} && ${act} --disable-sandbox --scratch-path '${ROOT_DIR}/build/spm/${pkg}')"
        add_why "R4 动了 ui/${pkg} → 只跑该包（其它包不因它变红，ADR-0031 分治）"
    fi
done

# ---- R5 Pod 接线 / 壳工程 → 双壳必须真编 ----
if hits '*.podspec' || hits 'apps/*' || hits 'Podfile*'; then
    tag R5
    add_cmd 'tools/ci/check_apple_shells.sh'
    add_why 'R5 动了 podspec/壳工程 → 双壳真编译（P150：source_files 写成仓库根相对时 CocoaPods **静默丢全部源码**，pod install exit 0 不算证据；pbxproj 已入库 ADR-0037，裸改也只有真编能抓）'
fi

# ---- R6 shader ----
if hits 'engine/shaders/*'; then
    tag R6
    add_cmd 'tools/build/build_shader_toolchain.sh'
    add_cmd 'tools/build/build_core_apple.sh --config=Release'
    add_why 'R6 动了 shader → Portable 层重编 + xcframework（红线 #6；生成产物不得入库，P96）'
fi

# ---- R7 依赖治理 ----
if hits 'third_party/*' || hits 'engine/vendor/*' || hits 'tools/deps/*'; then
    tag R7
    add_cmd 'python3 tools/deps/deps.py validate third_party/manifest.toml'
    add_cmd 'tools/build/build_core.sh --platform=apple --config=Debug --test --skip-label=heavy'
    add_why 'R7 动了依赖 → manifest 校验 + 装配面（红线 #10；跑法见 cq-dependency-governance）'
fi

# ---- R8 门禁/判据脚本自身 ----
if hits 'tools/ci/*' || hits 'tools/build/*' || hits 'tools/compliance/*' || hits 'tools/platform/*' || hits 'tools/qa/*'; then
    tag R8
    add_cmd 'bash -n tools/ci/run_gate.sh'
    add_cmd 'tools/ci/check_repo_hygiene.sh'
    add_cmd 'tools/ci/run_gate.sh --fast --batch=<本卡 ID>'
    add_why 'R8 动了门禁本身 → 改动后的脚本必须真跑一趟（P170：write_report() 里一个 return 让 tsv 静默不再追加，只跑"被记账的东西"就永远看不见它）'
fi

# ---- R9 真源与生成物 ----
if hits '.ai/source/*' || hits 'AGENTS.md' || hits 'CLAUDE.md' || hits '.cursorrules' || hits '.windsurfrules' || hits '.github/copilot-instructions.md'; then
    tag R9
    add_cmd 'python3 tools/ai/sync_context.py'
    add_cmd 'python3 tools/ai/linkcheck_docs.py'
    add_why 'R9 动了真源 → 重生成 5 份入口 + 链接判据（生成物禁止手改）'
fi

# ---- R10 CI 定义（本机不复现，只能静态核 + 同口径比对）----
if hits '.github/workflows/*'; then
    tag R10
    add_cmd 'python3 -c "import yaml,sys; yaml.safe_load(open(\x27.github/workflows/ci.yml\x27))" 2>/dev/null || echo "（本机无 PyYAML → 肉眼核缩进）"'
    add_cmd 'tools/build/build_core.sh --platform=apple --config=Debug --test --skip-label=heavy'
    add_why 'R10 动了 CI → 与本地同口径核对（口径差：CI 的 FFmpeg 装配步本机从不复现，功能面证据是 ctest 用例 media_ffmpeg_probe）'
fi

# ---- R11 纯文档 / 版本账 ----
if [ "${#TAGS[@]}" -eq 0 ]; then
    if hits 'docs/*' || hits '*.md' || hits 'VERSION' || hits 'docs/reports/VERSIONS.md'; then
        tag R11
        add_cmd 'python3 tools/ai/linkcheck_docs.py'
        add_cmd 'tools/ci/check_repo_hygiene.sh'
        add_why 'R11 纯文档/版本账 → 链接 + 卫生判据，**不碰编译器**'
    fi
fi

# ---- R12 根目录风格配置（射程 = 全库 C/C++，不属任何模块窄检）----
# 位置要求：必须在 R11 **之后** —— R11 的前提是"没有任何其它规则命中"，把 R12 放它前面
# 会让「文档 + 风格配置」同批的 diff 丢掉 linkcheck（run_gate.sh 里没有这一步，只有 CI 有）。
if hits '.clang-format' || hits '.editorconfig'; then
    tag R12
    add_cmd 'tools/ci/check_repo_hygiene.sh'
    add_cmd 'tools/ci/run_gate.sh --batch=<本卡 ID>'
    add_why 'R12 改了全库风格基线 → 判据 1（editorconfig 四条件）与判据 4（clang-format 违规数）**对全库重新生效**，存量违规要么一次重排、要么在 `.clang-format` 头部声明。升档不降级：这是唯一能改出 100+ 文件 diff 的非功能开关（INFRA-046 一趟重排 113 个文件）；P176：`clang-format -i` 会把符号链接换成普通文件，跑完必须 `git diff --summary` 查 mode change'
    NEED_FULL=1
fi

# ---- 兜底：任何未被上面任何规则覆盖的文件 → 升一档 ----
for f in "${CHANGED[@]}"; do
    covered=0
    for pat in 'CMakeLists.txt' 'VERSION' 'cmake/*' 'engine/*' 'tests/*' 'ui/*' 'api/*' 'apps/*' \
               'tools/*' 'docs/*' '.ai/*' 'third_party/*' '.github/*' '*.md' '*.podspec' 'Podfile*' \
               '.clang-format' '.editorconfig'; do
        # shellcheck disable=SC2254
        case "$f" in ${pat}) covered=1; break ;; esac
    done
    [ "${covered}" -eq 0 ] && UNCLASSIFIED+=("$f")
done
[ "${#UNCLASSIFIED[@]}" -gt 0 ] && { NEED_FULL=1; UNCLASSIFIED_FULL=1; }

TIER='L1/L2 窄检'
[ "${NEED_FULL}" -eq 1 ] && TIER='L3 全量（规则主动要求）'
[ "${UNCLASSIFIED_FULL}" -eq 1 ] && TIER='L3 全量（判不准升档）'
echo "== gate_scope：改动 ${#CHANGED[@]} 个文件 → 档位 ${TIER} =="
[ "${#TAGS[@]}" -gt 0 ] && echo " 命中规则：$(printf '%s ' "${TAGS[@]}")"
echo ""
if [ "${#CMDS[@]}" -gt 0 ]; then
    echo "该跑（按序，逐条可复制）："
    printf '  %s\n' "${CMDS[@]}"
else
    echo "该跑：没有匹配到任何规则 → 见下方兜底"
fi
echo ""
echo "为什么是这一档（各条规则的案底）："
[ "${#REASONS[@]}" -gt 0 ] && printf '  - %s\n' "${REASONS[@]}"
if [ "${NEED_FULL}" -eq 1 ]; then
    echo ""
    if [ "${UNCLASSIFIED_FULL}" -eq 1 ]; then
        printf ' ⚠️ 未归类的改动：\n'
        printf '     %s\n' "${UNCLASSIFIED[@]}"
        echo "   → 本趟跑全量：tools/ci/run_gate.sh --batch=<本卡 ID>"
        echo "   并把该路径加进本脚本的规则里（判不准升一档 = ADR-0046 决定 4；出现新形状不回填 = 路由开始说谎）"
    else
        echo " ⚠️ 本趟跑全量：tools/ci/run_gate.sh --batch=<本卡 ID>（由上面某条规则**主动**要求，不是没归类）"
    fi
else
    echo ""
    echo " → 全量（L3）**不在**上面的清单里：一个版本号一趟，见 docs/reports/VERSIONS.md §一"
fi
exit 0
