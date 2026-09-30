#!/usr/bin/env bash
# ChuanqiCut — 为 Swift 绑定准备 XCFramework（BIND-002）
#
# SwiftPM 的 binaryTarget 要求 xcframework 位于 package 内，故这里把构建产物
# 复制一份到 bindings/swift/Frameworks/。
#
# ⚠️ 用**复制**而不是符号链接：链接时 SPM/ld 需要真实文件树；
#    且产物本身不入版本库（见 .gitignore），复制件同理。
#
# 用法：bindings/swift/prepare.sh
# 前置：tools/build/build_core_apple.sh --config=Release

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SRC="$ROOT_DIR/build/apple/ChuanqiCut.xcframework"
DEST="$SCRIPT_DIR/Frameworks/ChuanqiCut.xcframework"

if [ ! -d "$SRC" ]; then
    echo "error: xcframework not found at $SRC" >&2
    echo "       run: tools/build/build_core_apple.sh --config=Release" >&2
    exit 4
fi

mkdir -p "$SCRIPT_DIR/Frameworks"

# 旧副本先移入废纸篓（不用 rm -rf：不可逆，且这些是脚本自动生成的目录）。
if [ -e "$DEST" ]; then
    TRASH_DEST="$HOME/.Trash/ChuanqiCut.xcframework.$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$HOME/.Trash"
    echo "==> moving existing copy to trash: $TRASH_DEST"
    mv "$DEST" "$TRASH_DEST"
fi

cp -R "$SRC" "$DEST"
echo "==> prepared: $DEST"
find "$DEST" -maxdepth 2 -name "*.a" -o -maxdepth 1 -name "Info.plist" | sort
