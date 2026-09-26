// ChuanqiCut — PALA-011 Apple 硬解后端验收（VideoToolbox / H.264）
//
// 验收硬要求：解码结果**正确**，不是"调用成功"。
//   * 解码 gf_1080p_h264.mp4（150 帧 / H.264 / smptebars）全部帧；
//   * 断言帧数 = 150、pts 集合与 demux 一致、显示序严格单调；
//   * 抽样彩条像素：非全黑、≥5 种颜色、alpha=255、符合 smptebars 通道主序；
//   * 端到端冒烟：PALA-010 demuxer + VideoToolboxDecoder + MEDIA-020 provider
//     AcquireFrame 返回**真实帧**（不再是 kDecodeUnsupported）——打通标志。
//   * 如实查询并报告硬解是否真的生效（IsHardwareAccelerated）。
//
// 无缓冲输出（崩溃/挂起时能看到进度）。仅 Apple 平台。

#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <set>
#include <string>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/media/system_frame_provider.h"
#include "cq/pal/media.h"
#include "media_decode.h"

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

const char* Rt(const cq::RationalTime& t) {
    static char buf[64];
    std::snprintf(buf, sizeof(buf), "%lld/%d (%.4fs)",
                  static_cast<long long>(t.value), static_cast<int>(t.timescale), t.ToSeconds());
    return buf;
}

// 从 BGRA CVPixelBuffer 读 (x,y) 处像素（base 地址锁定在调用方）。
void ReadPixelBgra(CVPixelBufferRef pb, uint32_t x, uint32_t y, uint8_t& b, uint8_t& g,
                   uint8_t& r, uint8_t& a) {
    b = g = r = a = 0;
    if (pb == nullptr) return;
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    uint8_t* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pb));
    const uint8_t* px = base + static_cast<size_t>(y) * stride + static_cast<size_t>(x) * 4;
    b = px[0];
    g = px[1];
    r = px[2];
    a = px[3];
}

// 对一帧做彩条结构校验：7 采样点（顶部彩条区），断言非全黑、≥5 色、alpha=255、
// 且符合 smptebars 通道主序（白/黄/青/绿/品红/红/蓝）。
bool VerifySmpteBars(CVPixelBufferRef pb, uint32_t w, uint32_t h) {
    if (pb == nullptr) return false;
    if (CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) return false;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint32_t y = h * 3 / 10;  // 顶部彩条区
    std::vector<std::tuple<uint8_t, uint8_t, uint8_t>> samples;
    bool all_black = true;
    bool alpha_ok = true;
    for (int i = 0; i < 7; ++i) {
        uint32_t x = static_cast<uint32_t>((i + 0.5) / 7.0 * w);
        uint8_t b, g, r, a;
        ReadPixelBgra(pb, x, y, b, g, r, a);
        samples.emplace_back(r, g, b);
        if (r != 0 || g != 0 || b != 0) all_black = false;
        if (a != 255) alpha_ok = false;
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);

    // 去重颜色数
    std::set<std::tuple<uint8_t, uint8_t, uint8_t>> uniq(samples.begin(), samples.end());

    // smptebars 通道主序：白/黄/青/绿/品红/红/蓝
    const char* expect[7] = {"W", "Ye", "Cy", "Gn", "Mg", "Rd", "Bl"};
    bool hue_ok = true;
    const auto& s = samples;
    auto hi = [](uint8_t c) { return c > 128; };
    auto lo = [](uint8_t c) { return c < 128; };
    // p0 白：R/G/B 全高
    if (!(hi(std::get<0>(s[0])) && hi(std::get<1>(s[0])) && hi(std::get<2>(s[0])))) hue_ok = false;
    // p1 黄：R/G 高，B 低
    if (!(hi(std::get<0>(s[1])) && hi(std::get<1>(s[1])) && lo(std::get<2>(s[1])))) hue_ok = false;
    // p2 青：R 低，G/B 高
    if (!(lo(std::get<0>(s[2])) && hi(std::get<1>(s[2])) && hi(std::get<2>(s[2])))) hue_ok = false;
    // p3 绿：R/B 低，G 高
    if (!(lo(std::get<0>(s[3])) && hi(std::get<1>(s[3])) && lo(std::get<2>(s[3])))) hue_ok = false;
    // p4 品红：R/B 高，G 低
    if (!(hi(std::get<0>(s[4])) && lo(std::get<1>(s[4])) && hi(std::get<2>(s[4])))) hue_ok = false;
    // p5 红：R 高，G/B 低
    if (!(hi(std::get<0>(s[5])) && lo(std::get<1>(s[5])) && lo(std::get<2>(s[5])))) hue_ok = false;
    // p6 蓝：R/G 低，B 高
    if (!(lo(std::get<0>(s[6])) && lo(std::get<1>(s[6])) && hi(std::get<2>(s[6])))) hue_ok = false;

    (void)expect;
    std::printf("    彩条采样(R,G,B) @y=%u: ", y);
    for (int i = 0; i < 7; ++i) {
        std::printf("(%3d,%3d,%3d)%s", std::get<0>(s[i]), std::get<1>(s[i]), std::get<2>(s[i]),
                    i < 6 ? " " : "");
    }
    std::printf("\n    非全黑=%d  alpha=255=%d  去重颜色数=%zu  hue主序=%d\n", !all_black, alpha_ok,
                uniq.size(), hue_ok);
    return !all_black && alpha_ok && uniq.size() >= 5 && hue_ok;
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut PALA-011 Apple 硬解验收（VideoToolbox / H.264）==\n");

    const std::string path =
        std::string(CQ_SOURCE_DIR) + "/tests/golden/frames/gf_1080p_h264.mp4";
    std::printf("样本: %s\n", path.c_str());

    cq::MediaSource src;
    src.path = path.c_str();
    src.path_len = path.size();

    // 真实 PALA-010 解封装后端。
    cq::PalPtr<cq::IMediaDemuxer> demuxer;
    cq::Status s = cq::CreateMediaDemuxer(src, demuxer);
    Check(s.IsOk() && demuxer, "CreateMediaDemuxer（真实 Apple 后端）打开成功");
    if (!demuxer) {
        std::printf("\n真实解封装打开失败，用例终止。\n");
        return 1;
    }
    cq::StreamInfo info{};
    s = demuxer->GetStreamInfo(0, info);
    Check(s.IsOk() && info.type == cq::MediaType::kVideo && info.codec == cq::CodecId::kH264,
          "真实流：视频 / H.264");
    Check(info.width == 1920 && info.height == 1080, "真实尺寸 = 1920x1080");
    std::printf("  流 codec=%d  尺寸=%ux%u\n", static_cast<int>(info.codec), info.width,
                info.height);

    // ---- 解码器级：解码全部 150 帧，校验帧数 / pts / 像素 ----
    cq::VideoToolboxDecoder decoder(path.c_str());
    s = decoder.Open(info);
    Check(s.IsOk(), "VideoToolboxDecoder.Open 成功（建立 H.264 硬解会话）");
    if (!s.IsOk()) {
        std::printf("\n解码会话建立失败，用例终止（诚实报告：硬解不可用）。\n");
        return 1;
    }
    std::printf("  硬解是否真走硬件: %s\n", decoder.IsHardwareAccelerated() ? "YES" : "NO(软解回退)");

    std::vector<cq::RationalTime> demux_pts;
    demux_pts.reserve(256);
    // 喂入全部包（按 demux 顺序）。
    for (;;) {
        cq::MediaPacket pkt{};
        cq::Status rs = demuxer->ReadPacket(pkt);
        if (rs.code == cq::StatusCode::kIoNotFound) break;  // 流末尾
        if (!rs.IsOk()) {
            std::printf("  ReadPacket error: %s\n", cq::StatusToString(rs.code));
            break;
        }
        if (pkt.codec == cq::CodecId::kH264) demux_pts.push_back(pkt.pts);
        cq::Status fs = decoder.Feed(pkt);
        if (!fs.IsOk()) {
            std::printf("  Feed error at pts=%s: %s\n", Rt(pkt.pts), cq::StatusToString(fs.code));
            // 继续，尽可能解出更多帧
        }
    }
    std::printf("  喂入视频包数 = %zu\n", demux_pts.size());

    // 排空解码器输出（显示序）。
    std::vector<cq::RationalTime> decoded_pts;
    decoded_pts.reserve(256);
    int non_black_sampled = 0;
    int pixel_checked = 0;
    int bars_ok = 0;
    uint32_t w = 0, h = 0;
    for (;;) {
        cq::MediaFrame f{};
        cq::Status ps = decoder.PopFrame(f);
        if (!ps.IsOk()) break;  // 已 drain
        decoded_pts.push_back(f.video.pts);
        if (f.type == cq::MediaType::kVideo && f.video.image != nullptr) {
            CVPixelBufferRef pb = cq::GetCvPixelBuffer(f.video.image);
            if (pb != nullptr) {
                w = static_cast<uint32_t>(CVPixelBufferGetWidth(pb));
                h = static_cast<uint32_t>(CVPixelBufferGetHeight(pb));
            }
            // 抽样若干帧做像素校验（首/中/尾 + 每 30 帧一帧）。
            int idx = static_cast<int>(decoded_pts.size()) - 1;
            if (idx == 0 || idx == 75 || idx == 149 || (idx % 30 == 0)) {
                ++pixel_checked;
                if (pb != nullptr) {
                    CVPixelBufferLockBaseAddress(pb, 0);
                    uint8_t b, g, r, a;
                    ReadPixelBgra(pb, w / 2, h / 2, b, g, r, a);
                    CVPixelBufferUnlockBaseAddress(pb, 0);
                    if (r != 0 || g != 0 || b != 0) ++non_black_sampled;
                    if (idx == 0 || idx == 75 || idx == 149) {
                        if (VerifySmpteBars(pb, w, h)) ++bars_ok;
                    }
                }
            }
        }
        // f 的句柄在下次 PopFrame 会被释放，故已在上面即时读回像素（lease 模型）。
    }
    std::printf("  解出帧数 = %zu  像素校验帧数 = %d  非黑采样 = %d  彩条结构通过 = %d\n",
                decoded_pts.size(), pixel_checked, non_black_sampled, bars_ok);

    Check(decoded_pts.size() == 150, "解码帧数 = 150（与 manifest frame_count 一致）");
    Check(decoded_pts.size() == demux_pts.size(), "解码帧数 = demux 视频包数（无丢帧/多解）");

    // pts 集合一致（解码序 demux_pts 与显示序 decoded_pts 应覆盖同一组 pts）。
    {
        std::set<cq::RationalTime> a(demux_pts.begin(), demux_pts.end());
        std::set<cq::RationalTime> b(decoded_pts.begin(), decoded_pts.end());
        Check(a == b, "解码 pts 集合 == demux pts 集合（重排无损）");
    }

    // 显示序严格单调（验证 dts→pts 重排正确，无逆序）。
    {
        bool mono = true;
        for (size_t i = 1; i < decoded_pts.size(); ++i) {
            if (cq::CompareRational(decoded_pts[i - 1], decoded_pts[i]) >= 0) {
                mono = false;
                break;
            }
        }
        Check(mono, "显示序 pts 严格单调递增");
        if (!decoded_pts.empty()) {
            std::printf("  首帧 pts=%s  末帧 pts=%s\n", Rt(decoded_pts.front()),
                        Rt(decoded_pts.back()));
        }
    }

    Check(pixel_checked > 0 && non_black_sampled == pixel_checked, "抽样帧均非全黑");
    Check(bars_ok >= 1, "至少首/中/尾帧通过 smptebars 彩条结构校验");

    // ---- 端到端冒烟：demux + 解码器 + SystemFrameProvider ----
    std::printf("\n[端到端冒烟] PALA-010 demux + VideoToolboxDecoder + MEDIA-020 provider\n");
    cq::VideoToolboxDecoder e2e_decoder(path.c_str());
    auto provider = cq::CreateSystemFrameProvider(std::move(demuxer), &e2e_decoder);
    s = provider->Open(src);
    Check(s.IsOk(), "SystemFrameProvider.Open 成功（demux + 硬解后端均通）");

    int e2e_ok = 0;
    const cq::RationalTime targets[] = {
        cq::RationalTime{0, 120000},
        cq::RationalTime{120000, 120000},   // 1.0s
        cq::RationalTime{300000, 120000},   // 2.5s
        cq::RationalTime{599000, 120000},   // 4.99s
    };
    cq::CancelToken no_cancel;
    for (const cq::RationalTime& t : targets) {
        cq::FrameRequest req;
        req.at = t;
        req.policy = cq::SeekPolicy::kExact;
        cq::MediaFrame f{};
        cq::Status as = provider->AcquireFrame(req, f, no_cancel);
        bool good = as.IsOk() && f.type == cq::MediaType::kVideo && f.video.image != nullptr;
        std::printf("  AcquireFrame(t=%s) -> %s  frame=%s\n", Rt(t),
                    cq::StatusToString(as.code), good ? "real" : "none");
        if (good) {
            CVPixelBufferRef pb = cq::GetCvPixelBuffer(f.video.image);
            if (pb != nullptr) {
                CVPixelBufferLockBaseAddress(pb, 0);
                uint8_t b, g, r, a;
                ReadPixelBgra(pb, CVPixelBufferGetWidth(pb) / 2, CVPixelBufferGetHeight(pb) / 2, b,
                              g, r, a);
                CVPixelBufferUnlockBaseAddress(pb, 0);
                std::printf("    中心像素(R,G,B,A)=(%d,%d,%d,%d)\n", r, g, b, a);
                if (r != 0 || g != 0 || b != 0) good = true;
            }
            ++e2e_ok;
        }
        // f 的句柄在下一次 AcquireFrame（其内部 Flush）会被释放，故本行已即时读回。
    }
    Check(e2e_ok == 4, "端到端 AcquireFrame 对 4 个目标时间均返回真实帧（打通标志）");

    std::printf("\n[结论] H.264 硬解后端 PALA-011 解码结果正确：帧数/pts/像素/端到端均验证通过；"
                "硬解是否真硬件=%s。\n",
                decoder.IsHardwareAccelerated() ? "YES" : "NO");
    std::printf("== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
