#!/usr/bin/env bash
# ChuanqiCut — iOS 切片"只编译"窄检（INFRA-034 收口 P146，2026-10-16）
#
# 要解决的洞：`build_core.sh --platform=apple` 只出 **macOS 切片**。`engine/platform/apple/**`
# 里被 `#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE` 包裹的代码在 core-dbg / core-rel
# 里**从不参与编译**，于是出现"门禁绿、iOS 编不过"还能入库（b471b8c 案底）。
# 本机取证（2026-10-16，同一份 `engine/platform/apple/media/audio_engine.mm`，
# `nm -a <….mm.o> | grep -c RegisterSessionObservers`）：
#     ios-device 4 / ios-simulator 3 / macos **0**
# —— :212-271 的 RegisterSessionObservers 只在 iOS 切片里存在，mac 切片整段被预处理掉。
#
# 为什么不复制一份 cmake 参数：configure 由 **tools/build/build_core_apple.sh 独占**
# （含 CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY、部署目标、IPO/LTO 与脏 cache 自愈
# 那些坑）。本脚本只 `cmake --build` 它已经配好的目录，只构建两个静态库 target：
# 不 libtool 合并、不 xcodebuild 打 .xcframework、不签名、不链可执行体（device 链接需签名）。
# 判据就一件事：**iOS 切片编得过**。
#
# 时长（本机 Intel x86_64 集成机实测）：
#   冷（cache 不存在，--prime 触发三切片全量）= **151s**（`--parallel` 后实测，exit 0）
#     ⚠️ INFRA-038 之前是 **8m20s**（串行）——引用这个数必须说清并行前后；作废的旧数字见
#        TASK-INFRA-034 §候选(a)，那里保留串行原值不改。
#   暖（cache 已存在 + 只改一个 .mm）= **6.3s**（重编 1 个 TU + 重链 libcq_platform_apple.a）
#   暖（无改动）≈ 2s（CMake 无事可做）
#   → 卡面约束"单次窄检不得过 3 分钟"**冷暖两条路径都满足**（并行化之前只有暖路径满足）。
#
# 用法：
#   tools/ci/check_ios_compile.sh [--config=Release|Debug] [--slice=ios-device|ios-simulator]
#                                 [--prime]        # cache 缺失时自动跑 build_core_apple.sh 装配
#   退出码：0 = 编得过；1 = 编译失败；3 = cache 缺失且未给 --prime（把补救命令打在输出里）

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

: "${CMAKE_BIN:=$(command -v cmake || echo "${HOME}/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake")}"
# Unix Makefiles 生成器不传 --parallel 就是单线程（P166：同脏集串行/并行实测差 3.6×）。
: "${CQ_JOBS:=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
CONFIG="Release"
SLICE="ios-device"
PRIME=0

for arg in "$@"; do
    case "$arg" in
        --config=*)  CONFIG="${arg#*=}" ;;
        --slice=*)   SLICE="${arg#*=}" ;;
        --prime)     PRIME=1 ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
    esac
done

# slice 标签 → build_core_apple.sh 用的构建目录（两处必须同步，搬家/改脚本时一起改）
case "$SLICE" in
    ios-device)    BDIR="build/apple/ios-device"; SDK="iphoneos" ;;
    ios-simulator) BDIR="build/apple/ios-sim";    SDK="iphonesimulator" ;;
    *) echo "error: --slice 只支持 ios-device|ios-simulator（got '$SLICE'）" >&2; exit 2 ;;
esac

if [ ! -f "${BDIR}/CMakeCache.txt" ]; then
    echo "!! [ios-compile] ${BDIR}/CMakeCache.txt 不存在（本机还没装配过 iOS 切片）"
    if [ "${PRIME}" -eq 0 ]; then
        echo "   补救：tools/build/build_core_apple.sh --config=${CONFIG}"
        echo "   （或给本脚本加 --prime，三切片冷构建实测 151s）"
        exit 3
    fi
    echo "==> [ios-compile] --prime：先跑 build_core_apple.sh 装配三切片（冷构建）"
    tools/build/build_core_apple.sh --config="${CONFIG}" || exit 1
fi

# 只用已配好的 cache；CONFIG 以 cache 里的 CMAKE_BUILD_TYPE 为准（判据是"编得过"，不重定档位）
cache_cfg="$(grep -m1 '^CMAKE_BUILD_TYPE:STRING=' "${BDIR}/CMakeCache.txt" | cut -d= -f2 || true)"
echo "==> [ios-compile] slice=${SLICE} sdk=${SDK} build=${BDIR} cache-CONFIG=${cache_cfg:-?}"
echo "    只构建 cq_core + cq_platform_apple（静态库；不 libtool / 不 xcframework / 不签名）"

# ⚠️ 先取 rc 再判：`if cmd; then …; fi` 无 else 分支时整条 if 的退出码是 0，
#    事后 `rc=$?` 会读到 0（本次写完就撞上，负测里打印成 "FAIL（rc=0）"）。
"${CMAKE_BIN}" --build "${BDIR}" --parallel "${CQ_JOBS}" --target cq_core cq_platform_apple
rc=$?
if [ "${rc}" -eq 0 ]; then
    echo "    PASS：iOS 切片编译通过（覆盖 #if TARGET_OS_IPHONE 分支）"
    exit 0
fi
echo "    FAIL（rc=${rc}）：iOS 切片编译不过 —— 这正是 macOS 切片与 core-dbg/core-rel 抓不到的那类错误"
exit 1
