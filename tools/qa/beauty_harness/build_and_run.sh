#!/bin/bash
# build_and_run.sh — CAM-012 磨皮 kernel 宿主验证（macOS，非真机）
#
# 做什么：把 iOSApp 的 beauty_bilateral.metal 用 metal -fcikernel 编成
# metallib（与 Xcode 编译期内建同源），连同**真**的 BeautyKernel.swift 与
# SharedUI 的 CameraBeauty.swift 组成完整生产链路，在本机 GPU 上跑算法级
# 断言（profile 单调 / GPU 方差单调 / 保边 / 1080p 耗时）。
#
# 前置：Xcode 命令行工具 + 支持 Metal 的 GPU（本机 Intel Iris Plus 640 实测可用）。
# 用法：tools/qa/beauty_harness/build_and_run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"        # tools/qa/beauty_harness
REPO="$(cd "$ROOT/../../.." && pwd)"         # 仓库根
EFFECTS="$REPO/apps/apple/ios/iOSApp/Camera/Effects"
SHAREDUI_CAM="$REPO/apps/apple/packages/SharedUI/Sources/SharedUI/Camera"
WORK="$(mktemp -d /tmp/cq_beauty_harness.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> [1/4] metal -fcikernel 一步编出 metallib（CI kernel 必须 -fcikernel，P40；"
echo "    本机工具链「-c 出 air 再 metallib 链接」会得到空库，须一步 -o）"
xcrun metal -fcikernel "$EFFECTS/beauty_bilateral.metal" -o "$WORK/beauty.metallib"

echo "==> [2/4] SharedUI stub 模块（真 CameraBeauty.swift，P39 技法）"
mkdir -p "$WORK/stub"
xcrun swiftc -parse-as-library -emit-module -module-name SharedUI \
    "$SHAREDUI_CAM/CameraBeauty.swift" -o "$WORK/stub/SharedUI.swiftmodule"
# -emit-module 只有接口没有代码，补 -emit-object 供链接。
xcrun swiftc -parse-as-library -emit-object -module-name SharedUI \
    "$SHAREDUI_CAM/CameraBeauty.swift" -o "$WORK/stub/SharedUI.o"

echo "==> [3/4] 编译 harness（真 BeautyKernel.swift + main.swift）"
xcrun swiftc "$ROOT/main.swift" "$EFFECTS/BeautyKernel.swift" \
    -I "$WORK/stub" "$WORK/stub/SharedUI.o" -o "$WORK/harness"

echo "==> [4/4] 运行（macOS 宿主 GPU）"
"$WORK/harness" "$WORK/beauty.metallib"
