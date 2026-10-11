// ChuanqiCut — Platform 帧提供器适配器实现（BIND-003 子步骤 5）
//
// 本 TU 是 core 与 Platform 的**接缝**：core 侧第一个调用 Platform 工厂的翻译单元。
// ⚠️ 链接影响：它引用 `cq::CreateFrameProvider`（Platform 工厂）。静态库按 archive
//    member 粒度拉符号，故**只有真正用到本 TU 的目标**才会把它链进来——
//    不使用预览能力的目标（如当前无 Platform 后端的 Android 构建）不受影响。
//    这是把「core 调 Platform 工厂」隔离在独立 TU 的原因，不要把它并入其它 TU。

#include "cq/media/platform_frame_provider.h"

#include <utility>  // std::move

namespace cq {

Status PlatformFrameProvider::Open(const MediaSource& src) {
    (void)src;
    return platform_ ? Status::Ok() : Status(StatusCode::kInvalidArgument);
}

Status PlatformFrameProvider::Seek(const RationalTime& target, SeekPolicy policy,
                              const CancelToken& token) {
    // Platform 契约只承诺精确 seek，无 policy 概念。非 kExact 若静默按精确处理，
    // 调用方会误以为拿到了「最近关键帧」——与其假绿，不如明确拒绝。
    if (policy != SeekPolicy::kExact) return Status(StatusCode::kInvalidArgument);
    if (!platform_) return Status(StatusCode::kInvalidArgument);
    return platform_->Seek(target, token);
}

Status PlatformFrameProvider::AcquireFrame(const FrameRequest& req, MediaFrame& out_frame,
                                      const CancelToken& token) {
    if (req.policy != SeekPolicy::kExact) return Status(StatusCode::kInvalidArgument);
    if (!platform_) return Status(StatusCode::kInvalidArgument);
    // Platform 的 AcquireFrame 语义即「目标时间处真正的展示帧」（契约原文），
    // 与 core 的 kExact 一致，故直接转发。
    return platform_->AcquireFrame(req.at, out_frame, token);
}

void PlatformFrameProvider::ReleaseFrame(MediaFrame& frame) {
    if (!platform_) return;
    platform_->ReleaseFrame(frame);
}

Status PlatformFrameProvider::GetDuration(RationalTime& out) const {
    if (!platform_) return Status(StatusCode::kInvalidArgument);
    return platform_->GetDuration(out);
}

Status PlatformFrameProviderFactory::Create(const MediaSource& src,
                                       std::unique_ptr<FrameProvider>& out) {
    out.reset();
    PlatformPtr<IFrameProvider> platform;
    Status s = CreateFrameProvider(src, platform);
    if (!s.IsOk()) return s;
    if (!platform) return Status(StatusCode::kInternal);
    out = std::unique_ptr<FrameProvider>(new PlatformFrameProvider(std::move(platform)));
    return Status::Ok();
}

}  // namespace cq
