#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ChuanqiCut Golden 样本生成器 (QA-001)
=====================================
读取同目录 manifest.toml，为 status=="built" 且 requires=="python-png"
的样本合成 PNG 帧序列，写入 frames/<id>/frame_%04d.png。

设计约束（来自任务与 AGENTS.root.md）：
  * 本机无 ffmpeg，全部 built 样本走「纯标准库 PNG 合成」路径（无 numpy/Pillow 依赖）。
  * 完全合成，绕开版权；不下载任何网络素材，不读取用户机器现成视频。
  * 体积克制：极端场景多为单帧；4K 仅保留关键帧。
  * 确定性：同样输入恒得同样输出，保证 golden 可复现。

可选 ffmpeg 分支：若环境存在 ffmpeg，会尝试为 requires=="ffmpeg" 的
unbuilt 样本编码真实 H.264/HEVC（含 B 帧、VFR、旋转、音轨）。本机缺失，
该分支自动跳过（见 --ffmpeg 开关）。

用法：
  python3 generate.py                  # 仅生成 python-png 样本（默认）
  python3 generate.py --ffmpeg         # 额外尝试 ffmpeg 编码样本（需 ffmpeg）
  python3 generate.py --ffmpeg-only    # 仅编码 ffmpeg 样本，跳过 python-png
                                        #（适合 CI/本地单独重建编码夹具，
                                        #  避免重跑 4K PNG 合成）
"""

import os
import sys
import zlib
import struct
import shutil
import subprocess
import tempfile
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "manifest.toml")
FRAMES_DIR = os.path.join(HERE, "frames")


# ----------------------------------------------------------------------
# 纯标准库 PNG 写入（RGB, 8bit, color type 2）
# ----------------------------------------------------------------------
def write_png(path: str, w: int, h: int, rgb: bytes) -> None:
    assert len(rgb) == w * h * 3, "rgb length mismatch"
    out = bytearray()
    out.extend(b"\x89PNG\r\n\x1a\n")

    def chunk(ctype: bytes, data: bytes) -> None:
        out.extend(struct.pack(">I", len(data)))
        out.extend(ctype)
        out.extend(data)
        out.extend(struct.pack(">I", zlib.crc32(ctype + data) & 0xFFFFFFFF))

    chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    stride = w * 3
    raw = bytearray(h * (stride + 1))
    for y in range(h):
        raw[y * (stride + 1)] = 0  # filter: none
        raw[y * (stride + 1) + 1: y * (stride + 1) + 1 + stride] = \
            rgb[y * stride:(y + 1) * stride]
    # 压缩级别 6：在尺寸与速度间折中（高频图 level 对体积影响很小）
    chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)


# ----------------------------------------------------------------------
# 图案生成：返回 w*h*3 的 bytes
# ----------------------------------------------------------------------
def _solid(w, h, params):
    c = tuple(params.get("color", [0, 0, 0]))
    return bytes(c) * (w * h)


def _smptebars(w, h, params):
    # SMPTE 75% 彩条（7 竖条）+ 底部反序条 + PLUGE 风格窄条
    bars = [
        (191, 191, 191),  # gray
        (191, 191, 0),    # yellow
        (0, 191, 191),    # cyan
        (0, 191, 0),      # green
        (191, 0, 191),    # magenta
        (191, 0, 0),      # red
        (0, 0, 191),      # blue
    ]
    n = len(bars)
    row = bytearray()
    for x in range(w):
        row.extend(bars[(x * n) // w])
    # 顶部 2/3 为彩条，底部 1/3 为反序 + 黑边
    buf = bytearray()
    top = h * 2 // 3
    buf.extend(row * top)
    # 底部：反序彩条
    rev = bytearray()
    for x in range(w):
        rev.extend(bars[n - 1 - (x * n) // w])
    buf.extend(rev * (h - top))
    return bytes(buf)


def _stripes_hd(w, h, params):
    # 高动态条纹：黑白等宽竖条，最大局部对比
    bar = max(1, w // 256)
    row = bytearray()
    for x in range(w):
        col = (255, 255, 255) if (x // bar) % 2 == 0 else (0, 0, 0)
        row.extend(col)
    return bytes(row) * h


def _texture_fine(w, h, params):
    # 细密棋盘格：暴露重采样锯齿/混叠
    cell = max(2, w // 240)
    white = bytearray()
    for x in range(w):
        white.extend((255, 255, 255) if (x // cell) % 2 == 0 else (0, 0, 0))
    black = bytearray(255 - c for c in white)
    buf = bytearray()
    for y in range(h):
        buf.extend(white if (y // cell) % 2 == 0 else black)
    return bytes(buf)


def _gradient(w, h, params):
    # 黑->白水平线性渐变
    row = bytearray()
    for x in range(w):
        v = (x * 255) // max(1, w - 1)
        row.extend((v, v, v))
    return bytes(row) * h


def _mandelbrot(w, h, params):
    # 分形：半分辨率计算后最近邻 2x 放大（控制纯 Python 计算量）
    hw, hh = max(1, w // 2), max(1, h // 2)
    max_iter = 80
    half = bytearray(hw * hh * 3)
    for py in range(hh):
        cy = (py / hh) * 3.0 - 1.5
        for px in range(hw):
            cx = (px / hw) * 3.5 - 2.5
            x = 0.0
            y = 0.0
            it = 0
            while x * x + y * y <= 4.0 and it < max_iter:
                xt = x * x - y * y + cx
                y = 2.0 * x * y + cy
                x = xt
                it += 1
            if it >= max_iter:
                r = g = b = 0
            else:
                t = it / max_iter
                r = int(255 * t)
                g = int(255 * t * 0.6)
                b = int(255 * (1 - t))
            idx = (py * hw + px) * 3
            half[idx] = r
            half[idx + 1] = g
            half[idx + 2] = b
    # 2x 放大
    buf = bytearray(w * h * 3)
    stride = w * 3
    for y in range(h):
        sy = min(hh - 1, y // 2)
        src = half[sy * hw * 3:(sy + 1) * hw * 3]
        base = y * stride
        for x in range(w):
            sx = min(hw - 1, x // 2)
            buf[base + x * 3:base + x * 3 + 3] = src[sx * 3:sx * 3 + 3]
    return bytes(buf)


def _motion_block(w, h, params, frame_idx, total_frames):
    # 灰底 + 红块自左向右横移，制造多帧时序
    bg = (40, 40, 40)
    block = (220, 30, 30)
    frame = bytearray(bytes(bg) * (w * h))
    bw = max(1, int(w * 0.15))
    bh = max(1, int(h * 0.30))
    bx = int((w - bw) * (frame_idx / max(1, total_frames - 1))) if total_frames > 1 else 0
    by = int(h * 0.35)
    for y in range(by, min(h, by + bh)):
        base = y * w * 3
        for x in range(bx, min(w, bx + bw)):
            idx = base + x * 3
            frame[idx] = block[0]
            frame[idx + 1] = block[1]
            frame[idx + 2] = block[2]
    return bytes(frame)


GENERATORS = {
    "solid": _solid,
    "smptebars": _smptebars,
    "stripes_hd": _stripes_hd,
    "texture_fine": _texture_fine,
    "gradient": _gradient,
    "mandelbrot": _mandelbrot,
}


def gen_frame(spec, frame_idx, total_frames) -> bytes:
    pattern = spec.get("pattern")
    w = spec["width"]
    h = spec["height"]
    if pattern == "motion_block":
        return _motion_block(w, h, spec, frame_idx, total_frames)
    gen = GENERATORS.get(pattern)
    if gen is None:
        raise ValueError(f"unknown pattern: {pattern}")
    return gen(w, h, spec)


# ----------------------------------------------------------------------
# ffmpeg 分支：生成真实编码样本（H.264/HEVC/B帧/VFR/旋转/音轨）
# ----------------------------------------------------------------------
# ！！！重要约束（team-lead 拍板）！！！
# 本 ffmpeg 二进制（evermeet.cx tessus 静态构建 6.1.1）**仅用于生成测试夹具**，
# 绝对不能链接进发布产物，也不能当作 FFmpeg 体积/符号基线的数据源
# （那是 DEPS-013 用我们自己的 demux 档位构建来测的）。
FFMPEG_BIN = os.environ.get(
    "CQ_FFMPEG_BIN", "/Users/zhuning/.workbuddy/binaries/ffmpeg/bin/ffmpeg")
FFPROBE_BIN = os.environ.get(
    "CQ_FFPROBE_BIN", "/Users/zhuning/.workbuddy/binaries/ffmpeg/bin/ffprobe")


def _run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"命令失败({r.returncode}): {' '.join(cmd[:6])}...\n"
                           f"{r.stderr.strip().splitlines()[-1] if r.stderr.strip() else ''}")
    return r


def _ffmpeg_common_video_args(spec):
    """返回 (lavfi 输入源, 视频编码参数列表)。"""
    w, h = spec["width"], spec["height"]
    dur = spec["duration_s"]
    codec = spec["codec"]
    gop = int(spec.get("gop_size", 30))
    bf = int(spec.get("bframes", 0))
    src = ["-f", "lavfi", "-i", f"smptebars=size={w}x{h}:rate=30:duration={dur}"]
    v = []
    if codec == "h264":
        v += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
              "-g", str(gop), "-bf", str(bf)]
        if gop >= 60:  # 确保长 GOP 不被场景切打乱
            v += ["-keyint_min", str(gop), "-sc_threshold", "0"]
    elif codec == "hevc":
        v += ["-c:v", "libx265", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
              "-g", str(gop)]
        if bf == 0:
            v += ["-x265-params", "bframes=0"]
    else:
        raise ValueError(f"未知 codec: {codec}")
    return src, v


def _generate_vfr(spec):
    """真 VFR：单进程内用 setpts 过滤器给相邻帧交替两种长度的间隔（非常数）。

    为什么不用 concat demuxer：本环境沙箱 bypass 模式下 ffmpeg 读不到由 Python
    写入的临时 PNG/列表文件（覆盖写也静默失败），concat 路径极不稳定。
    setpts 单进程内改时间戳、零临时文件，规避该问题。

    ⚠️ 踩过的三个坑（全部实测，勿回退）：
      1. setpts 返回值单位是 **timebase units 而非秒**，漏写 `/TB` 会让 pts 全部塌为 0，
         产物退化为 CFR（ffprobe 读到恒定 0.03333）。
      2. `-fps_mode vfr` 必须与 setpts 同用，缺则 ffmpeg 把不均匀时间戳重采样成 CFR。
      3. TB 不因 `-enc_time_base` / `settb` 而变（二者只作用于 encoder/后续环节），
         setpts 仍跑在输入时基 1/fps 上。**因此小于 1/fps 的间隔必然被量化掉** ——
         想表达 0.02s 这类亚帧间隔是做不到的，只能把排布落在整数 tick 上。

    ⚠️ VFR 样本的 duration_s 因此 ≠ frame_count/fps（本样本 90 帧 @30fps 名义 3.0s，
       实际 4.4667s），这是 VFR 的固有属性而非缺陷，manifest 里的 duration_s 记实测值。

    tessus 6.1.1 的 setpts 支持 floor/mod/if 表达式（注意 shell 引号，避免 `*` 被
    glob 吃掉导致 "Filter not found"）。

    累计时间戳 cumtime(N) = (0.02*floor((N+1)/2) + (2/30-0.02)*floor(N/2)) / TB
      → 相邻间隔在 0.02s / 0.0466667s 间交替，非常数（满足 VFR 校验），
        且 90 帧总时长恰为 3.0s，与 manifest 的 duration_s / fps=30 自洽 ——
        这样才能与同规格的 CFR 样本 gf_1080p_h264 形成「同帧数、同总时长、
        仅时间戳分布不同」的严格对照。
    """
    w, h = spec["width"], spec["height"]
    n = int(spec["frame_count"])
    out = os.path.join(FRAMES_DIR, f"{spec['id']}.mp4")
    # 在 TB 的刻度上按「整数 tick」排布，规避 <=TB 的间隔被量化抹平：
    #   p(N) = (N + floor(N/2)) tick  ->  相邻间隔严格交替 1 tick / 2 ticks，
    #   即 30fps 与 15fps 交替 —— 这是录屏/网络流最典型的真实 VFR 形态。
    fps = float(spec.get("fps", 30))
    setpts = f"(N+floor(N/2))*(1/{fps:g})/TB"
    cmd = [FFMPEG_BIN, "-y", "-hide_banner", "-loglevel", "error",
           "-f", "lavfi", "-i", f"smptebars=size={w}x{h}:rate=30",
           "-vf", f"setpts={setpts}",
           "-frames:v", str(n),
           "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
           "-g", "30", "-bf", "0",
           "-fps_mode", "vfr",
           "-movflags", "+faststart", out]
    _run(cmd)


def generate_ffmpeg_sample(spec):
    sid = spec["id"]
    out = os.path.join(FRAMES_DIR, f"{sid}.mp4")
    if spec.get("vfr"):
        _generate_vfr(spec)
        print(f"[ffmpeg] {sid}: VFR -> {out}")
        return
    src, v = _ffmpeg_common_video_args(spec)
    rotation = int(spec.get("rotation", 0))
    audio = bool(spec.get("audio"))
    cmd = [FFMPEG_BIN, "-y", "-hide_banner", "-loglevel", "error"] + src
    if audio:
        cmd += ["-f", "lavfi", "-i", f"sine=frequency=440:duration={spec['duration_s']}",
                "-c:a", "aac", "-map", "0:v:0", "-map", "1:a:0"]
    else:
        cmd += ["-map", "0:v:0"]
    # ⚠️ v 必须进 cmd —— 此前漏加，导致 gop_size/bframes/pix_fmt/preset 全部没生效，
    #    那些「通过」的编码参数校验实际上是落到 x264 默认值上蒙对的。
    cmd += v
    cmd += ["-movflags", "+faststart"]

    if rotation:
        # 旋转 metadata 只能走两步法，且 -display_rotation 必须在 -i 之前（它是 INPUT option）。
        # 依据：六种写法实测（字节级解析 tkhd 变换矩阵），只有这条真正写入：
        #   -metadata:s:v rotate=90（重编码 / -c copy）  -> tkhd 仍是单位矩阵
        #   -display_rotation 作 output option          -> ffmpeg 报错拒绝
        #   mkv 中转保留 tag 再 remux                    -> tkhd 仍是单位矩阵
        #   -display_rotation:v:0 N -i X -c copy         -> 成功（唯一可行）
        # 且它写的是标准 tkhd display matrix，**不写** 已废弃的 tags.rotate，
        # 所以 verify 侧也必须改读 display matrix，见 verify.py::_mp4_display_rotation。
        tmp = out + ".norot.mp4"
        _run(cmd + [tmp])
        _run([FFMPEG_BIN, "-y", "-hide_banner", "-loglevel", "error",
              "-display_rotation:v:0", str(rotation), "-i", tmp,
              "-c", "copy", "-movflags", "+faststart", out])
        if os.path.exists(tmp):
            os.remove(tmp)
    else:
        _run(cmd + [out])
    print(f"[ffmpeg] {sid}: {spec['codec']} rotate={rotation} audio={audio} -> {out}")


def try_ffmpeg_samples(samples):
    if not os.path.exists(FFMPEG_BIN):
        print(f"[ffmpeg] 未找到 ffmpeg：{FFMPEG_BIN}（可用 CQ_FFMPEG_BIN 覆盖）。跳过。")
        return 0
    todo = [s for s in samples if s.get("requires") == "ffmpeg"]
    print(f"[ffmpeg] 读取 manifest：requires=ffmpeg 样本 {len(todo)} 个")
    for s in todo:
        generate_ffmpeg_sample(s)
    return len(todo)


# ----------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------
def main():
    with open(MANIFEST, "rb") as f:
        manifest = tomllib.load(f)

    samples = manifest.get("sample", [])
    use_ffmpeg = "--ffmpeg" in sys.argv
    ffmpeg_only = "--ffmpeg-only" in sys.argv
    if ffmpeg_only:
        use_ffmpeg = True  # ffmpeg-only 隐含需要 ffmpeg 分支

    if not ffmpeg_only:
        built = [s for s in samples if s.get("requires") == "python-png" and s.get("status") == "built"]
        print(f"[generate] 读取 manifest：built(python-png) 样本 {len(built)} 个")

        for s in built:
            sid = s["id"]
            w, h = s["width"], s["height"]
            fc = s["frame_count"]
            out_dir = os.path.join(FRAMES_DIR, sid)
            os.makedirs(out_dir, exist_ok=True)
            for fi in range(fc):
                rgb = gen_frame(s, fi, fc)
                path = os.path.join(out_dir, f"frame_{fi + 1:04d}.png")
                write_png(path, w, h, rgb)
            print(f"[generate] {sid}: {fc} 帧 @ {w}x{h} -> {out_dir}")
    else:
        print("[generate] --ffmpeg-only：跳过 python-png 合成，仅编码 ffmpeg 样本")

    if use_ffmpeg:
        try_ffmpeg_samples(samples)
    else:
        # 即便不加 --ffmpeg，也提示缺失
        if any(s.get("requires") == "ffmpeg" for s in samples):
            print("[generate] 提示：存在 requires=ffmpeg 的样本未生成；"
                  "运行 `python3 generate.py --ffmpeg` 补全（需 ffmpeg）。")

    print(f"[generate] 完成。样本目录：{FRAMES_DIR}")


if __name__ == "__main__":
    main()
