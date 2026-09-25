#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ChuanqiCut Golden 样本校验器 (QA-001)
=====================================
读取 manifest.toml，对每条样本做「齐备性 + 参数一致性」校验：
  * built(python-png)：glob 帧文件数；解码首帧 PNG 头得真实
    width/height/bit-depth/color-type，与清单比对。
  * built(ffmpeg)：用 ffprobe 实测分辨率/编码/has_b_frames/帧数/帧间隔(VFR)/
    旋转 tag/音轨，与清单比对（等价 ffprobe）。
  * requires=ffmpeg（unbuilt）：作为「已知缺口」报告，不计入失败。

退出码：所有 built 样本一致为 0；任一 built 样本缺失/参数不符为 1。

用法：
  python3 verify.py            # 校验并打印齐备报告
  python3 verify.py --json     # 额外输出机器可读摘要到 stdout 末行
"""

import os
import sys
import glob
import json
import struct
import math
import subprocess
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "manifest.toml")
FRAMES_DIR = os.path.join(HERE, "frames")


def png_info(path: str):
    """解析 PNG 头，返回 (width, height, bit_depth, color_type)。等价 ffprobe。"""
    with open(path, "rb") as f:
        sig = f.read(8)
        if sig != b"\x89PNG\r\n\x1a\n":
            raise ValueError(f"不是 PNG 文件：{path}")
        while True:
            hdr = f.read(8)
            if len(hdr) < 8:
                raise ValueError(f"PNG 截断：{path}")
            ln = struct.unpack(">I", hdr[:4])[0]
            ctype = hdr[4:8]
            data = f.read(ln)
            if ctype == b"IHDR":
                w, h, bitd, colort = struct.unpack(">IIBB", data[:10])
                return w, h, bitd, colort
            f.read(4)  # crc


def human_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f}{unit}" if unit != "B" else f"{n}B"
        n /= 1024.0
    return f"{n:.1f}TB"


# ----------------------------------------------------------------------
# ffprobe 集成（编码类样本的真实参数核对，等价 ffprobe）
# ----------------------------------------------------------------------
FFPROBE_BIN = os.environ.get(
    "CQ_FFPROBE_BIN", "/Users/zhuning/.workbuddy/binaries/ffmpeg/bin/ffprobe")
# 注意：该 ffmpeg/ffprobe 仅用于校验测试夹具，绝不参与发布构建。


def _ffprobe_json(path: str) -> dict:
    import json as _json
    r = subprocess.run(
        [FFPROBE_BIN, "-v", "error", "-show_streams", "-show_format",
         "-of", "json", path],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "ffprobe failed")
    return _json.loads(r.stdout)


def _ffprobe_frame_pts(path: str):
    import subprocess as _sp
    r = _sp.run(
        [FFPROBE_BIN, "-v", "error", "-select_streams", "v",
         "-show_entries", "frame=pts_time", "-of", "default=noprint_wrappers=1:nokey=1", path],
        capture_output=True, text=True)
    vals = []
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            vals.append(float(line.split(",")[0]))
        except ValueError:
            pass
    return vals


def _mp4_display_rotation(path: str):
    """字节级读 mp4 tkhd 的变换矩阵，返回旋转角(度逆时针)；无旋转返回 None。

    为什么不读 ffprobe 的 tags.rotate：mp4 里旋转的**正确载体是 tkhd 的 display
    matrix**，tags.rotate 是 ffmpeg 6 已废弃的遗留写法 —— 生成器即便写了
    -metadata rotate=90，mp4 muxer 也不会把它落成 tag（实测 tags/side_data 均为空）。
    读 tkhd 是字节级真相，绕开 ffprobe 是否选择显示某一字段的不确定性。
    """
    if not path.endswith((".mp4", ".mov", ".m4v")):
        return None
    found = []

    def walk(f, end):
        while f.tell() < end:
            pos = f.tell()
            hdr = f.read(8)
            if len(hdr) < 8:
                return
            size, typ = struct.unpack(">I4s", hdr)
            typ = typ.decode("latin1")
            if size == 1:
                size = struct.unpack(">Q", f.read(8))[0]
            elif size == 0:
                size = end - pos
            nxt = pos + size
            if typ in ("moov", "trak"):
                walk(f, nxt)
            elif typ == "tkhd":
                ver = f.read(1)[0]
                f.read(3)                                   # flags
                # v0: creation(4) modification(4) track_ID(4) reserved(4) duration(4)
                # v1: creation(8) modification(8) track_ID(4) reserved(4) duration(8)
                f.read(20 if ver == 0 else 32)
                f.read(8)                                   # reserved
                f.read(2 + 2 + 2 + 2)                       # layer/alt_group/volume/reserved
                a, b = struct.unpack(">2i", f.read(8))[:2]  # matrix 前两项 = 旋转项
                found.append((a, b))
            f.seek(nxt)

    try:
        with open(path, "rb") as f:
            walk(f, os.path.getsize(path))
    except Exception:  # noqa
        return None
    for a, b in found:
        # matrix 是 16.16 定点；旋转矩阵为 [a b ; -b a]，角度 = atan2(b, a)
        A, B = a / 65536.0, b / 65536.0
        if abs(A) < 1e-6 and abs(B) < 1e-6:
            return None                                     # 退化为单位矩阵时 b==0
        ang = math.degrees(math.atan2(B, A))
        if abs(ang) > 1e-6:
            return round(ang)
    return None


def verify_ffmpeg_sample(spec, files):
    """返回 (ok, detail_list)。用 ffprobe 实测，不迁就产物。"""
    path = files[0]
    data = _ffprobe_json(path)
    streams = data.get("streams", [])
    vids = [s for s in streams if s.get("codec_type") == "video"]
    auds = [s for s in streams if s.get("codec_type") == "audio"]
    if not vids:
        return False, ["无视频流"]
    v = vids[0]
    detail = []

    # 分辨率
    w = int(v.get("width", 0)); h = int(v.get("height", 0))
    if (w, h) != (int(spec["width"]), int(spec["height"])):
        detail.append(f"分辨率不符 实={w}x{h} 期={spec['width']}x{spec['height']}")
    # 编码
    codec = v.get("codec_name")
    if codec != spec.get("codec"):
        detail.append(f"编码不符 实={codec} 期={spec.get('codec')}")
    # B 帧
    bf = int(spec.get("bframes", 0))
    has_b = int(v.get("has_b_frames", 0))
    if bf > 0 and has_b <= 0:
        detail.append(f"B帧缺失 has_b_frames={has_b} 期>0")
    if bf == 0 and has_b != 0:
        detail.append(f"不应有B帧 has_b_frames={has_b} 期=0")
    # 帧数
    n = int(spec.get("frame_count", 0))
    pts = _ffprobe_frame_pts(path)
    if len(pts) != n:
        detail.append(f"帧数不符 实={len(pts)} 期={n}")
    # VFR：帧间隔必须非常数
    if spec.get("vfr"):
        if len(pts) >= 2:
            diffs = [round(pts[i + 1] - pts[i], 5) for i in range(len(pts) - 1)]
            distinct = len(set(diffs))
            if distinct <= 1:
                detail.append(f"VFR失败: 帧间隔为常数 {diffs[0]}")
        else:
            detail.append("VFR失败: 帧太少")
    # 旋转 metadata
    rot = int(spec.get("rotation", 0))
    if rot != 0:
        # 旋转的正确载体是 tkhd display matrix；tags.rotate 仅作遗留容器的兜底。
        # ffmpeg -display_rotation 的语义是「逆时针 N 度」，因此写入 N 后
        # 矩阵反算出的角度为 -N。要求严格一一对应：(实测角 + 声明角) % 360 == 0。
        got_mat = _mp4_display_rotation(path)
        got_tag = v.get("tags", {}).get("rotate", "")
        if got_mat is not None:
            if (got_mat + rot) % 360 != 0:
                detail.append(f"旋转矩阵不符 实={got_mat}° 期=-{rot}°")
        elif str(got_tag) != str(rot):
            detail.append(f"旋转缺失 tags.rotate={got_tag or '(无)'} tkhd无旋转矩阵 期={rot}")
    # 音轨
    if spec.get("audio"):
        if not auds:
            detail.append("缺音轨")
        elif auds[0].get("codec_type") != "audio":
            detail.append("音轨流类型异常")
    return (len(detail) == 0), detail


def verify_png_sample(spec, files):
    """返回 (ok, detail_list, size, w, h, actual_count)。"""
    actual_count = len(files)
    expect_count = int(spec.get("frame_count", 0))
    expect_w, expect_h = int(spec["width"]), int(spec["height"])
    detail = []
    w = h = bitd = colort = None
    if actual_count == 0:
        detail.append("无帧文件")
    else:
        try:
            w, h, bitd, colort = png_info(files[0])
        except Exception as e:  # noqa
            detail.append(f"首帧解析失败:{e}")
        if w is not None:
            if (w, h) != (expect_w, expect_h):
                detail.append(f"尺寸不符 实={w}x{h} 期={expect_w}x{expect_h}")
            if bitd != 8 or colort != 2:
                detail.append(f"像素格式不符 bit={bitd} color={colort}(期 8/2)")
        if actual_count != expect_count:
            detail.append(f"帧数不符 实={actual_count} 期={expect_count}")
    size = sum(os.path.getsize(p) for p in files)
    return (len(detail) == 0), detail, size, w, h, actual_count


def main():
    with open(MANIFEST, "rb") as f:
        manifest = tomllib.load(f)
    samples = manifest.get("sample", [])
    want_json = "--json" in sys.argv

    print("=" * 72)
    print("ChuanqiCut Golden 样本库校验报告")
    print(f"manifest: {MANIFEST}")
    print(f"generator_path(声明): {manifest.get('generator_path')}")
    print("=" * 72)

    built_ok = 0
    built_fail = 0
    unbuilt = 0
    total_bytes = 0
    rows = []
    failures = []

    for s in samples:
        sid = s.get("id", "?")
        requires = s.get("requires")
        status = s.get("status")
        use_case = s.get("use_case", "")

        if requires == "ffmpeg" and status == "unbuilt":
            unbuilt += 1
            print(f"[缺口] {sid:32s} requires=ffmpeg (未生成，需编码器/授权素材)")
            rows.append({"id": sid, "status": "unbuilt", "requires": "ffmpeg"})
            continue

        # 解析文件（file_glob 相对 tests/golden/）
        files = sorted(glob.glob(os.path.join(HERE, s.get("file_glob", ""))))
        if not files:
            built_fail += 1
            rows.append({"id": sid, "status": "FAIL", "detail": "无文件"})
            print(f"[FAIL] {sid:32s} 无文件(file_glob={s.get('file_glob')})")
            failures.append(sid)
            continue

        if files[0].endswith(".png"):
            ok, detail, size, w, h, actual_count = verify_png_sample(s, files)
        else:  # 编码样本（.mp4 等）：ffprobe 实测
            if not os.path.exists(FFPROBE_BIN):
                ok, detail = False, [f"ffprobe 缺失:{FFPROBE_BIN}"]
                size = sum(os.path.getsize(p) for p in files)
                w = h = actual_count = None
            else:
                ok, detail = verify_ffmpeg_sample(s, files)
                size = sum(os.path.getsize(p) for p in files)
                vinfo = _ffprobe_json(files[0])
                v = [x for x in vinfo.get("streams", [])
                     if x.get("codec_type") == "video"][0]
                w, h = int(v.get("width", 0)), int(v.get("height", 0))
                actual_count = len(_ffprobe_frame_pts(files[0]))

        total_bytes += size
        if ok:
            built_ok += 1
            rows.append({"id": sid, "status": "built", "frames": actual_count,
                         "w": w, "h": h, "bytes": size})
            print(f"[OK  ] {sid:32s} {actual_count:>4d}帧 "
                  f"{w}x{h} {human_size(size):>8s}  {use_case[:34]}")
        else:
            built_fail += 1
            rows.append({"id": sid, "status": "FAIL", "detail": ";".join(detail)})
            print(f"[FAIL] {sid:32s} {';'.join(detail)}")
            failures.append(sid)

    print("-" * 72)
    print(f"built 一致: {built_ok}    built 失败: {built_fail}    "
          f"ffmpeg 缺口: {unbuilt}")
    print(f"素材总体积(实际): {human_size(total_bytes)}  ({total_bytes} bytes)")
    print("=" * 72)

    if want_json:
        summary = {
            "built_ok": built_ok,
            "built_fail": built_fail,
            "unbuilt": unbuilt,
            "total_bytes": total_bytes,
            "failures": failures,
        }
        print("JSON_SUMMARY:" + json.dumps(summary, ensure_ascii=False))

    if built_fail > 0:
        print(f"\n校验失败：{built_fail} 个 built 样本与清单不一致。", file=sys.stderr)
        return 1
    print("\n校验通过：所有 built 样本（python-png + ffmpeg 编码）齐备且参数与清单一致。")
    if unbuilt:
        print(f"注：仍有 {unbuilt} 个 requires=ffmpeg 样本未生成（需编码器/授权素材）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
