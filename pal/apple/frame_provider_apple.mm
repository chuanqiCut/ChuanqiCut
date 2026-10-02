// ChuanqiCut — Apple 侧帧提供器（PAL 契约 `cq::CreateFrameProvider` 的实现）
//
// ⚠️ 本函数自 CORE-006（2026-09-25）起在 pal/media.h 里**只有声明、从未实现**，
//    直到 BIND-003 子步骤 5（2026-10-02）才落地。它是本项目第 5 次同类问题
//    （cq_build_anchor / 能力查询 / BIND-001 实现 / test_media_decode_apple 之后的又一次）。
//
// 装配公式：
//   CreateMediaDemuxer（PALA-010）+ VideoToolboxDecoder（PALA-011）
//   → CreateSystemFrameProvider（MEDIA-020 编排，接管解码器所有权）
//   → 本文件的 CqFrameProvider 包成 PAL 的 IFrameProvider
//
// 为什么外面还要包一层 IFrameProvider：PAL 只暴露平台能力，取帧的**跨平台编排**
// （精确 seek / B 帧处理）属于 core（MEDIA-020）。故本类是「core 编排 + 平台解码器」
// 装配结果的 PAL 侧外观，不含新的编排逻辑。

#include <string>
#include <utility>  // std::move

#include "cq/media/system_frame_provider.h"  // CreateSystemFrameProvider（所有权重载）
#include "cq/pal/media.h"                    // IFrameProvider / MediaSource / CreateMediaDemuxer
#include "media_decode.h"                    // VideoToolboxDecoder（PALA-011，仅 Apple TU 可见）

namespace cq {
namespace {

class CqFrameProvider final : public IFrameProvider {
public:
    Status Open(const MediaSource& src) override {
        if (src.path == nullptr || src.path_len == 0) {
            return Status(StatusCode::kInvalidArgument);
        }

        // PALA-010：解封装
        PalPtr<IMediaDemuxer> demuxer;
        Status s = CreateMediaDemuxer(src, demuxer);
        if (!s.IsOk()) return s;
        if (!demuxer) return Status(StatusCode::kInternal);

        // PALA-011：硬解。解码器是堆对象，交给 provider 接管所有权（AdoptDecoder），
        // 避免「provider 活着但 decoder 已析构」的悬垂。
        // path 单独拷一份：MediaSource 只有「指针 + 长度」，不保证以 NUL 结尾。
        const std::string path(src.path, src.path_len);
        auto decoder = std::unique_ptr<IFrameDecoder>(new VideoToolboxDecoder(path.c_str()));

        provider_ = CreateSystemFrameProvider(std::move(demuxer), std::move(decoder));
        if (!provider_) return Status(StatusCode::kInternal);

        // Open 会读流信息并建立 VideoToolbox 会话；失败如实透传，不降级为「半可用」。
        return provider_->Open(src);
    }

    Status Seek(const RationalTime& target, const CancelToken& token) override {
        if (!provider_) return Status(StatusCode::kInvalidArgument);
        return provider_->Seek(target, SeekPolicy::kExact, token);
    }

    // PAL 契约承诺「精确 seek」：调用方拿到的一定是目标时间处的帧。
    // 故这里固定按 kExact 走 core 编排，不接受非精确策略——若将来需要
    // kKeyframeBefore / kNearest（缩略图 / 快速 scrub），应扩展 PAL 接口携带策略，
    // 而不是在这里静默降级。
    Status AcquireFrame(const RationalTime& at, MediaFrame& out_frame,
                        const CancelToken& token) override {
        if (!provider_) return Status(StatusCode::kInvalidArgument);
        FrameRequest req;
        req.at = at;
        req.policy = SeekPolicy::kExact;
        return provider_->AcquireFrame(req, out_frame, token);
    }

    void ReleaseFrame(MediaFrame& frame) override {
        if (!provider_) return;
        provider_->ReleaseFrame(frame);
    }

    Status GetDuration(RationalTime& out) const override {
        if (!provider_) return Status(StatusCode::kInvalidArgument);
        return provider_->GetDuration(out);
    }

    void Destroy() override { delete this; }

private:
    std::unique_ptr<FrameProvider> provider_;
};

}  // namespace

Status CreateFrameProvider(const MediaSource& src, PalPtr<IFrameProvider>& out_provider) {
    out_provider.reset();
    auto* p = new CqFrameProvider();
    Status s = p->Open(src);
    if (!s.IsOk()) {
        p->Destroy();
        return s;
    }
    out_provider = PalPtr<IFrameProvider>(p);
    return Status::Ok();
}

}  // namespace cq
