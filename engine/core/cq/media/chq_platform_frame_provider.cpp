// ChuanqiCut — Platform 帧提供器适配器实现（BIND-003 子步骤 5）
//
// 本 TU 是 core 与 Platform 的**接缝**：core 侧第一个调用 Platform 工厂的翻译单元。
// ⚠️ 链接影响：它引用 `cq::CreateFrameProvider`（Platform 工厂）。静态库按 archive
//    member 粒度拉符号，故**只有真正用到本 TU 的目标**才会把它链进来——
//    不使用预览能力的目标（如当前无 Platform 后端的 Android 构建）不受影响。
//    这是把「core 调 Platform 工厂」隔离在独立 TU 的原因，不要把它并入其它 TU。

#include "cq/media/chq_platform_frame_provider.h"

#include <utility>  // std::move

namespace cq {

ChqStatus ChqPlatformFrameProvider::Open(const ChqMediaSource& src) {
    (void)src;
    return platform_ ? ChqStatus::Ok() : ChqStatus(ChqStatusCode::kInvalidArgument);
}

ChqStatus ChqPlatformFrameProvider::Seek(const ChqRationalTime& target, ChqSeekPolicy policy,
                                         const ChqCancelToken& token) {
    if (!platform_) return ChqStatus(ChqStatusCode::kInvalidArgument);
    // P142：不再拒绝非 kExact 策略。此前「Platform 只承诺精确 seek，非 kExact 一律拒绝」，
    // 把 core 已实现的 kKeyframeBefore/kNearest 挡在门外 —— 但 scrub 拖动要的正是「廉价
    // 关键帧定位」（用户：滑动时快速 seek，结束再精准 seek）。core 层（ChqSystemFrameProvider）
    // 本就完整实现三种策略，此处只做忠实透传（int32_t 跨接缝，见 chq_media.h 注释）。
    return platform_->Seek(target, token, static_cast<int32_t>(policy));
}

ChqStatus ChqPlatformFrameProvider::AcquireFrame(const ChqFrameRequest& req, ChqMediaFrame& out_frame,
                                                 const ChqCancelToken& token) {
    if (!platform_) return ChqStatus(ChqStatusCode::kInvalidArgument);
    // 同上：req.policy（由调用方决定，如预览 scrub 传 kKeyframeBefore）透传给平台后端，
    // 由底层 ChqSystemFrameProvider 按策略真正实现。丢弃 policy 会静默退化成精确解码。
    return platform_->AcquireFrame(req.at, out_frame, token, static_cast<int32_t>(req.policy));
}

void ChqPlatformFrameProvider::ReleaseFrame(ChqMediaFrame& frame) {
    if (!platform_) return;
    platform_->ReleaseFrame(frame);
}

ChqStatus ChqPlatformFrameProvider::GetDuration(ChqRationalTime& out) const {
    if (!platform_) return ChqStatus(ChqStatusCode::kInvalidArgument);
    return platform_->GetDuration(out);
}

ChqStatus ChqPlatformFrameProviderFactory::Create(const ChqMediaSource& src,
                                                  std::unique_ptr<ChqFrameProvider>& out) {
    out.reset();
    ChqPlatformPtr<ChqIFrameProvider> platform;
    ChqStatus s = CreateFrameProvider(src, platform);
    if (!s.IsOk()) return s;
    if (!platform) return ChqStatus(ChqStatusCode::kInternal);
    out = std::unique_ptr<ChqFrameProvider>(new ChqPlatformFrameProvider(std::move(platform)));
    return ChqStatus::Ok();
}

}  // namespace cq
