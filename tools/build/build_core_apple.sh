#!/usr/bin/env bash
# ChuanqiCut — Apple 三切片 XCFramework 构建（INFRA-003）
#
# 一次性产出含三个切片的 XCFramework：
#   - iOS device   (arm64,        SDK iphoneos)          —— 交叉编译，本机不可运行
#   - iOS simulator(arm64 + x86_64, SDK iphonesimulator)
#   - macOS        (arm64 + x86_64, SDK macosx)
#
# 每个切片先分别用 CMake 构建出 cq_core.a + cq_pal_apple.a，再用 libtool 合并成
# 单一静态库 ChuanqiCut.a（保留各 .o 的 LC_BUILD_VERSION 平台标记），最后由
# `xcodebuild -create-xcframework` 合并成 .xcframework。
#
# 设计要点（沿用 build_core.sh 的约定）：
#   - cmake 不在 PATH，CMAKE_BIN 默认绝对路径，允许环境变量覆盖。
#   - 每步显式打印在做什么；任何一步失败立即非零退出（set -e + 显式检查），不静默继续。
#   - 只构建静态库 target（cq_core cq_pal_apple），不构建 tests/apps 可执行文件：
#     iOS device 链接可执行文件需要签名，本任务不涉签名；切片只交付静态库。
#   - iOS 交叉编译必须设 CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY，否则 CMake
#     在 configure 期的 try_compile 会去链接可执行文件而失败（device 需签名）。
#
# ⚠️ LTO 与 XCFramework 打包不兼容（2026-09-28 实测定位）
#   cmake/CompileOptions.cmake 开了 CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=ON。
#   Release + LTO 时 clang 产出的是 **bitcode-only 目标文件**（头部 magic 0x0b17c0de，
#   后跟 'BC\xc0\xde'），不是 Mach-O。`xcodebuild -create-xcframework` 解析不了，报：
#       unable to find any architecture information in the binary: Unknown header: 0xb17c0de
#   这与 ENABLE_BITCODE **无关**（此前误判为 bitcode 嵌入，加了 -fno-embed-bitcode，
#   方向错了，该 clang 也不识别此参数）。真正的开关是 IPO/LTO。
#   本脚本默认对打包构建关闭 IPO：分发的静态库带 LTO bitcode 会强制消费者的 linker
#   版本匹配，是常见的分发陷阱；且 xcodebuild 直接拒绝。Release 的 -O3 仍保留。
#   需要 LTO 时用 --lto=on（但那样产出的 .xcframework 会在此处失败，属预期行为）。
#
# 用法：
#   tools/build/build_core_apple.sh [--config=Debug|Release] [--clean] [--output=<dir>]
#                                   [--lto=off|on]
#
# 说明：本脚本不修改任何 C++/ObjC++ 业务代码；若 PAL 某 API 仅在 macOS 可用导致 iOS
# 切片编译失败，脚本会如实非零退出，具体失败文件/API 由构建日志给出，交 owner 裁决。

set -euo pipefail

# ---- cmake 二进制：默认绝对路径，允许环境变量覆盖 ----
: "${CMAKE_BIN:=/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake}"
# 用 xcrun 取当前 Xcode 的 xcodebuild / libtool / lipo（保证工具链与本机 Xcode 一致）。
XCRUN_BIN="${XCRUN_BIN:-xcrun}"

# ---- 默认值 ----
CONFIG="Debug"
CLEAN=0
OUTPUT_DIR=""
LTO="off"
SMOKE_LINK=1

# ---- 解析参数 ----
for arg in "$@"; do
    case "$arg" in
        --config=*) CONFIG="${arg#*=}" ;;
        --clean)     CLEAN=1 ;;
        --output=*)  OUTPUT_DIR="${arg#*=}" ;;
        --lto=*)     LTO="${arg#*=}" ;;
        --no-smoke-link) SMOKE_LINK=0 ;;
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

# ---- config 合法性 ----
case "$CONFIG" in
    Debug|Release) ;;
    *)
        echo "error: --config must be Debug or Release (got '$CONFIG')" >&2
        exit 2
        ;;
esac

# ---- lto 合法性（见顶部 LTO 说明）----
case "$LTO" in
    on)  IPO_VALUE="ON"  ;;
    off) IPO_VALUE="OFF" ;;
    *)
        echo "error: --lto must be on or off (got '$LTO')" >&2
        exit 2
        ;;
esac

# ---- cmake 可用性 ----
if [ ! -x "$CMAKE_BIN" ]; then
    echo "error: cmake not found at CMAKE_BIN='$CMAKE_BIN'" >&2
    echo "       set CMAKE_BIN to a valid cmake binary and retry." >&2
    exit 4
fi
if ! command -v "$XCRUN_BIN" >/dev/null 2>&1; then
    echo "error: '$XCRUN_BIN' not found in PATH (need Xcode command line tools)." >&2
    exit 4
fi

# ---- 项目根目录（脚本位于 tools/build/，上溯两级）----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

XCFW_NAME="ChuanqiCut.xcframework"
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$ROOT_DIR/build/apple/$XCFW_NAME"
fi

BUILD_BASE="$ROOT_DIR/build/apple"
IOS_DEVICE_DIR="$BUILD_BASE/ios-device"
IOS_SIM_DIR="$BUILD_BASE/ios-sim"
MACOS_DIR="$BUILD_BASE/macos"
HEADERS_DIR="$ROOT_DIR/core/include"

echo "==> ChuanqiCut Apple XCFramework build"
echo "    cmake : $CMAKE_BIN"
echo "    xcrun: $XCRUN_BIN"
echo "    root  : $ROOT_DIR"
echo "    config: $CONFIG"
echo "    lto   : $LTO (Release only)"
echo "    output: $OUTPUT_DIR"

# ---- 可选清理 ----
if [ "$CLEAN" -eq 1 ]; then
    # 同样走废纸篓，不 rm -rf（见上方输出目录的处理）。
    TRASH_DEST="$HOME/.Trash/apple-build-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$HOME/.Trash"
    echo "==> moving $BUILD_BASE to trash: $TRASH_DEST"
    mv "$BUILD_BASE" "$TRASH_DEST"
fi

# ---- 单切片构建：configure + build(仅静态库) + libtool 合并 ----
# 参数：label sysroot sysname archs deploy bdir
build_slice() {
    local label="$1" sysroot="$2" sysname="$3" archs="$4" deploy="$5" bdir="$6"

    # ---- 脏 cache 自愈 ----------------------------------------------------
    # 2026-09-28 排障期曾手动给 ios-device 传过 -DCMAKE_CXX_FLAGS=-fno-embed-bitcode
    # （方向错误的尝试，已撤销但残留进 CMakeCache）。CMake 会一直复用该 cache 值，
    # 导致后续 configure 悄悄带上这个该 clang 不识别的参数。检测到就清掉重来，
    # 避免“本地能过、别人 clone 后必炸”的幽灵状态。
    if [ -f "$bdir/CMakeCache.txt" ] && grep -q -- "-fno-embed-bitcode" "$bdir/CMakeCache.txt"; then
        echo "==> [$label] found stale '-fno-embed-bitcode' in CMakeCache.txt; removing cache"
        rm -f "$bdir/CMakeCache.txt"
        rm -rf "$bdir/CMakeFiles"
    fi

    echo
    echo "================================================================"
    echo "==> [$label] configure"
    echo "    CMAKE_SYSTEM_NAME   = $sysname"
    echo "    CMAKE_OSX_SYSROOT   = $sysroot"
    echo "    CMAKE_OSX_ARCHS     = $archs"
    echo "    DEPLOYMENT_TARGET   = $deploy"
    echo "    build dir           = $bdir"
    echo "================================================================"
    "$CMAKE_BIN" -S "$ROOT_DIR" -B "$bdir" \
        -DCMAKE_BUILD_TYPE="$CONFIG" \
        -DCMAKE_SYSTEM_NAME="$sysname" \
        -DCMAKE_OSX_SYSROOT="$sysroot" \
        -DCMAKE_OSX_ARCHITECTURES="$archs" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCQ_ENABLE_LTO_RELEASE="$IPO_VALUE"

    echo "    LTO(IPO, Release) = $IPO_VALUE"

    echo "==> [$label] build (targets: cq_core cq_pal_apple)"
    "$CMAKE_BIN" --build "$bdir" --config "$CONFIG" --target cq_core cq_pal_apple

    local core_a="$bdir/lib/libcq_core.a"
    local pal_a="$bdir/lib/libcq_pal_apple.a"
    if [ ! -f "$core_a" ]; then
        echo "error: [$label] cq_core.a not produced at $core_a" >&2
        exit 6
    fi
    if [ ! -f "$pal_a" ]; then
        echo "error: [$label] cq_pal_apple.a not produced at $pal_a" >&2
        exit 6
    fi
    echo "==> [$label] combine static libs -> $bdir/ChuanqiCut.a"
    "$XCRUN_BIN" libtool -static -o "$bdir/ChuanqiCut.a" "$core_a" "$pal_a"
    echo "    done: $(wc -c < "$bdir/ChuanqiCut.a") bytes"
}

# ---- iOS device（交叉编译，本机不可运行；架构基线 arm64，见 ADR-0010）----
build_slice "ios-device" "iphoneos"        "iOS"     "arm64"         "16.0" "$IOS_DEVICE_DIR"

# ---- iOS simulator（arm64 + x86_64）----
build_slice "ios-simulator" "iphonesimulator" "iOS"  "arm64;x86_64"  "16.0" "$IOS_SIM_DIR"

# ---- macOS（arm64 + x86_64；本机 Intel，x86_64 为本机原生，arm64 交叉编出）----
# ⚠️ 部署目标必须与 ADR-0010 一致（最低 macOS 15.4），不能写 11.0。
#   2026-09-28 实测：写 11.0 时 macOS 切片报
#   "'loadTracksWithMediaType:completionHandler:' is only available on macOS 12.0
#    or newer ... deployment target is macOS 11.0.0"（-Werror 下即失败）。
#   该 API 是必需的——旧的 `tracksWithMediaType:` 已在 macOS 15.0 弃用，同样会触发
#   -Werror。两头都不能动编译选项，唯一正解是让部署目标匹配 ADR-0010。
MACOS_DEPLOY="15.4"
build_slice "macos" "macosx" "Darwin" "arm64;x86_64" "$MACOS_DEPLOY" "$MACOS_DIR"

# ---- 合并前预检：切片必须是真 Mach-O，不能是 LTO bitcode ------------------
# 这道检查是 2026-09-28 的教训：xcodebuild 报的 "Unknown header: 0xb17c0de" 很隐晦，
# 光看错误信息会误判成 ENABLE_BITCODE。这里在合并前显式断言，失败就带着明确
# 根因退出，而不是把 xcodebuild 的原始报错丢给人猜。
echo
echo "==> preflight: slices must contain Mach-O objects (not LTO bitcode)"
PREFLIGHT_FAIL=0
for slice_dir in "$IOS_DEVICE_DIR" "$IOS_SIM_DIR" "$MACOS_DIR"; do
    slice_a="$slice_dir/ChuanqiCut.a"
    [ -f "$slice_a" ] || { echo "error: missing $slice_a" >&2; PREFLIGHT_FAIL=1; continue; }
    # otool 对 bitcode-only 的 .o 会输出 "is an LLVM bit-code file"
    if "$XCRUN_BIN" otool -l "$slice_a" 2>&1 | grep -q "is an LLVM bit-code file"; then
        echo "error: $slice_a contains LTO bitcode objects (not Mach-O)." >&2
        echo "       xcodebuild -create-xcframework cannot read them (Unknown header: 0xb17c0de)." >&2
        echo "       Rebuild with --lto=off (default), or pass --lto=on only if you intend to" >&2
        echo "       consume these libraries with a matching linker toolchain." >&2
        PREFLIGHT_FAIL=1
    else
        echo "    ok: $(basename "$slice_dir")"
    fi
done
if [ "$PREFLIGHT_FAIL" -ne 0 ]; then
    echo "error: preflight failed; refusing to run xcodebuild -create-xcframework" >&2
    exit 8
fi

# ---- 合并 XCFramework ----
echo
echo "================================================================"
echo "==> create xcframework -> $OUTPUT_DIR"
echo "================================================================"
# 输出目录存在就先移入废纸篓。
# 不走 `rm -rf`：删除不可逆，而这些目录是脚本自动重建的，移走即可；出问题时还能捞回来。
if [ -e "$OUTPUT_DIR" ]; then
    TRASH_DEST="$HOME/.Trash/$(basename "$OUTPUT_DIR").$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$HOME/.Trash"
    echo "==> moving existing output to trash: $TRASH_DEST"
    mv "$OUTPUT_DIR" "$TRASH_DEST"
fi
"$XCRUN_BIN" xcodebuild -create-xcframework \
    -library "$IOS_DEVICE_DIR/ChuanqiCut.a" -headers "$HEADERS_DIR" \
    -library "$IOS_SIM_DIR/ChuanqiCut.a"    -headers "$HEADERS_DIR" \
    -library "$MACOS_DIR/ChuanqiCut.a"      -headers "$HEADERS_DIR" \
    -output "$OUTPUT_DIR"

# ---- 验证三切片存在且架构正确 ----
echo
echo "==> verify slices"
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "error: xcframework not found at $OUTPUT_DIR" >&2
    exit 7
fi
echo "---- xcframework tree ----"
find "$OUTPUT_DIR" -maxdepth 2 -type d | sort
for lib in "$OUTPUT_DIR"/*/ChuanqiCut.a; do
    [ -e "$lib" ] || continue
    echo "---- $lib ----"
    "$XCRUN_BIN" lipo -info "$lib"
    file "$lib"
done
echo "---- Info.plist (AvailableLibraries) ----"
"$XCRUN_BIN" plutil -p "$OUTPUT_DIR/Info.plist" 2>/dev/null || true

# ---- 消费者侧链接冒烟：证明「打得出来」也「能被消费」-----------------------
# xcodebuild 成功只说明 .a 是合法 Mach-O；App 能不能真的 link 起来并跑通，必须试一次。
# 教训：这类“假绿”项目已经踩过一次（CORE-006 编译 7/7 全绿但接口是断的）。
# iOS 切片本机跑不了（需设备/模拟器），只对 macOS 切片做；宿主系统版本低于部署目标时
# 跳过——二进制的 min-version 高于系统版本会直接加载失败，报的是误导性的 dyld 错误。
if [ "$SMOKE_LINK" -eq 1 ]; then
    echo
    echo "==> consumer smoke-link test"
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "    skip: host is not macOS"
    else
        smoke_lib="$(find "$OUTPUT_DIR" -path "*macos*" -name "ChuanqiCut.a" | head -1)"
        if [ -z "$smoke_lib" ]; then
            echo "    skip: no macOS slice found"
        else
            smoke_headers="$(dirname "$smoke_lib")/Headers"
            smoke_host_ver="$(sw_vers -productVersion)"
            smoke_host_arch="$(uname -m)"
            # 仅当 deploy <= host 时该二进制可被加载
            if [ "$(printf '%s\n%s\n' "$MACOS_DEPLOY" "$smoke_host_ver" | sort -V | head -1)" != "$MACOS_DEPLOY" ]; then
                echo "    skip: host macOS $smoke_host_ver < deploy target $MACOS_DEPLOY"
            else
                smoke_tmp="$(mktemp -d)/cq_smoke_link"
                echo "    host  : macOS $smoke_host_ver ($smoke_host_arch)"
                echo "    lib   : $(basename "$smoke_lib")"
                # PAL/Apple 后端依赖这些系统框架；缺一个都会在 link 期炸出来，
                # 这正是“只打不验”发现不了的问题。
                if ! clang++ -std=c++20 -arch "$smoke_host_arch" \
                        -mmacosx-version-min="$MACOS_DEPLOY" \
                        -I "$smoke_headers" \
                        "$ROOT_DIR/tools/build/smoke_link.cpp" \
                        "$smoke_lib" \
                        -framework Metal -framework AVFoundation -framework CoreMedia \
                        -framework VideoToolbox -framework CoreVideo \
                        -o "$smoke_tmp"; then
                    echo "error: consumer link failed; see above" >&2
                    exit 9
                fi
                smoke_out="$("$smoke_tmp")"
                echo "    output: $smoke_out"
                if [ "$smoke_out" != "StatusToString(kOk) = OK" ]; then
                    echo "error: unexpected smoke output" >&2
                    exit 9
                fi
                echo "    ok: library links and runs"
                rm -f "$smoke_tmp"
            fi
        fi
    fi
fi

echo
echo "==> done. XCFramework at: $OUTPUT_DIR"
