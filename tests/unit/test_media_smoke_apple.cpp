// ChuanqiCut — MEDIA-020 真实链路冒烟（Apple：PALA-010 demux + SystemFrameProvider）
//
// 目的：打通「真实 MP4 → 真实 PALA-010 解封装 → SystemFrameProvider 编排」的前半段，
// 并**如实**暴露尚未实现的阻塞点：真实解码后端（PALA-011 VideoToolbox）未做，
// 因此 provider 在解码处应返回 kDecodeUnsupported，而不是用 mock 伪造成功。
//
// 验收（诚实版）：
//   * demux 侧真的通：Open 成功、流数量=1、H.264、1920x1080、时长≈5s。
//   * AcquireFrame 在真实链路上返回 kDecodeUnsupported（解码能力不可用），
//     证明阻塞点被如实识别在「解码」而非「解封装」，绝不伪造可解码帧。
// 无缓冲输出。

#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/media/system_frame_provider.h"
#include "cq/pal/media.h"

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

    // 注入 StubDecoder（PALA-011 未实现）：真实链路在此被如实阻塞。
    cq::StubDecoder stub;
    auto provider = cq::CreateSystemFrameProvider(std::move(demuxer), &stub);
    s = provider->Open(src);
    Check(s.IsOk(), "SystemFrameProvider.Open 成功（demux 侧已通）");

    // 尝试取帧：真实解码后端缺失，必须返回解码不可用，绝不能伪造帧。
    std::printf("\n[真实取帧] AcquireFrame 在解码后端缺失下应如实失败\n");
    cq::FrameRequest req;
    req.at = cq::RationalTime{120000, 120000};  // 1.0s
    req.policy = cq::SeekPolicy::kExact;
    cq::MediaFrame f{};
    cq::CancelToken no_cancel;
    s = provider->AcquireFrame(req, f, no_cancel);
    std::printf("  AcquireFrame -> code=%s IsError=%d\n", cq::StatusToString(s.code),
                s.IsError() ? 1 : 0);
    Check(s.IsError() && s.code == cq::StatusCode::kDecodeUnsupported,
          "真实链路：解码后端(PALA-011)未实现 → 返回 kDecodeUnsupported（阻塞点如实暴露）");

    std::printf("\n[结论] demux 真实打通；解码环节被 PALA-011 阻塞，本用例如实报告，未用 mock 伪造。\n");
    std::printf("== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
