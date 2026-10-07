// ChuanqiCut — 取帧链路真实验证（BIND-003 子步骤 2）
//
// 目的：证明「给定素材 + 时间戳 → 拿到真实解码帧」这条链路是通的。
// 走 **core 编排层**：SystemFrameProvider(PALA-010 demuxer + PALA-011 VideoToolboxDecoder)。
//
// ⚠️ 本文件最初的写法是直接用 PAL 的 `CreateFrameProvider` —— **那是错的**：
//    该函数在 pal/media.h 里只有声明，Apple 后端并未实现（链接期
//    "symbol(s) not found for architecture x86_64"）。
//    真正实现的是 core 层的 `IFrameDecoder`（VideoToolboxDecoder），
//    所以要走 core 的 SystemFrameProvider 编排，而不是 PAL 的工厂。
//
// 验收：不只是"调用成功"，而是帧本身可验证 ——
//   * 类型是视频、宽高非零、image 句柄非空（可直接零拷贝导入 GPU）
//   * 两个不同时刻取到的帧 pts 不同（证明真 seek 了，不是反复返回同一帧）

#include <cstdio>
#include <string>
#include <utility>  // std::move

#include "cq/base/concurrency.h"
#include "cq/base/status.h"
#include "cq/base/rational_time.h"
#include "cq/media/system_frame_provider.h"
#include "cq/pal/media.h"
#include "media_decode.h"  // PALA-011 VideoToolboxDecoder（仅 Apple TU 可见）

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

cq::RationalTime Ms(int64_t ms) {
    return cq::RationalTime(ms * 120, cq::kProjectTimeScale);
}

// 取一帧并校验；返回该帧 pts（失败返回 -1）
int64_t AcquireAndCheck(cq::FrameProvider* provider, int64_t at_ms, const char* label) {
    cq::CancelToken token;
    cq::FrameRequest req;
    req.at = Ms(at_ms);
    req.policy = cq::SeekPolicy::kExact;  // 精确 seek：编辑正确性优先

    cq::Status st = provider->Seek(req.at, req.policy, token);
    if (!st.IsOk()) {
        std::printf("  FAIL: [%s] Seek 失败 (code=%d)\n", label, static_cast<int>(st.code));
        ++g_checks;
        ++g_failures;
        return -1;
    }

    cq::MediaFrame frame;
    st = provider->AcquireFrame(req, frame, token);
    if (!st.IsOk()) {
        std::printf("  FAIL: [%s] AcquireFrame 失败 (code=%d)\n", label,
                    static_cast<int>(st.code));
        ++g_checks;
        ++g_failures;
        return -1;
    }

    const bool ok = (frame.type == cq::MediaType::kVideo) && frame.video.width > 0 &&
                    frame.video.height > 0 && frame.video.image != nullptr;
    std::printf("  [%s] %ux%u pts=%lld\n", label, frame.video.width, frame.video.height,
                static_cast<long long>(frame.video.pts.value));
    Check(ok, "帧有效：视频类型 / 宽高非零 / image 句柄非空");

    const int64_t pts = ok ? frame.video.pts.value : -1;
    provider->ReleaseFrame(frame);  // lease 归还，否则 provider 池无法回收
    return pts;
}

}  // namespace

int main() {
    std::printf("=== BIND-003 子步骤 2：取帧链路（core 编排 + 硬解）===\n");

    const std::string path =
        std::string(CQ_SOURCE_DIR) + "/tests/golden/frames/gf_1080p_h264.mp4";
    std::printf("样本: %s\n", path.c_str());

    cq::MediaSource src;
    src.path = path.c_str();
    src.path_len = path.size();

    // PALA-010：解封装
    cq::PalPtr<cq::IMediaDemuxer> demuxer;
    if (!cq::CreateMediaDemuxer(src, demuxer).IsOk() || !demuxer) {
        std::printf("  FAIL: CreateMediaDemuxer 失败\n");
        std::printf("\nFAILED: 1 checks, 1 failures\n");
        return 1;
    }
    Check(true, "CreateMediaDemuxer（PALA-010）");

    // PALA-011：VideoToolbox 硬解（实现 core 的 IFrameDecoder）
    cq::VideoToolboxDecoder decoder(path.c_str());
    Check(true, "VideoToolboxDecoder 构造（PALA-011）");

    // MEDIA-020：core 编排层
    auto provider = cq::CreateSystemFrameProvider(std::move(demuxer), &decoder);
    Check(provider != nullptr, "CreateSystemFrameProvider（MEDIA-020）");
    Check(provider->Open(src).IsOk(), "provider->Open(素材)");

    cq::RationalTime duration;
    if (provider->GetDuration(duration).IsOk()) {
        std::printf("  时长: %lld ticks (ts=%d)\n", static_cast<long long>(duration.value),
                    duration.timescale);
    }

    // 两个相隔较远的时刻：若实现反复返回同一帧，pts 会相同 → 暴露"假 seek"
    const int64_t pts_a = AcquireAndCheck(provider.get(), 500, "t=0.5s");
    const int64_t pts_b = AcquireAndCheck(provider.get(), 2000, "t=2.0s");

    if (pts_a >= 0 && pts_b >= 0) {
        Check(pts_a != pts_b, "两个时刻 pts 不同（真 seek，不是同一帧）");
        Check(pts_b > pts_a, "t=2.0s 的帧晚于 t=0.5s（正放语义）");
    }

    std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
