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
#
# ⚠️ PARSERS 不含 hevc / mpeg4video / opus（2026-10-11 DEPS-012 链接闭合实测）：
#   FFmpeg 9.0.2 上游 libavcodec/Makefile 在这三处不闭合 ——
#   * hevc_parser.o / opus_parser.o 不在任何 OBJS 规则里，但 parser 注册表引用其符号；
#   * mpeg4video_parser 显式拉 mpeg4videodec/ituh263dec，其内部又被 decoder 宏
#     裁掉关键函数（ff_set_qscale 等），静态链接必炸。
#   容器 demux（mov/mkv/ts/ogg/flv...）不依赖这三个 parser，容器内 hevc/opus 流不受影响。
DEMUXERS=(mov matroska avi flv h264 hevc mpegts mpegvideo wav aiff mp3 aac ogg flac asf rm m4v amr ac3 eac3 caf dts vc1)
PARSERS=(h264 aac av1 mpegvideo mpegaudio vc1 flac vorbis ac3 eac3 mlp truehd dts dca mjpeg)
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
CONF_FLAGS+=(--arch="$ARCH"   # 不给会默认本机 arch：arm64 交叉编时 configure 误判 x86_64 去找 nasm
             --enable-cross-compile --target-os=darwin
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
# 逐成员提取 + 序号化重命名（baselines 两层同名坑，2026-10-12 补第二层）：
#   * 跨库同名（utils.o 在 avutil/avformat/avcodec 各一）→ <lib>_ 前缀；
#   * **同库同名**（libavutil.a 内 cpu.o 有两份：cpu.c 通用版 + x86/cpu.c 平台版，
#     ar 成员允许重名）→ **不能用 bash 的 ar x 逐成员提取**：`ar x lib member` 对同名
#     成员永远只取**第一个**，第二份（x86/cpu.c 平台版）照样丢，ff_get_cpu_flags_x86
#     仍 undefined。故用 python 按 ar 格式逐偏移提取（同名成员天然全保留，支持 BSD
#     `#1/` 长名与 __.SYMDEF 跳过）。
extract_ar() {
  python3 - "$1" "$2" "$3" << 'PYEOF'
import sys, os
ar_path, prefix, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(ar_path, 'rb').read()
if data[:8] not in (b'! <arch>\n', b'!<arch>\n'):   # 系统 ar 带空格 / FFmpeg $(AR) 不带
    sys.exit(f'not an ar archive: {ar_path} size={len(data)} head={data[:24]!r}')
os.makedirs(out_dir, exist_ok=True)
off, i = 8, 0
while off < len(data):
    if len(data) - off < 60: break
    hdr = data[off:off+60]
    name = hdr[0:16].decode('ascii', 'replace').strip()
    size = int(hdr[48:58].decode().strip())
    body = off + 60
    if name.startswith('__'):          # __.SYMDEF* 等符号表成员，跳过
        off = body + size + (size & 1); continue
    real = name
    if name.startswith('#1/'):         # BSD 长名：真实名存于成员体前 N 字节
        n = int(name[3:])
        real = data[body:body+n].decode('ascii', 'replace').rstrip('\x00')
        body += n; size -= n
    blob = data[body:body+size]
    out = os.path.join(out_dir, f'{prefix}_{i:05d}_{os.path.basename(real)}')
    open(out, 'wb').write(blob)
    i += 1
    off = body + size + (size & 1)
print(f'   {prefix}: {i} members')
PYEOF
}
MERGE="$(mktemp -d)"
extract_ar "$STAGE/lib/libavutil.a"   avutil   "$MERGE/avutil"
extract_ar "$STAGE/lib/libavformat.a" avformat "$MERGE/avformat"
extract_ar "$STAGE/lib/libavcodec.a"  avcodec  "$MERGE/avcodec"
mkdir -p "$OUT"
# ⚠️ 必须先删旧 archive：ar r 对已存在的 archive 是「插入或替换」而非重建，
# 上次构建的残留成员（甚至旧裁剪清单的成员）会叠加进本次产物——2026-10-12 实测
# arm64 闭合失败即由此起（v1 裸名 parsers.o 残留，链接器先拉入旧 config 成员）。
rm -f "$OUT/libffmpeg.a"
ar rcs "$OUT/libffmpeg.a" "$MERGE/avutil"/*.o "$MERGE/avformat"/*.o "$MERGE/avcodec"/*.o

# 同名校验：序号化后不应存在任何重复成员（有 = 合并逻辑出错，符号丢失前兆）
DUPES="$(ar t "$OUT/libffmpeg.a" | sort | uniq -d)"
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

# --- 6.5) 链接闭合冒烟（DEPS-012 教训：体积/符号检查不暴露依赖链缺口，只有真链接才暴露）---
# 用 C++ 消费者（同 core 的 include 方式 + extern "C" 包裹）链接合并库，
# 引用 demux 档的全部对外入口；失败 = 裁剪清单与上游依赖不闭合，禁止出货。
SMOKE_CPP="$(mktemp /tmp/ffsmoke.XXXXXX.cpp)"
SMOKE_BIN="${SMOKE_CPP%.cpp}.out"
cat > "$SMOKE_CPP" << 'EOF'
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
}
int main() {
    AVFormatContext* ctx = nullptr;
    if (avformat_open_input(&ctx, "/dev/null", nullptr, nullptr) < 0) return 1;
    avformat_find_stream_info(ctx, nullptr);
    for (unsigned i = 0; i < ctx->nb_streams; ++i) {
        const AVCodecDescriptor* d = avcodec_descriptor_get(ctx->streams[i]->codecpar->codec_id);
        (void)d->name;
        (void)av_get_media_type_string(ctx->streams[i]->codecpar->codec_type);
    }
    avformat_close_input(&ctx);
    return 0;
}
EOF
echo ">> 链接闭合冒烟 (clang++ 消费者) ..."
if ! clang++ "$SMOKE_CPP" -o "$SMOKE_BIN" -arch "$ARCH" -isysroot "$SDKROOT_PATH" -Wno-nullability-completeness \
     -I"$OUT/include" "$OUT/libffmpeg.a" \
     -framework CoreFoundation -framework CoreVideo -framework CoreMedia -framework VideoToolbox; then
  echo "!! 链接闭合失败：demux 档裁剪清单与 FFmpeg 内部依赖不闭合（见 Undefined symbols）" >&2
  echo "   排查：PARSERS/BSFS 清单 vs libavcodec/Makefile 依赖链（DEPS-012，2026-10-11 hevc/opus/mpeg4video 案）" >&2
  rm -f "$SMOKE_CPP" "$SMOKE_BIN"
  exit 1
fi
rm -f "$SMOKE_CPP" "$SMOKE_BIN"
echo "   (闭合通过)"

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
