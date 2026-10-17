#!/usr/bin/env bash
# ChuanqiCut — 构建期 shader 工具链装配（INFRA-034，2026-10-16）
#
# 为什么存在（P160）：`tools/shaders/build_shaders.py` 硬依赖两个二进制
#     build/tools/glslang/StandAlone/glslang   与   build/tools/spirv-cross/spirv-cross
#   而**仓库里从来没有能产出它们的入库脚本** —— 本机那套是历史会话手搓的。
#   实测后果：`build_core.sh --platform=apple --clean` 停在
#     [27%] SHADER-001: glslang → SPIR-V → spirv-cross → MSL (blit)
#     error: shader 工具链不可用（试过：…/build/tools/glslang/StandAlone/glslang）
#   新克隆机、CI runner、以及任何清过 build/ 的机器**都编不出内核**。
#   暖缓存门禁永远发现不了这件事（缓存里一直有），所以这条判据必须做成脚本。
#
# 源码按 `third_party/manifest.toml` 的 pin 取（红线 #10：manifest 是真源）：
#   - 目录不存在 → 浅 fetch 该 commit 并校验 `HEAD == pin_ref`；
#   - 目录存在但不是 git 仓库（本机现状）→ 用现成树，glslang 另按 `CHANGES.md`
#     顶部版本核对 manifest 的 version，并**明确打印"commit 级 pin 不可校验"**——
#     不假装验过（AGENTS：未验证的推测必须标 hypothesis）。
#     ⚠️ 非 git 树还有个上游副作用：SPIRV-Cross 的 CMake 会**向上**找到宿主仓库的
#     .git，把 ChuanqiCut 的 HEAD 当成自己的版本打印（实测 "Git hash: v0.1.0-244-g5cfcdcb+"）。
#     那行日志不能作为 SPIRV-Cross 的版本证据，别拿它去对 pin。
#     **处置：本机 `third_party/src/SPIRV-Cross/CMakeLists.txt` 里打了一处本地补丁**（把该
#     变量固定成 manifest 的 pin）。红线 #10 要求登记：补丁**不入库**（整个 `third_party/src/`
#     在 .gitignore 里），CI/新克隆机走 pin 的 git checkout，拿到的是**未打补丁的上游树**，
#     于是它会如实打印自己那个 commit（那时才是可信的版本证据）。
#     补丁指纹变了会自动强制重编，见下面 SPVC_PATCH_FP。
#
# 用法：
#   tools/build/build_shader_toolchain.sh              # 缺什么补什么（幂等）
#   tools/build/build_shader_toolchain.sh --jobs 8     # 指定并行度（默认取 hw.ncpu）
#   tools/build/build_shader_toolchain.sh --rebuild    # 强制重配重编
#   tools/build/build_shader_toolchain.sh --check-only # 只验产物在不在、能不能跑（**只读，不删任何文件** P162）
#
# ⚠️ 本脚本必须在**空仓库状态**验过（先 `rm -rf build`）：两个案底都是这么抓出来的 ——
#   1) 日志重定向目标 `build/tools/` 在新克隆机上不存在，真实失败被一条 shell 错误盖掉；
#   2) 失败残留的 CMakeCache 会把上次的 `-D` 值端回来，"改对 flag 重跑"看着仍失败（见 P161）。
#   在暖缓存上跑通的装配脚本不等于能用（P160）。
#
# 产物落点即 build_shaders.py 的默认位置（glslang 与 **全小写的 spirv-cross** 两个目录名）；
# `glslang --version` / `spirv-cross --help` 各打一行横幅，真正的功能判据是末尾的端到端转译。
# CI（.github/workflows/ci.yml）在 build_core.sh 之前调本脚本 —— 与 FFmpeg 装配同构。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

: "${CMAKE_BIN:=$(command -v cmake || echo "$HOME/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake")}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
REBUILD=0
CHECK_ONLY=0
FORCE_NEXT=0
SRC=""
MANIFEST="third_party/manifest.toml"

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs)       JOBS="$2"; shift 2 ;;
        --rebuild)    REBUILD=1; shift ;;
        --check-only) CHECK_ONLY=1; shift ;;
        --src)        SRC="$2"; shift 2 ;;          # 指定已 checkout 的源码根（离线机）
        -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

SRC_ROOT="${SRC:-third_party/src}"

# pin 从 manifest 读（本脚本自己**不写死 commit**，避免同一判据两份真源）。
# manifest 是 `pin_ref = "<sha>"   # 注释` 形式，按 dep 块内第一段 name→pin_ref 取值。
pin_of() {
    awk -v n="$1" '
        $0 ~ "^name[[:space:]]*=[[:space:]]*\""n"\"" { inn = 1 }
        inn && /^pin_ref/ { gsub(/[";]/, "", $3); print $3; exit }
    ' "$MANIFEST"
}

ver_of() {
    awk -v n="$1" '
        $0 ~ "^name[[:space:]]*=[[:space:]]*\""n"\"" { inn = 1 }
        inn && /^version/ { gsub(/[";]/, "", $3); print $3; exit }
    ' "$MANIFEST"
}

upstream_of() {
    awk -v n="$1" '
        $0 ~ "^name[[:space:]]*=[[:space:]]*\""n"\"" { inn = 1 }
        inn && /^upstream/ { gsub(/[";]/, "", $3); print $3; exit }
    ' "$MANIFEST"
}

# ==== 单个依赖：确保源码在 pin 上 ====
ensure_src() {
    local name="$1" dir="$SRC_ROOT/$1" pin upstream wantver havever
    pin="$(pin_of "$name")"; upstream="$(upstream_of "$name")"; wantver="$(ver_of "$name")"
    [ -n "$pin" ] || { echo "!! manifest 里读不到 $name 的 pin_ref" >&2; exit 6; }

    if [ ! -d "$dir" ]; then
        [ -n "$SRC" ] && { echo "!! --src=$SRC 下没有 $name" >&2; exit 6; }
        echo "==> [$name] 源码缺失，浅 fetch pin $pin"
        git clone --no-checkout --filter=blob:none "$upstream" "$dir" >/dev/null 2>&1
        git -C "$dir" fetch --depth 1 origin "$pin" >/dev/null 2>&1
        git -C "$dir" checkout --detach "$pin" >/dev/null 2>&1
    fi

    if git -C "$dir" rev-parse HEAD >/dev/null 2>&1 && [ -d "$dir/.git" ]; then
        local got; got="$(git -C "$dir" rev-parse HEAD)"
        if [ "$got" != "$pin" ]; then
            echo "!! [$name] HEAD=$got != manifest pin=$pin —— 先 git -C $dir checkout $pin" >&2
            exit 6
        fi
        echo "    [$name] commit pin 校验通过（$got，git 仓库）"
    else
        # 非 git 树：只能做版本级核对，commit 级无法证 —— 直说不装
        havever=""
        [ -f "$dir/CHANGES.md" ] && havever="$(grep -m1 -oE '^## [0-9]+\.[0-9]+\.[0-9]+' "$dir/CHANGES.md" | tr -d '# ')"
        echo "    [$name] 非 git 树（本机历史 checkout），**commit 级 pin 不可校验**；" \
             "version 核对：manifest=$wantver 树内=${havever:-取不到}"
        if [ -n "$havever" ] && [ "$havever" != "$wantver" ]; then
            echo "!! [$name] 版本与 manifest 不符（$havever vs $wantver），拒绝继续" >&2
            exit 6
        fi
    fi
}

# ==== 构建一个工具链二进制 ====
# 出参目录**必须与 `tools/shaders/build_shaders.py` 的默认查找路径逐字一致**：
#   glslang → build/tools/glslang/StandAlone/glslang
#   spirv-cross → build/tools/spirv-cross/spirv-cross   ← 全小写，不是 manifest 里的 `SPIRV-Cross`
# 用依赖名当目录名在 macOS/默认 APFS（大小写不敏感）上"碰巧能用"，换到大小写敏感的卷
# （Linux、或区分大小写的 APFS 宗卷）就是"工具链不可用"。所以 outdir 单独传，不拿 name 顶替。
build_tool() {
    local name="$1" outdir="$2" binrel="$3"; shift 3
    local bdir="build/tools/${outdir}"
    local bin="${bdir}/${binrel}"
    local force="$FORCE_NEXT"; FORCE_NEXT=0        # 一次性：只作用于紧跟的这一个工具
    local why=""
    if [ "$REBUILD" -eq 1 ]; then why="--rebuild"; fi
    if [ "$force" -eq 1 ]; then why="本地补丁指纹变更"; fi
    # ⚠️ `--check-only` 是**只读模式**，一条删除都不许走（第一版在 check-only 下把
    # `build/tools/spirv-cross/` 整棵删了 —— 判据现场被自己的判据脚本销毁，P162）。
    if [ "$CHECK_ONLY" -eq 0 ] && [ -n "$why" ] && [ -d "$bdir" ]; then
        echo "    [$name] ${why}：删除既有构建目录 ${bdir}/"
        rm -rf "$bdir"
    fi
    if [ -x "$bin" ] && [ "$REBUILD" -eq 0 ] && [ "$force" -eq 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
        echo "==> [$name] 产物已存在，跳过编译（--rebuild 可强制）：$bin"
        return 0
    fi
    if [ "$CHECK_ONLY" -eq 1 ]; then
        [ -x "$bin" ] || { echo "!! [$name] --check-only：产物缺失 $bin" >&2; return 1; }
        echo "    [$name] --check-only OK：$bin"
        return 0
    fi

    echo "==> [$name] configure + build（-j${JOBS}）"
    # `build/` 整棵不存在是新克隆机/CI runner 的正常状态（本机也一样：复现 CI 时先 rm -rf build）。
    # 不先建目录，下面两条日志重定向会直接 "No such file or directory"，
    # 把真实失败原因盖成一条 shell 错误（实测第一版就这么死在 run1）。
    mkdir -p build/tools
    # 产物不在 = 上次 configure/build 没成功；**旧 CMakeCache 会把上次的 -D 值原样端回来**，
    # 于是"改了 flag 重跑"会复现同一个失败（实测：第一次误设 GLSL=OFF 后，
    # 删掉那行 flag 重跑仍死在 "Must enable GLSL support to enable MSL support."）。
    # 所以在重配前把残骸清掉，让每次重跑都真正用上当前这套 flag。
    if [ -f "${bdir}/CMakeCache.txt" ]; then
        echo "    [$name] 清掉失败残留的构建目录 ${bdir}/（旧缓存会锁死上次的 -D 值）"
        rm -rf "${bdir}"
    fi
    "$CMAKE_BIN" -S "$SRC_ROOT/${name}" -B "$bdir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        "$@" >"${bdir}.configure.log" 2>&1 || {
            echo "!! [$name] configure 失败，日志 ${bdir}.configure.log 末尾：" >&2
            tail -15 "${bdir}.configure.log" | sed 's/^/    /' >&2; return 1; }
    "$CMAKE_BIN" --build "$bdir" -j "${JOBS}" >"${bdir}.build.log" 2>&1 || {
        echo "!! [$name] 编译失败，日志 ${bdir}.build.log 末尾：" >&2
        tail -20 "${bdir}.build.log" | sed 's/^/    /' >&2; return 1; }

    [ -x "$bin" ] || { echo "!! [$name] 产物不在预期位置：$bin（build_shaders.py 就找这个路径）" >&2; return 1; }
    echo "    [$name] $bin  $(stat -f '%z B' "$bin" 2>/dev/null)"
}

if [ ! -x "$CMAKE_BIN" ]; then
    echo "error: cmake not found at CMAKE_BIN='$CMAKE_BIN'" >&2
    exit 4
fi
echo "==> shader 工具链装配 @ $(date '+%F %T')  cmake=$CMAKE_BIN  src=$SRC_ROOT"

ensure_src glslang
ensure_src SPIRV-Cross
# glslang：External/ 里不带 SPIRV-Tools → 必须关优化（-O 由 spirv-opt 提供，本链用不上）
build_tool glslang glslang StandAlone/glslang \
    -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DBUILD_TESTING=OFF
# SPIRV-Cross 的**本地补丁**（版本横幅去污染，见文件头）改了就必须重编：把补丁行指纹当 cache key
# 打进去，指纹变了自动强制重配重编 —— 靠人"记得手动 --rebuild"迟早漏。
SPVC_PATCH_FP="$({ grep -n 'ChuanqiCut 本地补丁' "$SRC_ROOT/SPIRV-Cross/CMakeLists.txt" || echo "(无补丁)"; } | cksum | tr -d ' =')"
# ⚠️ cache 里的行形如 `SPVC_PATCH_FP:UNINITIALIZED=<fp>` —— 这个 key **不是** CMake `option()`/
#   `set(... CACHE)` 声明过的，未声明的 `-D` 一律落成 `UNINITIALIZED` 类型。
#   实测拿 `SPVC_PATCH_FP:STRING=` 去 grep 永远不命中 → 每次暖跑都误判"指纹变了"→ 删目录重编，
#   脚本自认为幂等其实每遍多花 65s 且把 --check-only 的判据现场也删了（P162）。类型段必须可选。
if [ "$CHECK_ONLY" -eq 0 ] && [ -f build/tools/spirv-cross/CMakeCache.txt ] &&
   ! grep -qE "^SPVC_PATCH_FP(:[A-Z]+)?=${SPVC_PATCH_FP}$" build/tools/spirv-cross/CMakeCache.txt; then
    echo "==> [SPIRV-Cross] 本地补丁指纹 ${SPVC_PATCH_FP} 与缓存不符 → 强制重编"
    FORCE_NEXT=1
fi
# SPIRV-Cross：测试套要外部 glslang/SPIRV-Tools 现场，关掉；不装到系统前缀。
# ⚠️ 别再把 backends 挨个 OFF 来"瘦身"：CLI（spirv-cross 二进制）在 CMakeLists.txt:429-456
#   硬要求 GLSL/HLSL/MSL/CPP/REFLECT/UTIL/STATIC **全开**，关任一个直接 FATAL_ERROR
#   （实测第一次就死在 "Must enable GLSL support to enable MSL support."）。
#   这里能省的只有测试套与 install 规则。
build_tool SPIRV-Cross spirv-cross spirv-cross \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_SKIP_INSTALL=ON \
    -DSPIRV_CROSS_NAMESPACE_OVERRIDE= \
    -DSPVC_PATCH_FP="${SPVC_PATCH_FP}"

echo "==> 自检（两个二进制都要能跑）"
GL="$(pwd)/build/tools/glslang/StandAlone/glslang"
SC="$(pwd)/build/tools/spirv-cross/spirv-cross"
"$GL" --version | head -1 | sed 's/^/    glslang      /'
# spirv-cross **没有** `--version`（未知参数会打 usage 并 rc=1，实测打断 set -e）。
# `--help` 首行是它的版本横幅，够用来证明"二进制能跑"；功能正确性交给下面的端到端转译。
# ⚠️ 这行横幅的**可信度取决于源码树怎么来的**（P160 附注 / 池 [23]）：
#   - 本机（非 git 树，已打本地补丁）→ 打的是 manifest pin，可信但来源是补丁；
#   - CI / 新克隆机（按 pin `git checkout`，未打补丁的上游树）→ 打的是它自己的 commit，可信；
#   - 非 git 树**没打补丁**时 → `git describe` 向上抓到宿主仓库 HEAD = **假归属**，不可引用。
"$SC" --help 2>&1 | head -1 | sed 's/^/    spirv-cross  /' || true
echo "==> 端到端：用 SHADER-001 真实转一遍 blit（不写进源码树，只落 build/generated）"
# 这里不调 tomllib，系统 python3（本机 3.9）就够；门禁的 $PY（≥3.12）另有用途。
python3 tools/shaders/build_shaders.py --repo-root . --out-dir build/generated/shaders \
    --glslang "$GL" --spirv-cross "$SC" | tail -3
echo "==> done. 现在可以跑 tools/build/build_core.sh --platform=apple"
