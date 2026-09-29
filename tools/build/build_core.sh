#!/usr/bin/env bash
# ChuanqiCut — 唯一的本地内核构建入口（INFRA-002）
#
# 本脚本是桌面端（macOS / Linux）构建内核 + 跑单测的唯一入口。
# CI 复用同一脚本（禁止在 CI 里另写一套编译命令，见 ARCH-001 §9 / TASK-INFRA-002）。
#
# 设计要点：
#   - cmake 不在本机 PATH 里，故 CMAKE_BIN 默认回退到绝对路径，
#     允许通过环境变量 CMAKE_BIN 覆盖（例如 CI 里用系统 cmake）。
#   - 默认构建类型 Debug；可通过 --config 切到 Release（开 LTO）。
#   - 默认只做编译（-Werror 门禁）；加 --test 会额外跑 ctest。
#
# 用法：
#   tools/build/build_core.sh --platform=apple [--config=Debug|Release] [--test] [--clean]
#
# 注：本期仅 apple 桌面构建真正落地；android / ohos 由各自宿主工具链构建，
#     此处收到非 apple 平台时给出明确提示并退出，避免“假成功”。

set -euo pipefail

# ---- cmake 二进制：默认绝对路径，允许环境变量覆盖 ----
: "${CMAKE_BIN:=/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake}"

# ---- 默认值 ----
PLATFORM="apple"
CONFIG="Debug"
RUN_TESTS=0
CLEAN=0
BUILD_DIR="build"

# ---- 解析参数 ----
for arg in "$@"; do
    case "$arg" in
        --platform=*) PLATFORM="${arg#*=}" ;;
        --config=*)   CONFIG="${arg#*=}" ;;
        --test)       RUN_TESTS=1 ;;
        --clean)      CLEAN=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown argument '$arg' (try --help)" >&2
            exit 2
            ;;
    esac
done

# ---- 平台门禁 ----
if [ "$PLATFORM" != "apple" ]; then
    echo "error: --platform=$PLATFORM is not supported in this phase." >&2
    echo "       INFRA-002 only lands the macOS/desktop build; android/ohos" >&2
    echo "       are built by their own host toolchains (ARCH-001 §9)." >&2
    exit 3
fi

if [ ! -x "$CMAKE_BIN" ]; then
    echo "error: cmake not found at CMAKE_BIN='$CMAKE_BIN'" >&2
    echo "       set CMAKE_BIN to a valid cmake binary and retry." >&2
    exit 4
fi

# ---- 项目根目录（脚本位于 tools/build/，上溯两级）----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

echo "==> ChuanqiCut core build"
echo "    cmake : $CMAKE_BIN"
echo "    root  : $ROOT_DIR"
echo "    platform: $PLATFORM   config: $CONFIG   test: $RUN_TESTS"

# ---- 可选清理 ----
if [ "$CLEAN" -eq 1 ]; then
    echo "==> cleaning $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

# ---- 配置 + 构建 ----
echo "==> configure (CMAKE_BUILD_TYPE=$CONFIG)"
"$CMAKE_BIN" -S . -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE="$CONFIG"

echo "==> build"
"$CMAKE_BIN" --build "$BUILD_DIR" --config "$CONFIG"

# ---- 可选单测 ----
# ctest 与 cmake 同目录（本机也不在 PATH），从 CMAKE_BIN 推导，允许 CTEST_BIN 覆盖。
if [ "$RUN_TESTS" -eq 1 ]; then
    : "${CTEST_BIN:=$(dirname "$CMAKE_BIN")/ctest}"
    if [ ! -x "$CTEST_BIN" ]; then
        echo "error: ctest not found at CTEST_BIN='$CTEST_BIN'" >&2
        exit 5
    fi
    echo "==> ctest ($CTEST_BIN)"
    "$CTEST_BIN" --test-dir "$BUILD_DIR" --output-on-failure --build-config "$CONFIG"
fi

echo "==> done."
