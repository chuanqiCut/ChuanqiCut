#!/usr/bin/env bash
# ChuanqiCut — 本机总门禁（INFRA-010，2026-10-05）
#
# 场景：其他开发机代码合并后的守门（cq-code-review 流程 A）、本机提交前自审（流程 B）。
# 原则：**门禁口径以本机为准** —— 远端"已验证"一律按未验证处理，全量在本机重跑。
#
# 检查项（按序执行，任一失败立即非零退出 = 一票否决）：
#   1. deps      依赖治理 manifest 校验（需 Python >= 3.11 / tomllib）
#   2. headers   Platform/公共头纯净性（tools/platform/check_platform_headers.py）
#   2b. hygiene  仓库卫生（tools/ci/check_repo_hygiene.sh：忽略锚定 / 旧路径 / 产物入库 / editorconfig /
#                源码树内未忽略产物目录；P84 的"产物不得入库"内联检查已并入此处，判据只留一份）
#   2c. layer-hygiene Apple 端 UIView 图层卫生（P131：禁清空 backing layer 的 sublayers）
#   2d. api-doc  公共接口参考未过期（gen_api_reference.py --check，P151：曾在 AIEDIT/AUDIO 批次里过期 4 天）
#   2e. ios-compile iOS 切片"只编译"窄检（tools/ci/check_ios_compile.sh，P146：
#                #if TARGET_OS_IPHONE 分支在 macOS 切片里从不参与编译）
#   3. core-dbg  内核 Debug 构建 + 全量单测（-Werror）
#   4. core-rel  内核 Release 构建 + 全量单测（-Werror + LTO）
#   5. apple     XCFramework 三切片 + Swift 绑定测试 + SharedUI/功能 Pod 测试
#   6. apple-shells 双 App 壳构建（tools/ci/check_apple_shells.sh，INFRA-037 收池 [18]：
#                用 App 自己的 workspace 真编一次，podspec/Pbxproj/门面接线坏了会在这里红）
#   7. golden    golden 样本齐备性（tests/golden/verify.py）
#
# 用法：
#   tools/ci/run_gate.sh                 # 全量（默认）
#   tools/ci/run_gate.sh --fast          # 快速档：跳过 4，以及 5/6 整个 Apple 组
#   tools/ci/run_gate.sh --skip-apple    # 跳过 5/6（XCFramework + Swift + SharedUI + 双壳）
#   PYTHON_BIN=/path/to/python3 tools/ci/run_gate.sh   # 指定 Python >= 3.11
#
# 报告：每步日志落 build/gate-logs/<step>.log；结尾打印门禁摘要（含 ctest 数字）。
#   ⚠️ 摘要**只来自本次运行记账**（SUMMARY 数组），不读日志文件——上一版 print_summary()
#   靠 `[ -f log ]` 遍历同名日志，被 kill 的那一趟会把**上一次遗留**的数字当本次结果念出去
#   （P145）。开跑即清空 gate-logs/*.log + 每步起始处截断，双保险。

set -u
PIPESTATUS_OK=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
LOG_DIR="$ROOT_DIR/build/gate-logs"
mkdir -p "$LOG_DIR"
rm -f "${LOG_DIR}"/*.log

FAST=0
SKIP_APPLE=0
for arg in "$@"; do
    case "$arg" in
        --fast)       FAST=1; SKIP_APPLE=1 ;;
        --skip-apple) SKIP_APPLE=1 ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; SKIP=0
SUMMARY=()
DURATIONS=()
# 每步耗时入账（P166：串行时代只有墙钟总数，"哪一步贵"全靠 mtime 反推 → 猜错过一次）。
# 口径：整数秒、含步骤自身的等待；SKIP 不计时（恒 0）。
GATE_T0="$(date +%s)"

# 摘要行 = 步骤的唯一出口：记一次账，念一次账。行数恒等于 PASS+FAIL+SKIP。
record() {
    local status="$1" name="$2" note="${3:-}"
    SUMMARY+=("$(printf ' %-5s %-22s %s' "${status}" "${name}" "${note}")")
    case "${status}" in
        PASS) PASS=$((PASS + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
        SKIP) SKIP=$((SKIP + 1)) ;;
    esac
}

# 从步骤日志里提一行摘要（本次日志，已截断过；提不出来就留空，不猜）。
digest() {
    local name="$1" log="${LOG_DIR}/${name}.log"
    [ -f "${log}" ] || return 0
    case "${name}" in
        core-dbg|core-rel) grep -hE '[0-9]+% tests passed' "${log}" | tail -1 ;;
        # 取 "Executed N tests, with M failures" 这行而不是 "Test Suite ... passed at <时间戳>"：
        # 前者是数字（摘要要的是数字），后者只有时间戳。失败时同一行会变成 "with M failures"。
        apple-*) grep -hE 'Executed [0-9]+ tests, with' "${log}" | tail -1 ;;
    esac
    return 0
}

# 每趟落两份报告，都在 gitignored 的 `build/gate-logs/` 里（不进仓库、不脏工作树）：
#   gate-summary.md  = 本次运行的完整报告（每趟覆盖，供复制进模块册）
#   gate-history.tsv = 每趟一行墙钟账（追加，跨趟看趋势；跑一百趟也就几十 KB）
# ⚠️ 故意不写进 `.ai/memory/baselines.md`：门禁自写已跟踪文档 = 每跑一趟就把工作树弄脏，
#    而且会绕过全局册单写者的人工核数字环节（P160 那类"暖缓存冒充绿"就是靠这一环挡住的）。
write_report() {
    local total="$1" sum="$2" tier="全量"
    [ "${FAST}" -eq 1 ] && tier="--fast"
    # --skip-apple 只跳 Apple 组、仍跑双配置内核与 ctest，与"全量"不是一档，
    # 混记会让跨趟趋势看不出这趟少跑了七步。
    [ "${FAST}" -eq 0 ] && [ "${SKIP_APPLE}" -eq 1 ] && tier="--skip-apple"
    {
        echo "# 门禁报告 $(date '+%Y-%m-%d %H:%M:%S')（档位=${tier}）"
        echo ""
        echo "- PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}｜行数=${#SUMMARY[@]}｜墙钟=${total}s｜已计时合计=${sum}s"
        echo ""
        printf '%s\n' '```'
        [ "${#SUMMARY[@]}" -gt 0 ] && printf '%s\n' "${SUMMARY[@]}"
        printf '%s\n' '```'
    } >"${LOG_DIR}/gate-summary.md"
    [ -f "${LOG_DIR}/gate-history.tsv" ] || \
        printf 'date\ttime\ttier\tpass\tfail\tskip\tsteps\twall_s\ttimed_s\n' >"${LOG_DIR}/gate-history.tsv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%d')" "$(date '+%H:%M:%S')" "${tier}" \
        "${PASS}" "${FAIL}" "${SKIP}" "${#SUMMARY[@]}" "${total}" "${sum}" \
        >>"${LOG_DIR}/gate-history.tsv"
    echo " 报告：${LOG_DIR}/gate-summary.md（跨趟趋势：${LOG_DIR}/gate-history.tsv）"
    return 0
}

print_summary() {
    echo "=============================================================="
    echo " 门禁摘要：PASS=${PASS}  FAIL=${FAIL}  SKIP=${SKIP}  （行数 ${#SUMMARY[@]}，应等于三者之和）"
    # bash 3.2 + set -u：空数组直接展开会报 unbound，故先判长度
    [ "${#SUMMARY[@]}" -gt 0 ] && printf '%s\n' "${SUMMARY[@]}"
    # 墙钟总数与「各步 [Ns] 之和」的差 = 门禁自身的记账开销（正常应只有个位数秒）。
    # 差得多 = 有步骤没走 run_step* 计时器，改脚本时漏了。
    local total=$(( $(date +%s) - GATE_T0 ))
    local sum=0
    [ "${#DURATIONS[@]}" -gt 0 ] && sum="$(printf '%s\n' "${DURATIONS[@]}" | cut -d'|' -f2 | awk '{s+=$1} END{print s+0}')"
    echo " 墙钟 ${total}s；已计时步骤合计 ${sum}s（差 $((total - sum))s = 未计时步骤/记账开销）"
    # 成本分布每趟自己念出来（最慢三步），不用事后再去反推 mtime —— P166 的原始病灶。
    if [ "${#DURATIONS[@]}" -gt 0 ]; then
        echo " 最慢：$(printf '%s\n' "${DURATIONS[@]}" | sort -t'|' -k2 -rn | head -3 | \
            awk -F'|' '{printf "%s%s %ss", s, $1, $2; s=" ← "}')"
    fi
    write_report "${total}" "${sum}"
    echo "=============================================================="
    return 0
}

# ---- 步骤执行器：PASS/FAIL/SKIP 记账；失败打印尾部日志并一票否决退出 ----
# 每步起始截断日志（P145：摘要只可能来自本次内容）。
run_step() {
    local name="$1"; shift
    local log="${LOG_DIR}/${name}.log"
    : > "${log}"
    echo "==> [${name}] $*"
    local t0; t0="$(date +%s)"
    if "$@" >"${log}" 2>&1; then
        local d=$(( $(date +%s) - t0 )); DURATIONS+=("${name}|${d}")
        echo "    PASS ${d}s（日志：${log}）"
        record PASS "${name}" "$(digest "${name}") [${d}s]"
    else
        local rc=$?
        local d=$(( $(date +%s) - t0 )); DURATIONS+=("${name}|${d}")
        echo "    FAIL（rc=${rc}）—— 最后 30 行："
        tail -30 "${log}" | sed 's/^/    /'
        record FAIL "${name}" "rc=${rc}，日志 ${log} [${d}s]"
        print_summary
        exit 1
    fi
}

# 同一件事的目录内版本（SPM 必须在包目录里跑）。六个功能 Pod 共用，避免复制粘贴走偏。
run_step_dir() {
    local name="$1" dir="$2"; shift 2
    local log="${LOG_DIR}/${name}.log"
    : > "${log}"
    echo "==> [${name}] (cd ${dir} && $*)"
    local t0; t0="$(date +%s)"
    if (cd "${dir}" && "$@") >"${log}" 2>&1; then
        local d=$(( $(date +%s) - t0 )); DURATIONS+=("${name}|${d}")
        echo "    PASS ${d}s（日志：${log}）"
        record PASS "${name}" "$(digest "${name}") [${d}s]"
    else
        local rc=$?
        local d=$(( $(date +%s) - t0 )); DURATIONS+=("${name}|${d}")
        echo "    FAIL（rc=${rc}）—— 最后 30 行："
        tail -30 "${log}" | sed 's/^/    /'
        record FAIL "${name}" "rc=${rc}，日志 ${log} [${d}s]"
        print_summary
        exit 1
    fi
}

skip_step() {
    # $2 含全角字符时调用方负责加引号；此处仅拼接打印
    echo "==> [$1] SKIP：$2"
    record SKIP "$1" "$2"
}

# ---- Python >= 3.11（tomllib）：env 指定 > 托管版本 > ~/.local > 系统（探测）----
PY="${PYTHON_BIN:-}"
if [ -z "${PY}" ]; then
    for cand in "${HOME}/.workbuddy/binaries/python/versions/3.13.12/bin/python3" \
                "${HOME}/.local/bin/python3.12"; do
        if [ -x "${cand}" ] && "${cand}" -c 'import tomllib' >/dev/null 2>&1; then
            PY="${cand}"; break
        fi
    done
fi
if [ -z "${PY}" ]; then
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
        PY=python3
    fi
fi

echo "=============================================================="
echo " ChuanqiCut 本机门禁 @ $(date '+%F %T')  host=$(hostname -s)"
echo "=============================================================="

# 1. 依赖治理
if [ -n "${PY}" ]; then
    run_step "deps" "${PY}" tools/deps/deps.py validate third_party/manifest.toml
else
    skip_step "deps" "未找到 Python 3.11+（tomllib）。可用 PYTHON_BIN=... 指定。"
fi

# 2. Platform/公共头纯净性
run_step "headers" python3 tools/platform/check_platform_headers.py

# 2b. 仓库卫生（INFRA-034）：忽略规则锚定探针 / 活文档旧路径零残留 / 产物未入库 / .editorconfig 四条件
#     产物入库检查原本是本脚本内联的一段 grep（P84），现由 check_repo_hygiene.sh 统一口径 ——
#     两套正则必然走偏（内联那份至今没盖 Pods/、engine/vendor/），判据只留一份。
run_step "hygiene" tools/ci/check_repo_hygiene.sh

# 2c. Apple 端 UIView 图层卫生（P131：禁清空 UIView backing layer 的 sublayers ——
#     子视图的 layer 也挂在那里，全清会让 UIKit 持有「有 view / 无 layer」的畸形状态 →
#     CA 首次提交事务时 superview 读到野指针 SIGSEGV。见 REVIEW-2026-10-14）
#     INFRA-031 起跑**两趟**：壳工程仍在 apps/apple，自绘视图全部随包上提到 ui/。
#     脚本只接一个根（check_uiview_layer_hygiene.py:120），漏改另一趟 = 门禁静默变窄
#     （ADR-0044 红线 1 的复发病），故两趟都断言"扫到非零文件数"。
lh_log="${LOG_DIR}/layer-hygiene.log"
: > "${lh_log}"
lh_t0="$(date +%s)"
lh_rc=0; lh_total=0
for lh_root in apps/apple ui; do
    echo "---- root=${lh_root}" >>"${lh_log}"
    python3 tools/compliance/check_uiview_layer_hygiene.py "${lh_root}" >>"${lh_log}" 2>&1 || lh_rc=1
    lh_n="$(grep -oE '扫描 [0-9]+ 个文件' "${lh_log}" | tail -1 | grep -oE '[0-9]+' || true)"
    [ -z "${lh_n}" ] && lh_n=0
    if [ "${lh_n}" -eq 0 ]; then
        echo "error: root=${lh_root} 扫到 0 个文件（扫描根写错 / 包搬家后没跟上）" >>"${lh_log}"
        lh_rc=1
    fi
    lh_total=$((lh_total + lh_n))
done
lh_d=$(( $(date +%s) - lh_t0 )); DURATIONS+=("layer-hygiene|${lh_d}")
if [ "${lh_rc}" -eq 0 ]; then
    echo "==> [layer-hygiene] PASS ${lh_d}s（两趟合计 ${lh_total} 个文件，R1 违规 0）"
    record PASS "layer-hygiene" "两趟 ${lh_total} 个文件，R1 违规 0 [${lh_d}s]"
else
    echo "    FAIL [layer-hygiene] —— 最后 30 行："
    tail -30 "${lh_log}" | sed 's/^/    /'
    record FAIL "layer-hygiene" "rc=${lh_rc}，日志 ${lh_log} [${lh_d}s]"
    print_summary; exit 1
fi

# 2d. 公共接口参考未过期（P151：gen_api_reference.py 从未进门禁，docs/api/engine-api.md
#     在 10-12~10-16 的 AIEDIT/AUDIO-002/效果参数批次里长期过期，直到 INFRA-032 重跑才发现）。
#     --check 是**全文比对**而非符号集合比对；判据自证：往 cq_sdk.h 加一条声明后本步必须红
#     （2026-10-16 实测：注入 cq_hygiene_negative_probe → exit 1，回滚 → exit 0）。
run_step "api-doc" python3 tools/docs/gen_api_reference.py --check

# 2e. iOS 切片"只编译"窄检（P146 收口，INFRA-034）：#if TARGET_OS_IPHONE 分支在 macOS 切片
#     里从不参与编译 —— 同一份 audio_engine.mm 的 RegisterSessionObservers 符号数
#     ios-device 4 / ios-sim 3 / macos **0**（nm -a 取证）。冷机 --prime 走 build_core_apple.sh
#     （实测 8m20s，与后面 apple-xcframework 是同一份活，只是提前）；暖机 2~6s。
run_step "ios-compile" tools/ci/check_ios_compile.sh --prime --config=Release

# 3. 内核 Debug + 全量单测
run_step "core-dbg" tools/build/build_core.sh --platform=apple --config=Debug --test

# 4. 内核 Release + 全量单测
if [ "${FAST}" -eq 1 ]; then
    skip_step "core-rel" "--fast 快速档"
else
    run_step "core-rel" tools/build/build_core.sh --platform=apple --config=Release --test
fi

# 5. XCFramework + Swift 绑定 + SharedUI
if [ "${SKIP_APPLE}" -eq 1 ]; then
    skip_step "apple" "跳过（--fast / --skip-apple）"
else
    run_step "apple-xcframework" tools/build/build_core_apple.sh --config=Release
    run_step "apple-prepare" "${ROOT_DIR}/api/swift/prepare.sh"
    run_step_dir "apple-swift-bindings" api/swift \
        swift test --disable-sandbox --scratch-path "${ROOT_DIR}/build/spm/bindings"
    run_step_dir "apple-sharedui" ui/SharedUI \
        swift build --disable-sandbox --scratch-path "${ROOT_DIR}/build/spm/SharedUI"
    # 功能 Pod 测试逐包跑（ADR-0031 分治；新增 Pod 时在此追加同款一行）
    run_step_dir "apple-player" ui/ChuanqiCutPlayer \
        swift test --disable-sandbox --scratch-path "${ROOT_DIR}/build/spm/ChuanqiCutPlayer"
    # Camera 契约层测试（实现层 iOS 专属不进 SPM，随双壳构建验证 = 下面第 6 步 apple-shells，
    # INFRA-037 起这句注释才真的成立；此前双壳一直在门禁外）
    run_step_dir "apple-camera" ui/ChuanqiCutCamera \
        swift test --disable-sandbox --scratch-path "${ROOT_DIR}/build/spm/ChuanqiCutCamera"
    # 导入域测试
    run_step_dir "apple-import" ui/ChuanqiCutImport \
        swift test --disable-sandbox --scratch-path "${ROOT_DIR}/build/spm/ChuanqiCutImport"
    # 编辑器域测试
    run_step_dir "apple-editor" ui/ChuanqiCutEditor \
        swift test --disable-sandbox --scratch-path "${ROOT_DIR}/build/spm/ChuanqiCutEditor"
fi

# 6. 双 App 壳构建（INFRA-037，收池 [18]；2026-10-17 传哲批准进门禁）
#    补的是"门禁里没有一步真把 App 编出来"这个洞：ios-compile 只编内核 iOS 切片，
#    壳里的 podspec/Pbxproj/门面接线坏了以前只能靠人记得按 P129 手工跑。
#    用的就是 **App 自己的 workspace**，不另立判据工程（两套同源判据必然走偏）。
#    暖跑两端合计 39s / 冷跑 280s（本机 Intel 实测，baselines「双壳进门禁」）。
if [ "${SKIP_APPLE}" -eq 1 ]; then
    skip_step "apple-shells" "跳过（--fast / --skip-apple）"
else
    run_step "apple-shells" tools/ci/check_apple_shells.sh
fi

# 7. golden 样本齐备性
if [ -n "${PY}" ]; then
    run_step "golden" "${PY}" tests/golden/verify.py --json
else
    skip_step "golden" "未找到 Python 3.11+"
fi

print_summary
echo " 门禁通过（以本机实测为准）"
exit 0
