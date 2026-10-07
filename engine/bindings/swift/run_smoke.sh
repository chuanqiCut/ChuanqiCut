#!/usr/bin/env bash
# ChuanqiCut — Swift 调用链路独立验收（BIND-002）
#
# 用 swiftc 直接编译 Swift 绑定 + 显式链接内核静态库，绕过 SwiftPM 的
# binaryTarget 问题（见 Tests/SwiftSmoke/main.swift 文件头说明），
# 单独把「Swift 能不能真调用内核」验清楚。
#
# 用法：bindings/swift/run_smoke.sh
# 前置：先跑 tools/build/build_core_apple.sh --config=Release（产出 xcframework）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

XCFW="$ROOT_DIR/build/apple/ChuanqiCut.xcframework"
if [ ! -d "$XCFW" ]; then
    echo "error: xcframework not found at $XCFW" >&2
    echo "       run: tools/build/build_core_apple.sh --config=Release" >&2
    exit 4
fi

# 本机架构决定用哪个切片（与 build_core_apple.sh 的切片命名一致）
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    x86_64) SLICE="macos-arm64_x86_64" ;;
    arm64)  SLICE="macos-arm64_x86_64" ;;   # 通用二进制里含 arm64
    *) echo "error: unsupported arch $HOST_ARCH" >&2; exit 4 ;;
esac
LIB_DIR="$XCFW/$SLICE"

if [ ! -f "$LIB_DIR/libChuanqiCut.a" ]; then
    echo "error: $LIB_DIR/libChuanqiCut.a not found" >&2
    exit 4
fi

OUT_DIR="$(mktemp -d)"
OUT="$OUT_DIR/cq_swift_smoke"

echo "==> ChuanqiCut Swift smoke"
echo "    swift : $(xcrun --find swiftc)"
echo "    lib   : $LIB_DIR/libChuanqiCut.a"
echo "    slice : $SLICE"

# 内核的部署目标是 macOS 15.4（ADR-0010）。不显式指定 target 时 swiftc 按 15.0 链接，
# 会对每个 .o 报 "built for newer macOS version (15.4) than being linked (15.0)"。
# 告警要消除（项目纪律：不留告警），故显式对齐部署目标。
DEPLOY="15.4"

# -I 指向含 module.modulemap 的目录，使 `import CChuanqiCut` 可用。
#
# 库名已改为 Unix 标准的 libChuanqiCut.a（2026-09-30），故 -L/-l 可用：
# 此前叫 ChuanqiCut.a 时 `-lChuanqiCut` 找不到 —— `-lNAME` 只匹配 `libNAME.a`。
# -lc++ 仍然需要：内核是 C++20。
# 系统框架同样要显式列出（与 ChuanqiCut.podspec 的 ss.frameworks 一致）：
# smoke 现在会创建 Preview → 拉入 cq_sdk_preview.o → 传递拉入 PAL 图形/解码
# TU → VideoToolbox / CoreMedia / Metal 等符号必须有归属（2026-10-02 实测）。
FRAMEWORKS="Foundation Metal AVFoundation CoreMedia VideoToolbox CoreVideo \
CoreGraphics AudioToolbox QuartzCore IOSurface"
FW_FLAGS=()
for fw in $FRAMEWORKS; do FW_FLAGS+=(-framework "$fw"); done

xcrun swiftc -O \
    -target "${HOST_ARCH}-apple-macosx${DEPLOY}" \
    -I "$SCRIPT_DIR/Sources/CChuanqiCut/include" \
    "$SCRIPT_DIR/Sources/ChuanqiCut/ChuanqiCut.swift" \
    "$SCRIPT_DIR/Sources/ChuanqiCut/Time.swift" \
    "$SCRIPT_DIR/Sources/ChuanqiCut/Previewer.swift" \
    "$SCRIPT_DIR/Sources/ChuanqiCut/Timeline.swift" \
    "$SCRIPT_DIR/Sources/ChuanqiCut/Session.swift" \
    "$SCRIPT_DIR/Tests/SwiftSmoke/main.swift" \
    -L "$LIB_DIR" -lChuanqiCut -lc++ "${FW_FLAGS[@]}" \
    -o "$OUT"

echo "==> run"
"$OUT"
rc=$?
rm -f "$OUT"
rmdir "$OUT_DIR" 2>/dev/null || true
exit $rc
