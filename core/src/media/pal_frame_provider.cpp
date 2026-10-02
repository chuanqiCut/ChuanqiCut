// ChuanqiCut — PAL 帧提供器适配器实现（BIND-003 子步骤 5）
//
// 本 TU 是 core 与 PAL 的**接缝**：core 侧第一个调用 PAL 工厂的翻译单元。
// ⚠️ 链接影响：它引用 `cq::CreateFrameProvider`（PAL 工厂）。静态库按 archive
//    member 粒度拉符号，故**只有真正用到本 TU 的目标**才会把它链进来——
//    不使用预览能力的目标（如当前无 PAL 后端的 Android 构建）不受影响。
//    这是把「core 调 PAL 工厂」隔离在独立 TU 的原因，不要把它并入其它 TU。

#include "cq/media/pal_frame_provider.h"

#include <utility>  // std::move

namespace cq {

Status PalFrameProvider::Open(const MediaSource& src) {
    (void)src;
    return pal_ ? Status::Ok() : Status(StatusCode::kInvalidArgument);
}

Status PalFrameProvider::Seek(const RationalTime& target, SeekPolicy policy,
                              const CancelToken& token) {
    // PAL 契约只承诺精确 seek，无 policy 概念。非 kExact 若静默按精确处理，
    // 调用方会误以为拿到了「最近关键帧」——与其假绿，不如明确拒绝。
    if (policy != SeekPolicy::kExact) return Status(StatusCode::kInvalidArgument);
    if (!pal_) return Status(StatusCode::kInvalidArgument);
    return pal_->Seek(target, token);
}

Status PalFrameProvider::AcquireFrame(const FrameRequest& req, MediaFrame& out_frame,
                                      const CancelToken& token) {
    if (req.policy != SeekPolicy::kExact) return Status(StatusCode::kInvalidArgument);
    if (!pal_) return Status(StatusCode::kInvalidArgument);
    // PAL 的 AcquireFrame 语义即「目标时间处真正的展示帧」（契约原文），
    // 与 core 的 kExact 一致，故直接转发。
    return pal_->AcquireFrame(req.at, out_frame, token);
}

void PalFrameProvider::ReleaseFrame(MediaFrame& frame) {
    if (!pal_) return;
    pal_->ReleaseFrame(frame);
}

Status PalFrameProvider::GetDuration(RationalTime& out) const {
    if (!pal_) return Status(StatusCode::kInvalidArgument);
    return pal_->GetDuration(out);
}

Status PalFrameProviderFactory::Create(const MediaSource& src,
                                       std::unique_ptr<FrameProvider>& out) {
    out.reset();
    PalPtr<IFrameProvider> pal;
    Status s = CreateFrameProvider(src, pal);
    if (!s.IsOk()) return s;
    if (!pal) return Status(StatusCode::kInternal);
    out = std::unique_ptr<FrameProvider>(new PalFrameProvider(std::move(pal)));
    return Status::Ok();
}

}  // namespace cq
