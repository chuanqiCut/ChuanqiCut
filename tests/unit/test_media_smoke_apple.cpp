// ChuanqiCut — MEDIA-020 真实链路冒烟（Apple：PALA-010 demux + PALA-011 硬解 + Provider）
//
// 目的：打通「真实 MP4 → 真实 PALA-010 解封装 → PALA-011 VideoToolbox 硬解 →
// SystemFrameProvider 编排」的**完整端到端**，并验证 AcquireFrame 返回**真实解码帧**
// （PALA-011 落地后不再是 kDecodeUnsupported）。解码结果须像素正确（非全黑）。
//
// 验收（打通版）：
//   * demux 侧真的通：Open 成功、流数量=1、H.264、1920x1080、时长≈5s。
//   * AcquireFrame 在真实链路上返回真实解码帧（kExact 命中目标展示帧），像素非全黑。
// 无缓冲输出。

#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>

#include <CoreVideo/CoreVideo.h>

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
    std::snprintf(buf, sizeof(buf), "v=%lld/%d (%.4fs)",
                  static_cast<long long>(t.value), static_cast<int>(t.timescale),
                  t.ToSeconds());
    return buf;
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut MEDIA-020 真实链路冒烟（Apple demux + Provider）==\n");

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

    int32_t n = demuxer->GetStreamCount();
    std::printf("  流数量 = %d\n", n);
    Check(n == 1, "真实流数量 = 1");

    cq::StreamInfo info{};
    s = demuxer->GetStreamInfo(0, info);
    Check(s.IsOk() && info.type == cq::MediaType::kVideo && info.codec == cq::CodecId::kH264,
          "真实流：视频 / H.264");
    Check(info.width == 1920 && info.height == 1080, "真实尺寸 = 1920x1080");

    cq::RationalTime dur{0, 1};
    s = demuxer->GetDuration(dur);
    Check(s.IsOk() && dur.value >= 560000 && dur.value <= 640000,
          "真实时长 ≈ 5.0s（≈600000 ticks @120000）");
    std::printf("  真实时长 = %s\n", Rt(dur));

    // 注入 PALA-011 VideoToolbox 硬解后端（真实链路打通）。
    cq::VideoToolboxDecoder decoder(src.path);
    auto provider = cq::CreateSystemFrameProvider(std::move(demuxer), &decoder);
    s = provider->Open(src);
    Check(s.IsOk(), "SystemFrameProvider.Open 成功（demux + 硬解后端均通）");

    // 真实取帧：端到端打通，AcquireFrame 必须返回真实解码帧（非 kDecodeUnsupported）。
    std::printf("\n[真实取帧] AcquireFrame 应返回真实解码帧（像素正确，非全黑）\n");
    cq::FrameRequest req;
    req.at = cq::RationalTime{120000, 120000};  // 1.0s
    req.policy = cq::SeekPolicy::kExact;
    cq::MediaFrame f{};
    cq::CancelToken no_cancel;
    s = provider->AcquireFrame(req, f, no_cancel);
    std::printf("  AcquireFrame -> code=%s IsError=%d\n", cq::StatusToString(s.code),
                s.IsError() ? 1 : 0);
    Check(s.IsOk() && f.type == cq::MediaType::kVideo && f.video.image != nullptr,
          "真实链路打通：AcquireFrame 返回真实解码帧（不再是 kDecodeUnsupported）");

    // 像素级复核：中心像素非全黑（smptebars 彩条，中心落在绿/青区域，绝不黑）。
    if (f.type == cq::MediaType::kVideo && f.video.image != nullptr) {
        CVPixelBufferRef pb = cq::GetCvPixelBuffer(f.video.image);
        if (pb != nullptr) {
            CVPixelBufferLockBaseAddress(pb, 0);
            uint8_t b = 0, g = 0, r = 0, a = 0;
            const uint8_t* base =
                static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pb));
            size_t stride = CVPixelBufferGetBytesPerRow(pb);
            uint32_t w = static_cast<uint32_t>(CVPixelBufferGetWidth(pb));
            uint32_t h = static_cast<uint32_t>(CVPixelBufferGetHeight(pb));
            const uint8_t* px =
                base + static_cast<size_t>(h / 2) * stride + static_cast<size_t>(w / 2) * 4;
            b = px[0];
            g = px[1];
            r = px[2];
            a = px[3];
            CVPixelBufferUnlockBaseAddress(pb, 0);
            std::printf("    中心像素(R,G,B,A)=(%d,%d,%d,%d)\n", r, g, b, a);
            Check(a == 255 && (r != 0 || g != 0 || b != 0),
                  "真实解码帧中心像素非全黑且 alpha=255");
        }
    }

    std::printf("\n[结论] demux + 硬解 + 编排端到端打通，AcquireFrame 返回真实帧；硬解是否硬件=%s。\n",
                decoder.IsHardwareAccelerated() ? "YES" : "NO");

    std::printf("== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
