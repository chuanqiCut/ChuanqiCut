#!/usr/bin/env bash
# =============================================================================
# make_ffmpeg_xcframework.sh — 把已编好的 demux slice 汇总为 xcframework
# -----------------------------------------------------------------------------
# 输入：third_party/prebuilt/ffmpeg/<ver>/demux/<sdk>-<arch>/libffmpeg.a
#       （由 build_ffmpeg_demux.sh --sdk X --arch Y 产出）
# 输出：third_party/prebuilt/ffmpeg/<ver>/demux/libffmpeg.xcframework
#       macosx          = x86_64 + arm64（lipo 合一）
#       iphoneos        = arm64
#       iphonesimulator = x86_64 + arm64（lipo 合一）
#
# 用法：
#   tools/build/make_ffmpeg_xcframework.sh [版本号] [刚完成的 sdk-arch（仅日志提示用）]
#   版本号缺省 9.0.2。可重复执行：每次全量重组当前已存在的 slice。
#
# 规则：macOS / simulator 需要两个架构齐全才出对应 slice（避免 xcframework 内
#   同 platform 重复条目）；缺架构时打印警告并用现有架构继续，构建机补齐后重跑即可。
# =============================================================================
set -euo pipefail

FF_VERSION="${1:-9.0.2}"
LAST_BUILT="${2:-}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEMUX="$ROOT/third_party/prebuilt/ffmpeg/$FF_VERSION/demux"
OUT="$DEMUX/libffmpeg.xcframework"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

have() { [ -f "$DEMUX/$1/libffmpeg.a" ]; }

echo ">> 汇总 xcframework: $OUT"
[ -n "$LAST_BUILT" ] && echo "   (本次新完成 slice: $LAST_BUILT)"

ARGS=()
mkdir -p "$WORK/macosx" "$WORK/iphonesimulator"   # lipo -output 不自动建父目录

# macOS：x86_64 + arm64 → lipo 合一
if have macosx-x86_64 && have macosx-arm64; then
  lipo -create "$DEMUX/macosx-x86_64/libffmpeg.a" "$DEMUX/macosx-arm64/libffmpeg.a" \
       -output "$WORK/macosx/libffmpeg.a"
  ARGS+=(-library "$WORK/macosx/libffmpeg.a" -headers "$DEMUX/macosx-arm64/include")
elif have macosx-x86_64 || have macosx-arm64; then
  echo "!! macOS 只有一个架构，缺：" >&2
  have macosx-x86_64 || echo "   macosx-arm64（tools/build/build_ffmpeg_demux.sh --sdk macosx --arch arm64）" >&2
  have macosx-arm64  || echo "   macosx-x86_64（tools/build/build_ffmpeg_demux.sh --sdk macosx --arch x86_64）" >&2
  echo "   本轮不生成 macosx slice，其余照常。" >&2
else
  echo ">> 无 macOS slice，跳过"
fi

# iOS 真机：arm64
if have iphoneos-arm64; then
  ARGS+=(-library "$DEMUX/iphoneos-arm64/libffmpeg.a" -headers "$DEMUX/iphoneos-arm64/include")
else
  echo ">> 缺 iphoneos-arm64（--sdk iphoneos --arch arm64），本轮不生成 iphoneos slice"
fi

# iOS 模拟器：x86_64 + arm64 → lipo 合一
if have iphonesimulator-x86_64 && have iphonesimulator-arm64; then
  lipo -create "$DEMUX/iphonesimulator-x86_64/libffmpeg.a" "$DEMUX/iphonesimulator-arm64/libffmpeg.a" \
       -output "$WORK/iphonesimulator/libffmpeg.a"
  ARGS+=(-library "$WORK/iphonesimulator/libffmpeg.a" -headers "$DEMUX/iphonesimulator-arm64/include")
elif have iphonesimulator-x86_64 || have iphonesimulator-arm64; then
  echo "!! simulator 只有一个架构，缺：" >&2
  have iphonesimulator-x86_64 || echo "   iphonesimulator-arm64（--sdk iphonesimulator --arch arm64）" >&2
  have iphonesimulator-arm64  || echo "   iphonesimulator-x86_64（--sdk iphonesimulator --arch x86_64）" >&2
  echo "   本轮不生成 iphonesimulator slice，其余照常。" >&2
else
  echo ">> 无 simulator slice，跳过"
fi

if [ ${#ARGS[@]} -eq 0 ]; then
  echo "!! 没有任何可用 slice，无法生成 xcframework" >&2
  exit 1
fi

rm -rf "$OUT"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT" >/dev/null

# 同步到 engine/vendor/（CocoaPods vendored_libraries 沙箱实测坑：不接受 pod root 外的
# `../third_party` 相对路径，静默忽略不接进 Pods 工程 → Pod 必须引用 engine 内路径；
# 本脚本每次构建后覆盖拷贝，单一源头不漂移。vendor 目录由 .gitignore 盖住，产物不入 git。)
VENDOR="$ROOT/engine/vendor"
mkdir -p "$VENDOR"
rm -rf "$VENDOR/libffmpeg.xcframework"
cp -R "$OUT" "$VENDOR/libffmpeg.xcframework"
echo ">> 已同步 vendor: $VENDOR/libffmpeg.xcframework"

echo ">> xcframework 内容："
ls "$OUT"
echo ">> done."
