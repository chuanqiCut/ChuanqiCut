#!/usr/bin/env bash
# =============================================================================
# build_ffmpeg_demux.sh — FFmpeg「demux 档位」最小构建（DEPS-010/012）
# -----------------------------------------------------------------------------
# 目标（manifest ffmpeg profile=demux，features=[demux,seek,probe,bitstream-filter]）：
#   只要 libavformat + libavutil + libavcodec 的 parser / bitstream-filter 部分。
#   不要 decoder / encoder / filter / swscale / swresample / avdevice / postproc /
#   任何 GPL 组件 / 任何网络协议。产物 LGPL-2.1+。
#
# 产物（每个 sdk-arch 一个目录，头文件随产物保存，Pod vendored 直接用）：
#   third_party/prebuilt/ffmpeg/<ver>/demux/<sdk>-<arch>/libffmpeg.a
#   third_party/prebuilt/ffmpeg/<ver>/demux/<sdk>-<arch>/include/
# 汇总（供 Pod vendored_libraries 引用，三个 slice）：
#   third_party/prebuilt/ffmpeg/<ver>/demux/libffmpeg.xcframework
#     macosx        = x86_64 + arm64（lipo 合一）
#     iphoneos      = arm64
#     iphonesimulator = x86_64 + arm64（lipo 合一）
#
# 用法：
#   tools/build/build_ffmpeg_demux.sh --sdk <macosx|iphoneos|iphonesimulator> \
#                                     --arch <x86_64|arm64> [--debug] [--no-xcframework]
#   --debug : -O0 -g、不 strip —— 源码级调试时用产物替换正常档（DEPS-012 调试路径）
#
# 前置（不在本脚本内，见 DEPS-002 / ADR-0008）：
#   源码已 checkout 到 pin_ref（tag n9.0.2）：
#     git clone --depth 1 --branch n9.0.2 https://github.com/FFmpeg/FFmpeg.git third_party/src/ffmpeg
#   本机无 nasm/yasm → x86_64 必须 --disable-x86asm；arm64 用 Apple 原生 arm64 汇编，无需外部工具。
#
# 合并方法（baselines.md 已验证的坑，勿改回 libtool -static）：
#   libutil/libavformat/libavcodec 内含同名 .o（utils.o、cpu.o、version.o、codec.o 等），
#   libtool -static / BSD ar 直接合并会丢同名成员符号。必须：ar x 分库解包 →
#   重命名 <lib>_<base>.o → ar rcs 合并 → 校验 duplicate members = 0。
#
# 本脚本**不决定最终链接方式**（静态/动态）——那由 LGPL 处置 ADR 拍板（ARCH-002 §5.1）。
# =============================================================================
set -euo pipefail

FF_VERSION="9.0.2"
PIN_REF="946fcce07b6dcd0331c8cc609192aeff5e1924f8"   # tag n9.0.2

SDK=""        # macosx | iphoneos | iphonesimulator
ARCH=""       # x86_64 | arm64
DEBUG=0
DO_XCFRAMEWORK=1

usage() { grep '^# 用法' -A3 "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --sdk)   SDK="$2"; shift 2 ;;
    --arch)  ARCH="$2"; shift 2 ;;
    --debug) DEBUG=1; shift ;;
    --no-xcframework) DO_XCFRAMEWORK=0; shift ;;
    -h|--help) usage ;;
    *) echo "!! 未知参数: $1" >&2; usage ;;
  esac
done

case "$SDK" in
  macosx|iphoneos|iphonesimulator) ;;
  *) echo "!! --sdk 必须是 macosx|iphoneos|iphonesimulator" >&2; usage ;;
esac
case "$ARCH" in
  x86_64|arm64) ;;
  *) echo "!! --arch 必须是 x86_64|arm64" >&2; usage ;;
esac
if [ "$SDK" = "iphoneos" ] && [ "$ARCH" = "x86_64" ]; then
  echo "!! iphoneos 不支持 x86_64（真机只有 arm64）" >&2; exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/third_party/src/ffmpeg"
OUT_ROOT="$ROOT/third_party/prebuilt/ffmpeg/$FF_VERSION/demux"
OUT="$OUT_ROOT/$SDK-$ARCH"
BUILD="$(mktemp -d)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$BUILD" "$STAGE" 2>/dev/null || true' EXIT

# --- 0) 校验源码已 checkout 到正确 commit（ADR-0008：拉得到即证明 commit 真实存在）---
ACTUAL="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo "")"
if [ "$ACTUAL" != "$PIN_REF" ]; then
  echo "!! 源码 commit 不匹配：期望 $PIN_REF，实际 ${ACTUAL:-<非 git/缺失>}" >&2
  echo "   先执行：git -C $SRC checkout $PIN_REF" >&2
  exit 1
fi

# --- 1) configure：demux 档位裁剪（out-of-tree）---
# 裁剪清单：只开「demux 档位」真正需要的容器/解析器/比特流过滤器，别多开。
# 若某平台需要更多格式，在此增删即可（这是产品决策，不是治理红线）。
DEMUXERS=(mov matroska avi flv h264 hevc mpegts mpegvideo wav aiff mp3 aac ogg flac asf rm m4v amr ac3 eac3 caf dts vc1)
PARSERS=(h264 hevc aac av1 mpeg4video mpegvideo mpegaudio vc1 vp9 opus flac vorbis ac3 eac3 mlp truehd dts dca mjpeg)
BSFS=(extract_extradata aac_adtstoasc mpeg4_unpack_bframes h264_mp4toannexb hevc_mp4toannexb vp9_superframe opus eac3_core)

CONF_FLAGS=(
  --prefix="$STAGE"
  --disable-programs --disable-doc --disable-sdl2
  --disable-avdevice --disable-swscale --disable-swresample --disable-avfilter
  --disable-network --disable-iconv --disable-bzlib --disable-lzma --disable-zlib
  --disable-libx264 --disable-libx265 --disable-libvpx --disable-libmp3lame
  --disable-decoders --disable-encoders --disable-hwaccels
  --disable-muxers --disable-outdevs --disable-indevs --disable-devices
  --enable-small --disable-everything
)
for d in "${DEMUXERS[@]}"; do CONF_FLAGS+=(--enable-demuxer="$d"); done
for p in "${PARSERS[@]}"; do CONF_FLAGS+=(--enable-parser="$p"); done
for b in "${BSFS[@]}"; do CONF_FLAGS+=(--enable-bsf="$b"); done
CONF_FLAGS+=(--enable-protocol=file --enable-protocol=pipe)

# Apple 交叉编译：SDK sysroot + 部署目标（macOS ≥11 / iOS ≥16，低于产物消费方
# podspec 的 deployment target 即可，静态库由链接方最终决定部署目标）。
SDKROOT_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
case "$SDK" in
  macosx)
    MIN_FLAG="-mmacosx-version-min=11.0" ;;
  iphoneos)
    MIN_FLAG="-miphoneos-version-min=16.0" ;;
  iphonesimulator)
    MIN_FLAG="-mios-simulator-version-min=16.0" ;;
esac
CONF_FLAGS+=(--enable-cross-compile --target-os=darwin
             --extra-cflags="-arch $ARCH -isysroot $SDKROOT_PATH $MIN_FLAG"
             --extra-ldflags="-arch $ARCH -isysroot $SDKROOT_PATH $MIN_FLAG")
if [ "$ARCH" = "x86_64" ]; then
  CONF_FLAGS+=(--disable-x86asm)   # 本机无 nasm/yasm（baselines DEPS-010）
fi
if [ "$DEBUG" = "1" ]; then
  CONF_FLAGS+=(--extra-cflags="-O0 -g")
else
  CONF_FLAGS+=(--disable-debug)
fi

echo ">> FFmpeg demux build: sdk=$SDK arch=$ARCH debug=$DEBUG"
echo "   src=$SRC  pin_ref=$PIN_REF"
mkdir -p "$BUILD"
cd "$BUILD"
echo ">> configure (sdk=$SDK arch=$ARCH) ..."
"$SRC/configure" "${CONF_FLAGS[@]}"

# --- 2) 构建静态库 ---
echo ">> make -j ..."
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
echo ">> make install (staging) ..."
make install

# --- 3) 合并为单个 convenience archive libffmpeg.a ---
# ar x 分库解包 → 重命名 <lib>_<base>.o → ar rcs（baselines 已验证：libtool -static 会丢同名成员符号）
MERGE="$(mktemp -d)"
mkdir -p "$MERGE/avutil" "$MERGE/avformat" "$MERGE/avcodec"
( cd "$MERGE/avutil"    && ar x "$STAGE/lib/libavutil.a"    && for f in *.o; do mv "$f" "avutil_$f"; done )
( cd "$MERGE/avformat"  && ar x "$STAGE/lib/libavformat.a"  && for f in *.o; do mv "$f" "avformat_$f"; done )
( cd "$MERGE/avcodec"   && ar x "$STAGE/lib/libavcodec.a"   && for f in *.o; do mv "$f" "avcodec_$f"; done )
mkdir -p "$OUT"
ar rcs "$OUT/libffmpeg.a" "$MERGE/avutil"/*.o "$MERGE/avformat"/*.o "$MERGE/avcodec"/*.o

# 同名校验：重命名后不应存在任何重复成员（有 = 有 .o 没进库，符号丢失前兆）
DUPES="$(cat "$MERGE/avutil"/*.o "$MERGE/avformat"/*.o "$MERGE/avcodec"/*.o >/dev/null; ar t "$OUT/libffmpeg.a" | sort | uniq -d)"
if [ -n "$DUPES" ]; then
  echo "!! 合并产物存在重复成员（预期 0）：" >&2
  echo "$DUPES" >&2
  exit 1
fi

# --- 4) 头文件随产物保存（Pod vendored / CMake binary 路径都从这里取）---
rm -rf "$OUT/include"
cp -R "$STAGE/include" "$OUT/include"

# --- 5) strip（debug 档保留符号）---
if [ "$DEBUG" != "1" ]; then
  strip -S "$OUT/libffmpeg.a"
fi

# --- 6) 测量结果 ---
SIZE=$(stat -f%z "$OUT/libffmpeg.a" 2>/dev/null || stat -c%s "$OUT/libffmpeg.a")
SHA=$(shasum -a 256 "$OUT/libffmpeg.a" | awk '{print $1}')
echo ">> 产物：$OUT/libffmpeg.a"
echo "   size_bytes = $SIZE"
echo "   sha256     = $SHA"

# --- 7) GPL / 外部编解码符号扫描 ---
# 模式必须用 lib<name> 前缀（baselines 教训：裸格式名会命中 FFmpeg 自身 LGPL 代码，假阳性）。
echo ">> GPL 符号扫描 (nm)："
if nm "$OUT/libffmpeg.a" 2>/dev/null | grep -Ei 'libx264|libx265|libxvid|libvorbis|libtheora|libvpx|libopenjpeg|libgsm|libopencore|libtwolame|libvo_aac|libaacplus|libilbc|libsnappy|libzimg|libcdio|libopenh264|libwebp|_gpl|gpl' | grep -v 'T _ff_'; then
  echo "!! 发现疑似 GPL/外部编解码符号，需人工复核" >&2
  exit 1
else
  echo "   (无 GPL / 外部编解码符号)"
fi

echo ">> done: $SDK-$ARCH  size_bytes=$SIZE"
echo "   回填 third_party/manifest.toml 的 ffmpeg artifact（size/sha256）。"

# --- 8) xcframework 汇总（仅正常档非 debug 主动触发，或显式 --no-xcframework 关闭）---
if [ "$DO_XCFRAMEWORK" = "1" ]; then
  "$ROOT/tools/build/make_ffmpeg_xcframework.sh" "$FF_VERSION" "$SDK-$ARCH" || \
    echo "!! xcframework 组装失败（不影响单架构产物，可稍后单独跑 make_ffmpeg_xcframework.sh）" >&2
fi
