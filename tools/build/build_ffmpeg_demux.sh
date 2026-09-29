#!/usr/bin/env bash
# =============================================================================
# build_ffmpeg_demux.sh — FFmpeg「demux 档位」最小构建（DEPS-010）
# -----------------------------------------------------------------------------
# 目标（manifest ffmpeg profile=demux，features=[demux,seek,probe,bitstream-filter]）：
#   只要 libavformat + libavutil + libavcodec 的 parser / bitstream-filter 部分。
#   不要 decoder / encoder / filter / swscale / swresample / avdevice / postproc /
#   任何 GPL 组件 / 任何网络协议。产物 LGPL-2.1+，单库 < 3MB（strip 后）。
#
# 产物：把三个静态库合并为一个 convenience archive：
#   prebuilt/ffmpeg/9.0.2/demux/apple-<arch>/libffmpeg.a
#
# 前置（不在本脚本内，见 DEPS-002 / ADR-0008）：
#   源码已 checkout 到 pin_ref 946fcce07b6dcd0331c8cc609192aeff5e1924f8（tag n9.0.2）：
#     git clone --depth 1 --branch n9.0.2 https://github.com/FFmpeg/FFmpeg.git third_party/src/ffmpeg
#   本机无 nasm/yasm → 必须 --disable-x86asm。
#
# 用法：
#   tools/build/build_ffmpeg_demux.sh [x86_64|arm64] [源码目录]
#   arch 缺省 x86_64；源码目录缺省 third_party/src/ffmpeg
#
# 注意：本脚本**不决定最终链接方式**（静态/动态/对象归档）——那由链接策略（传哲+法务）
#   在别处拍板。这里只构建出可测的产物并测量体积 + GPL 符号。
#
# 实现要点：out-of-tree 构建（BUILD 在源码树之外），避免改动源码树里的已有产物、
#   也规避某些环境对「批量删除」的安全拦截。
# =============================================================================
set -euo pipefail

ARCH="${1:-x86_64}"
SRC="${2:-third_party/src/ffmpeg}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$(cd "$ROOT/$SRC" 2>/dev/null || echo "$SRC")"

PIN_REF="946fcce07b6dcd0331c8cc609192aeff5f8"
BUILD="$(mktemp -d)"
STAGE="$(mktemp -d)"
OUT="$ROOT/prebuilt/ffmpeg/9.0.2/demux/apple-$ARCH"
trap 'rm -rf "$BUILD" "$STAGE" 2>/dev/null || true' EXIT

# 裁剪清单：只开「demux 档位」真正需要的容器/解析器/比特流过滤器，别多开。
# 若某平台需要更多格式，在此增删即可（这是产品决策，不是治理红线）。
DEMUXERS=(mov matroska avi flv h264 hevc mpegts mpegvideo wav aiff mp3 aac ogg flac asf rm m4v amr ac3 eac3 caf dts vc1)
PARSERS=(h264 hevc aac av1 mpeg4video mpegvideo mpegaudio vc1 vp9 opus flac vorbis ac3 eac3 mlp truehd dts dca mjpeg)
BSFS=(extract_extradata aac_adtstoasc mpeg4_unpack_bframes h264_mp4toannexb hevc_mp4toannexb vp9_superframe opus eac3_core)

echo ">> FFmpeg demux build: arch=$ARCH  src=$SRC  pin_ref=$PIN_REF"

# --- 0) 校验源码已 checkout 到正确 commit（ADR-0008：拉得到即证明 commit 真实存在）---
ACTUAL="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo "")"
if [ "$ACTUAL" != "$PIN_REF" ]; then
  echo "!! 源码 commit 不匹配：期望 $PIN_REF，实际 ${ACTUAL:-<非 git/缺失>}" >&2
  echo "   先执行：git -C $SRC checkout $PIN_REF" >&2
  exit 1
fi

# --- 1) configure：demux 档位裁剪（out-of-tree）---
CONF_FLAGS=(
  --prefix="$STAGE"
  --disable-programs --disable-doc --disable-sdl2
  --disable-avdevice --disable-swscale --disable-swresample --disable-avfilter
  --disable-network --disable-iconv --disable-bzlib --disable-lzma --disable-zlib
  --disable-libx264 --disable-libx265 --disable-libvpx --disable-libmp3lame
  --disable-decoders --disable-encoders --disable-hwaccels
  --disable-muxers --disable-outdevs --disable-indevs --disable-devices
  --disable-x86asm --enable-small --disable-everything
)
for d in "${DEMUXERS[@]}"; do CONF_FLAGS+=(--enable-demuxer="$d"); done
for p in "${PARSERS[@]}"; do CONF_FLAGS+=(--enable-parser="$p"); done
for b in "${BSFS[@]}"; do CONF_FLAGS+=(--enable-bsf="$b"); done
CONF_FLAGS+=(--enable-protocol=file --enable-protocol=pipe)

if [ "$ARCH" = "arm64" ]; then
  CONF_FLAGS+=(--arch=arm64 --enable-cross-compile --target-os=darwin
               --extra-cflags="-arch arm64" --extra-ldflags="-arch arm64")
fi

mkdir -p "$BUILD"
cd "$BUILD"
echo ">> configure (arch=$ARCH) ..."
"$SRC/configure" "${CONF_FLAGS[@]}"

# --- 2) 构建静态库 ---
echo ">> make -j ..."
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo ">> make install (staging) ..."
make install

# --- 3) strip + 合并为单个 convenience archive libffmpeg.a ---
strip -S "$STAGE/lib/"*.a
mkdir -p "$OUT"
echo ">> libtool -static -> $OUT/libffmpeg.a"
libtool -static -o "$OUT/libffmpeg.a" \
  "$STAGE/lib/libavformat.a" \
  "$STAGE/lib/libavutil.a" \
  "$STAGE/lib/libavcodec.a"

# --- 4) 测量结果 ---
SIZE=$(stat -f%z "$OUT/libffmpeg.a" 2>/dev/null || stat -c%s "$OUT/libffmpeg.a")
SHA=$(shasum -a 256 "$OUT/libffmpeg.a" | awk '{print $1}')
echo ">> 产物：$OUT/libffmpeg.a"
echo "   size_bytes = $SIZE"
echo "   sha256     = $SHA"

# --- 5) GPL / 外部编解码符号扫描 ---
echo ">> GPL 符号扫描 (nm)："
if nm "$OUT/libffmpeg.a" 2>/dev/null | grep -Ei 'x264|x265|libx26|postproc|libvpx|libmp3lame|libfdk' | grep -v 'T _ff_'; then
  echo "!! 发现疑似 GPL/外部编解码符号，需人工复核" >&2
else
  echo "   (无 GPL / 外部编解码符号)"
fi

echo ">> done. 把上面 size_bytes / sha256 回填 third_party/manifest.toml 的 ffmpeg artifact。"
