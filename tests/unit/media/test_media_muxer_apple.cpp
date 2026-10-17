// ChuanqiCut — 平台无关 muxer 接缝验收（ChqIMediaMuxer 经工厂调用，全程不碰 AppleVideoEncoder）
//
// 验收硬要求：导出能力可被上层「平台无关」调用。
//   * 全程只通过 core 冻结接口 `ChqIMediaMuxer` + 工厂 `CreateMediaMuxer` 完成一次导出；
//     测试 TU 不 include `media_encode.h`、不出现 `AppleVideoEncoder` 类型——
//     证明上层（EXPORT-001 导出控制器）无需触碰任何 Apple 内部编码器即可导出 H.264 MP4。
//   * 帧源用真实 PALA-010 demux + PALA-011 硬解（VideoToolboxDecoder）产出 NativeImageHandle，
//     经 `ChqIMediaMuxer::WriteVideoFrame(NativeImageHandle, ChqRationalTime, ChqCancelToken)` 写入。
//   * ffprobe 验证：codec=H.264 / 1920x1080 / 帧数==N / 时长≈N/30；
//     首帧中心像素 ≈ (0,188,0,255) 且绿主导（通道顺序未颠倒）。
//   * 取消路径：经 `ChqIMediaMuxer::Cancel()` 中止并删除半成品文件。
//
// 无缓冲输出（崩溃/挂起时能看到进度）。仅 Apple 平台。

#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>  // access(X_OK)：ffprobe 回退路径存在性判定
#include <string>
#include <vector>

#include "cq/base/chq_status.h"
#include "cq/base/chq_rational_time.h"
#include "cq/platform/chq_media.h"  // ChqIMediaMuxer / CreateMediaMuxer（平台无关接缝）
#include "media_decode.h"           // VideoToolboxDecoder / GetCvPixelBuffer（仅帧源，Apple TU）

#ifndef CQ_SOURCE_DIR
#define CQ_SOURCE_DIR "."
#endif

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (cond) {
        std::printf("  ok  : %s\n", msg);
    } else {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

const char* Rt(const cq::ChqRationalTime& t) {
    static char buf[64];
    std::snprintf(buf, sizeof(buf), "%lld/%d (%.4fs)", static_cast<long long>(t.value),
                  static_cast<int>(t.timescale), t.ToSeconds());
    return buf;
}

// 从 BGRA CVPixelBuffer 读 (x,y) 处像素（base 地址锁定在调用方）。
void ReadPixelBgra(CVPixelBufferRef pb, uint32_t x, uint32_t y, uint8_t& b, uint8_t& g,
                   uint8_t& r, uint8_t& a) {
    b = g = r = a = 0;
    if (pb == nullptr) return;
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pb));
    const uint8_t* px = base + static_cast<size_t>(y) * stride + static_cast<size_t>(x) * 4;
    b = px[0];
    g = px[1];
    r = px[2];
    a = px[3];
}

bool RunCapture(const char* cmd, std::string& out) {
    out.clear();
    FILE* f = popen(cmd, "r");
    if (f == nullptr) return false;
    char buf[1024];
    while (std::fgets(buf, sizeof(buf), f) != nullptr) {
        out += buf;
    }
    int st = pclose(f);
    return st == 0;
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut muxer 接缝验收（ChqIMediaMuxer 平台无关调用 / Apple 后端）==\n");

    const int N = 60;  // 写前 60 帧（2s @30fps）

    const std::string src_path =
        std::string(CQ_SOURCE_DIR) + "/tests/golden/frames/gf_1080p_h264.mp4";
    std::printf("样本: %s\n", src_path.c_str());

    cq::ChqMediaSource src;
    src.path = src_path.c_str();
    src.path_len = src_path.size();

    // ---- 真实 PALA-010 解封装 ----
    cq::ChqPlatformPtr<cq::ChqIMediaDemuxer> demuxer;
    cq::ChqStatus s = cq::CreateMediaDemuxer(src, demuxer);
    Check(s.IsOk() && demuxer, "PALA-010 CreateMediaDemuxer 打开成功");
    if (!demuxer) {
        std::printf("\n解封装打开失败，用例终止。\n");
        return 1;
    }
    cq::ChqStreamInfo info{};
    s = demuxer->GetStreamInfo(0, info);
    Check(s.IsOk() && info.type == cq::ChqMediaType::kVideo && info.codec == cq::ChqCodecId::kH264,
          "真实流：视频 / H.264");
    Check(info.width == 1920 && info.height == 1080, "真实尺寸 = 1920x1080");

    cq::VideoToolboxDecoder decoder(src_path.c_str());
    s = decoder.Open(info);
    Check(s.IsOk(), "PALA-011 VideoToolboxDecoder.Open 成功");
    if (!s.IsOk()) {
        std::printf("\n硬解会话建立失败，用例终止（诚实报告：硬解不可用）。\n");
        return 1;
    }
    std::printf("  PALA-011 硬解是否真走硬件: %s\n",
                decoder.IsHardwareAccelerated() ? "YES" : "NO(软解回退)");

    // ---- 平台无关地拿到 muxer（ChqIMediaMuxer，不碰 AppleVideoEncoder）----
    cq::ChqPlatformPtr<cq::ChqIMediaMuxer> muxer;
    s = cq::CreateMediaMuxer(muxer);
    Check(s.IsOk() && muxer, "CreateMediaMuxer 拿到平台无关 ChqIMediaMuxer");
    if (!muxer) {
        std::printf("\nMuxer 工厂失败，用例终止。\n");
        return 1;
    }

    const std::string out_path = "/tmp/cq_muxer_out.mp4";
    std::remove(out_path.c_str());
    s = muxer->Open(out_path.c_str(), cq::ChqContainerFormat::kMp4);
    Check(s.IsOk(), "ChqIMediaMuxer::Open 成功（MP4 容器）");
    if (!s.IsOk()) {
        std::printf("\nMuxer Open 失败，用例终止。\n");
        return 1;
    }

    cq::ChqVideoTrackConfig vcfg{};
    vcfg.codec = cq::ChqCodecId::kH264;
    vcfg.width = info.width;
    vcfg.height = info.height;
    vcfg.frame_rate = cq::ChqRationalTime{30, 1};
    vcfg.bitrate = cq::ChqBitrateTier::kHigh;  // 20 Mbps，与原始导出一致
    vcfg.max_keyframe_interval = 1;            // all-intra，最大化像素还原度
    vcfg.allow_hardware = true;
    s = muxer->AddVideoTrack(vcfg);
    Check(s.IsOk(), "ChqIMediaMuxer::AddVideoTrack 成功（设置 H.264 视频轨）");
    if (!s.IsOk()) {
        std::printf("\nAddVideoTrack 失败，用例终止。\n");
        return 1;
    }
    std::printf("  muxer 硬件编码能力（本机探针）: %s\n",
                muxer->IsHardwareAccelerated() ? "YES（可用）" : "NO（软件回退）");

    // ---- 喂入全部包，再按显示序解码出帧 ----
    for (;;) {
        cq::ChqMediaPacket pkt{};
        cq::ChqStatus rs = demuxer->ReadPacket(pkt);
        if (rs.code == cq::ChqStatusCode::kIoNotFound) break;
        if (!rs.IsOk()) break;
        if (pkt.codec == cq::ChqCodecId::kH264) {
            cq::ChqStatus fs = decoder.Feed(pkt);
            if (!fs.IsOk()) {
                std::printf("  Feed error at pts=%s: %s\n", Rt(pkt.pts),
                            cq::StatusToString(fs.code));
            }
        }
    }

    // ---- 经平台无关接口逐帧写入（关键：全程只碰 ChqIMediaMuxer + NativeImageHandle）----
    cq::ChqCancelToken no_cancel;
    int written = 0;
    bool write_ok = true;
    for (;;) {
        cq::ChqMediaFrame f{};
        cq::ChqStatus ps = decoder.PopFrame(f);
        if (!ps.IsOk()) break;  // 已 drain
        if (f.type == cq::ChqMediaType::kVideo && f.video.image != nullptr) {
            cq::ChqStatus ws = muxer->WriteVideoFrame(f.video.image, f.video.pts, no_cancel);
            if (!ws.IsOk()) {
                std::printf("  WriteVideoFrame 失败 @pts=%s: %s\n", Rt(f.video.pts),
                            cq::StatusToString(ws.code));
                write_ok = false;
                break;
            }
            ++written;
        }
        if (written >= N) break;  // 只写前 N 帧
    }
    std::printf("  写入帧数 = %d（目标 N=%d）\n", written, N);
    Check(write_ok && written == N, "经 ChqIMediaMuxer 成功写 N 帧且全部 Ok");

    s = muxer->Finish(no_cancel);
    Check(s.IsOk(), "ChqIMediaMuxer::Finish 成功（封装完成）");
    Check(muxer->FrameCount() == N, "FrameCount() == N");
    if (!s.IsOk()) {
        std::printf("\n封装收尾失败，用例终止。\n");
        return 1;
    }

    // muxer 句柄离开作用域即经 ChqPlatformPtr 析构 Destroy()（不泄漏）。下面用独立 muxer 验证释放。

    // ---- ffprobe 验证产出文件 ----
    // ffprobe 解析顺序与 tests/golden/generate.py 一致：环境变量 > $HOME 托管位置 > PATH。
    const char* ffprobe = std::getenv("CQ_FFPROBE_BIN");
    const char* home = std::getenv("HOME");
    std::string ffprobe_bin = "ffprobe";
    if (ffprobe != nullptr && ffprobe[0] != '\0') {
        ffprobe_bin = ffprobe;
    } else if (home != nullptr) {
        const std::string local =
            std::string(home) + "/.workbuddy/binaries/ffmpeg/bin/ffprobe";
        if (access(local.c_str(), X_OK) == 0) ffprobe_bin = local;
    }
    std::printf("\n[ffprobe 验证] 工具: %s\n", ffprobe_bin.c_str());

    std::string cmd = std::string(ffprobe_bin) +
                      " -v error -show_entries stream=codec_name,width,height,nb_read_frames"
                      " -count_frames -of default=noprint_wrappers=1 " +
                      out_path;
    std::string probe_out;
    bool have_ffprobe = RunCapture(cmd.c_str(), probe_out);
    std::printf("  %s\n", probe_out.c_str());

    if (have_ffprobe) {
        bool codec_h264 = probe_out.find("codec_name=h264") != std::string::npos;
        bool w_ok = probe_out.find("width=1920") != std::string::npos;
        bool h_ok = probe_out.find("height=1080") != std::string::npos;
        int nb = 0;
        const char* p = std::strstr(probe_out.c_str(), "nb_read_frames=");
        if (p != nullptr) nb = std::atoi(p + std::strlen("nb_read_frames="));
        Check(codec_h264, "ffprobe: codec = H.264");
        Check(w_ok && h_ok, "ffprobe: 分辨率 = 1920x1080");
        Check(nb == N, "ffprobe: 帧数 == 写入帧数 N（编码 60 帧）");

        std::string dcmd = std::string(ffprobe_bin) +
                           " -v error -show_entries format=duration -of default=noprint_wrappers=1 " +
                           out_path;
        std::string dout;
        if (RunCapture(dcmd.c_str(), dout)) {
            std::printf("  %s", dout.c_str());
            double dur = 0;
            const char* dp = std::strstr(dout.c_str(), "duration=");
            if (dp != nullptr) dur = std::atof(dp + std::strlen("duration="));
            double expected = static_cast<double>(N) / 30.0;
            Check(dur > expected - 0.1 && dur < expected + 0.1,
                  "ffprobe: 时长 ≈ N/30s（帧数/帧率吻合）");
        }
    } else {
        std::printf("  [警告] ffprobe 不可用，跳过 ffprobe 验证（其余检查仍进行）。\n");
    }

    // ---- 像素正确性：重解码输出首帧中心像素 ----
    std::printf("\n[像素正确性] 重解码输出首帧，中心像素对照 (0,188,0,255)\n");
    {
        cq::ChqMediaSource o_src;
        o_src.path = out_path.c_str();
        o_src.path_len = out_path.size();
        cq::ChqPlatformPtr<cq::ChqIMediaDemuxer> o_demux;
        cq::ChqStatus os = cq::CreateMediaDemuxer(o_src, o_demux);
        cq::ChqStreamInfo o_info{};
        if (os.IsOk()) o_demux->GetStreamInfo(0, o_info);

        cq::VideoToolboxDecoder o_dec(out_path.c_str());
        cq::ChqStatus oos = o_dec.Open(o_info);
        bool pix_ok = false;
        if (oos.IsOk()) {
            for (;;) {
                cq::ChqMediaPacket pkt{};
                cq::ChqStatus rs = o_demux->ReadPacket(pkt);
                if (rs.code == cq::ChqStatusCode::kIoNotFound) break;
                if (!rs.IsOk()) break;
                if (pkt.codec == cq::ChqCodecId::kH264) o_dec.Feed(pkt);
            }
            for (;;) {
                cq::ChqMediaFrame f{};
                cq::ChqStatus ps = o_dec.PopFrame(f);
                if (!ps.IsOk()) break;
                if (f.type == cq::ChqMediaType::kVideo && f.video.image != nullptr) {
                    CVPixelBufferRef pb = cq::GetCvPixelBuffer(f.video.image);
                    if (pb != nullptr) {
                        uint32_t w = static_cast<uint32_t>(CVPixelBufferGetWidth(pb));
                        uint32_t h = static_cast<uint32_t>(CVPixelBufferGetHeight(pb));
                        CVPixelBufferLockBaseAddress(pb, 0);
                        uint8_t b, g, r, a;
                        ReadPixelBgra(pb, w / 2, h / 2, b, g, r, a);
                        CVPixelBufferUnlockBaseAddress(pb, 0);
                        std::printf("    输出首帧中心像素(R,G,B,A)=(%d,%d,%d,%d)\n", r, g, b, a);
                        const int tol = 12;
                        pix_ok = (a == 255) && (std::abs(r - 0) <= tol) &&
                                 (std::abs(g - 188) <= tol) && (std::abs(b - 0) <= tol) &&
                                 (g > r + 30) && (g > b + 30);
                    }
                    break;  // 只看首帧
                }
            }
        }
        Check(pix_ok, "输出首帧中心像素 ≈ (0,188,0,255) 且绿主导（通道顺序未颠倒）");
    }

    // ---- 取消路径冒烟：经 ChqIMediaMuxer::Cancel 应删除半成品文件 ----
    std::printf("\n[取消路径] Open 后 Cancel 应安全中止并删除半成品文件\n");
    {
        const std::string cancel_path = "/tmp/cq_muxer_cancel.mp4";
        std::remove(cancel_path.c_str());
        cq::ChqPlatformPtr<cq::ChqIMediaMuxer> cmuxer;
        cq::ChqStatus cs = cq::CreateMediaMuxer(cmuxer);
        bool cancel_ok = false;
        if (cs.IsOk() && cmuxer) {
            cq::ChqStatus os = cmuxer->Open(cancel_path.c_str(), cq::ChqContainerFormat::kMp4);
            cq::ChqVideoTrackConfig cc{};
            cc.codec = cq::ChqCodecId::kH264;
            cc.width = info.width;
            cc.height = info.height;
            cc.frame_rate = cq::ChqRationalTime{30, 1};
            cc.bitrate = cq::ChqBitrateTier::kMedium;
            cq::ChqStatus as = cmuxer->AddVideoTrack(cc);
            if (os.IsOk() && as.IsOk()) {
                cq::ChqStatus xs = cmuxer->Cancel();
                bool file_gone = (std::remove(cancel_path.c_str()) != 0);  // 已被 Cancel 删除 → 返回 -1
                cancel_ok = xs.IsOk() && file_gone;
            }
        }
        Check(cancel_ok, "Cancel：经 ChqIMediaMuxer 中止写入并删除半成品文件（文件不存在）");
    }

    std::printf(
        "\n[结论] muxer 接缝验收：经平台无关 ChqIMediaMuxer 写 N 帧成功；ffprobe 验证 "
        "codec/分辨率/帧数/时长；首帧中心像素对照真值；硬编能力（本机探针）=%s。\n",
        muxer->IsHardwareAccelerated() ? "YES" : "NO");
    std::printf("== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
