#!/usr/bin/env python3
# ChuanqiCut — PAL 头文件门禁扫描（CORE-006，零平台类型 / 零 FFmpeg 类型）
#
# 设计要点（来自评审）：
#   * 朴素 grep 会把注释误报；AppleClang 下平台类型反而能编译通过。
#     故本脚本在匹配前**先剔除注释与字符串字面量**，再匹配，避免漏报与误报。
#   * 纯标准库实现（无第三方依赖），可接入 CTest / CI。
#
# 检查项：
#   1. 平台类型：NSString / CGFloat / CVPixelBufferRef / jobject / JNIEnv / MTLDevice /
#      ID3D11Device / CGImageRef / EGLDisplay / VkDevice 等（可配置清单）
#   2. 平台头：#include <CoreFoundation/...> <jni.h> <android/...> <Metal/...>
#      <d3d11.h> <EGL/...> <vulkan/...> <GLES.../...> 等
#   3. FFmpeg 类型：AVFormatContext / AVPacket / AVCodecID / AVFrame / AVStream /
#      avformat_* / avcodec_* 等
#   4. 平台宏：#if __APPLE__ / __ANDROID__ / __OHOS__（能力必须运行时查询，不得编译期推断）
#   5. 异常：throw（内核禁用异常，错误一律 Status）
#   6. 裸 double：时间应走 RationalTime，PAL 头不应出现 double 类型
#
# 违规 → 退出码 1，并输出 文件:行号: 类别: 命中内容: 原始行。

import os
import re
import sys

# ---- 配置清单（可按需扩展）----
# 平台类型（标识符，整词匹配）
PLATFORM_TYPES = [
    "NSString", "NSInteger", "CGFloat", "CGImageRef", "CGColorSpaceRef",
    "CVPixelBufferRef", "CVPixelBuffer", "CVImageBufferRef",
    "jobject", "jclass", "jmethodID", "JNIEnv", "JavaVM",
    "MTLDevice", "MTLTexture", "MTLLibrary", "MTLCommandQueue",
    "EGLDisplay", "EGLContext", "EGLSurface",
    "VkDevice", "VkImage", "VkInstance", "VkPhysicalDevice", "VkQueue",
    "ID3D11Device", "ID3D11Texture2D", "ID3D12Device", "ID3D12Resource",
    "AHardwareBuffer", "ANativeWindow",
]

# 平台宏（整词匹配）
PLATFORM_MACROS = [
    "__APPLE__", "__ANDROID__", "__OHOS__", "TARGET_OS_IPHONE", "TARGET_OS_MAC",
]

# 平台头（#include <...> 路径中包含以下子串即违规）
PLATFORM_HEADERS = [
    "CoreFoundation", "CoreGraphics", "CoreVideo", "CoreMedia", "CoreImage",
    "AVFoundation", "Photos", "Metal", "MetalKit", "jni.h", "android/",
    "native_engine", "napi/", "JNI", "d3d11.h", "d3d12.h", "D3D11", "D3D12",
    "EGL", "EGL.h", "vulkan", "vulkan.h", "Vulkan", "GLES", "GLES2", "GLES3",
    "OpenGLES",
]

# FFmpeg 显式类型（整词匹配）
FFMPEG_TYPES = [
    "AVFormatContext", "AVPacket", "AVFrame", "AVStream", "AVCodec", "AVCodecID",
    "AVCodecContext", "AVCodecParameters", "AVDictionary", "AVRational",
    "AVBufferRef", "AVIOContext", "AVERROR", "SwsContext", "SwsFilter",
]


def strip_comments_and_strings(text):
    """把注释与字符串/字符字面量替换成等宽空格（保留换行与行结构，便于行号对齐）。"""
    out = []
    i = 0
    n = len(text)
    state = "code"  # code | line_comment | block_comment | string_d | char_d
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if state == "code":
            if c == "/" and nxt == "/":
                # 行注释：整行剩余替换空格
                while i < n and text[i] != "\n":
                    out.append(" ")
                    i += 1
                # 保留换行
                if i < n:
                    out.append("\n")
                    i += 1
                continue
            if c == "/" and nxt == "*":
                out.append(" ")
                out.append(" ")
                i += 2
                state = "block_comment"
                continue
            if c == '"':
                out.append(" ")
                i += 1
                state = "string_d"
                continue
            if c == "'":
                out.append(" ")
                i += 1
                state = "char_d"
                continue
            out.append(c)
            i += 1
            continue

        elif state == "line_comment":
            # 理论上不会进入（已在 code 分支处理）；保险处理
            if c == "\n":
                out.append("\n")
                state = "code"
            else:
                out.append(" ")
            i += 1
            continue

        elif state == "block_comment":
            if c == "\n":
                out.append("\n")
                i += 1
                continue
            if c == "*" and nxt == "/":
                out.append(" ")
                out.append(" ")
                i += 2
                state = "code"
                continue
            out.append(" ")
            i += 1
            continue

        elif state == "string_d":
            if c == "\\":
                out.append(" ")
                out.append(" ")
                i += 2
                continue
            if c == '"':
                out.append(" ")
                i += 1
                state = "code"
                continue
            out.append(" ") if c != "\n" else out.append("\n")
            i += 1
            continue

        elif state == "char_d":
            if c == "\\":
                out.append(" ")
                out.append(" ")
                i += 2
                continue
            if c == "'":
                out.append(" ")
                i += 1
                state = "code"
                continue
            out.append(" ") if c != "\n" else out.append("\n")
            i += 1
            continue

    return "".join(out)


def scan_file(path):
    """返回该文件的违规列表：[(line_no, category, token, raw_line), ...]"""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()

    clean = strip_comments_and_strings(raw)
    lines = clean.split("\n")

    # 预编译正则
    type_re = {t: re.compile(r"\b" + re.escape(t) + r"\b") for t in PLATFORM_TYPES}
    macro_re = {m: re.compile(r"\b" + re.escape(m) + r"\b") for m in PLATFORM_MACROS}
    ffmpeg_re = {t: re.compile(r"\b" + re.escape(t) + r"\b") for t in FFMPEG_TYPES}
    # FFmpeg 前缀：av_ 函数族（避开英文词如 availability）
    ffmpeg_avfunc_re = re.compile(r"\bav_[A-Za-z]")
    # FFmpeg 结构体前缀 AV + 大写
    ffmpeg_avstruct_re = re.compile(r"\bAV[A-Z]")
    include_re = re.compile(r"#include\s*<([^>]+)>")
    throw_re = re.compile(r"\bthrow\b")
    double_re = re.compile(r"\bdouble\b")

    violations = []
    for idx, line in enumerate(lines, start=1):
        raw_line = raw.split("\n")[idx - 1] if idx - 1 < len(raw.split("\n")) else ""

        for t, rgx in type_re.items():
            if rgx.search(line):
                violations.append((idx, "platform_type", t, raw_line))
        for m, rgx in macro_re.items():
            if rgx.search(line):
                violations.append((idx, "platform_macro", m, raw_line))
        for t, rgx in ffmpeg_re.items():
            if rgx.search(line):
                violations.append((idx, "ffmpeg_type", t, raw_line))
        if ffmpeg_avfunc_re.search(line):
            violations.append((idx, "ffmpeg_type", "av_*", raw_line))
        if ffmpeg_avstruct_re.search(line):
            violations.append((idx, "ffmpeg_type", "AV*", raw_line))

        m_inc = include_re.search(line)
        if m_inc:
            inc_path = m_inc.group(1)
            for h in PLATFORM_HEADERS:
                if h in inc_path:
                    violations.append((idx, "platform_header", "<%s>" % h, raw_line))
                    break

        if throw_re.search(line):
            violations.append((idx, "exception", "throw", raw_line))
        if double_re.search(line):
            violations.append((idx, "double_type", "double", raw_line))

    return violations


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(here))  # tools/pal -> repo root
    cq_inc = os.path.join(root, "core", "include", "cq")

    # 默认扫描全部「跨平台接口目录」（CORE-006 已锁定 pal；GFX-001 / MEDIA-010 新增
    # gfx / media，同样必须零平台类型。门禁统一兜底，不只为 pal 一目录设防）。
    # 可用第一个参数覆盖为单个目录（直接手动调试时用）。
    if len(argv) > 1:
        scan_dirs = [argv[1]]
    else:
        scan_dirs = [os.path.join(cq_inc, d) for d in ("pal", "gfx", "media")]

    headers = []
    for d in scan_dirs:
        if not os.path.isdir(d):
            print("include dir not found: %s" % d, file=sys.stderr)
            return 2
        for dirpath, _, filenames in os.walk(d):
            for fn in filenames:
                if fn.endswith(".h"):
                    headers.append(os.path.join(dirpath, fn))
    headers.sort()

    total = 0
    failed_files = 0
    for path in headers:
        v = scan_file(path)
        if v:
            failed_files += 1
            total += len(v)
            rel = os.path.relpath(path)
            print("FAIL  %s" % rel)
            for (ln, cat, tok, raw) in v:
                snippet = raw.strip()
                if len(snippet) > 120:
                    snippet = snippet[:120] + "..."
                print("  %s:%d: [%s] matched '%s'  |  %s" % (rel, ln, cat, tok, snippet))

    print("-" * 60)
    print("scanned %d header(s) across %d dir(s), %d violation(s) in %d file(s)"
          % (len(headers), len(scan_dirs), total, failed_files))

    if total > 0:
        return 1
    print("OK: no platform types / FFmpeg types / exceptions / double in cq interface headers")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
