// ChuanqiCut — Platform 帧提供器适配器（BIND-003 子步骤 5）
//
// 作用：把 Platform 的 `ChqIFrameProvider`（platform/media.h，平台能力）包成 core 的
// `ChqFrameProvider`（cq/media/frame_provider.h，编辑侧编排抽象），
// 使 core 的预览渲染器、以及 core 侧的 C ABI 门面，都能经 Platform 工厂拿到取帧能力，
// 而**不需要** core 反向依赖任何平台实现。
//
// 为什么要这一层：
//   Platform 的 ChqIFrameProvider 是「平台后端」（demux + 解码 + 精确 seek 的平台实现）；
//   core 的 ChqFrameProvider 是「编辑侧抽象」（带 ChqSeekPolicy、帧缓存、解码器池编排）。
//   两者语义重叠但层次不同。Platform 侧的实现内部仍然用 MEDIA-020 ChqSystemFrameProvider
//   做编排（见 platform/apple/frame_provider_apple.mm），故这里只是**形状适配**，
//   不引入第二套取帧逻辑。
//
// ⚠️ 适配不完美之处（写明，不要假装等价）：
//   * Platform 契约只承诺「精确 seek」，无 policy 概念 —— 故非 kExact 策略一律拒绝，
//     不静默降级（真需要 kKeyframeBefore/kNearest 时，应先扩展 Platform 接口携带策略）。
//   * Platform ChqIFrameProvider 未暴露帧缓存 / 解码器池注入点 —— SetFrameCache /
//     SetDecoderPool 在此**不生效**。预览若要接 MEDIA-011 缓存，需先扩展 Platform 契约。

#ifndef CQ_CORE_MEDIA_CHQ_PLATFORM_FRAME_PROVIDER_H_
#define CQ_CORE_MEDIA_CHQ_PLATFORM_FRAME_PROVIDER_H_

#include <memory>

#include "cq/base/chq_concurrency.h"
#include "cq/base/chq_status.h"
#include "cq/base/chq_rational_time.h"
#include "cq/media/chq_frame_provider.h"
#include "cq/media/chq_frame_provider_factory.h"
#include "cq/platform/chq_media.h"

namespace cq {

class ChqPlatformFrameProvider final : public ChqFrameProvider {
public:
    explicit ChqPlatformFrameProvider(ChqPlatformPtr<ChqIFrameProvider> platform) : platform_(std::move(platform)) {}

    // Platform 工厂 `CreateFrameProvider` 内部已完成 Open，此处只校验有效性（幂等）。
    ChqStatus Open(const ChqMediaSource& src) override;

    ChqStatus Seek(const ChqRationalTime& target, ChqSeekPolicy policy,
                const ChqCancelToken& token) override;

    ChqStatus AcquireFrame(const ChqFrameRequest& req, ChqMediaFrame& out_frame,
                        const ChqCancelToken& token) override;

    void ReleaseFrame(ChqMediaFrame& frame) override;

    ChqStatus GetDuration(ChqRationalTime& out) const override;

    void SetFrameCache(ChqIFrameCache* cache) override { cache_ = cache; }
    void SetDecoderPool(ChqIDecoderPool* pool) override { pool_ = pool; }

private:
    ChqPlatformPtr<ChqIFrameProvider> platform_;
    ChqIFrameCache* cache_ = nullptr;  // 当前不生效，见文件头说明
    ChqIDecoderPool* pool_ = nullptr;  // 同上
};

// 默认工厂：经 Platform 的 `CreateFrameProvider` 产出 ChqFrameProvider。
// 用途：core 侧（含 C ABI 门面）在**不引用任何平台符号**的前提下拿到取帧能力 ——
// 平台差异全部由 Platform 工厂吸收，这正是 Platform 存在的意义。
class ChqPlatformFrameProviderFactory final : public ChqIFrameProviderFactory {
public:
    ChqStatus Create(const ChqMediaSource& src, std::unique_ptr<ChqFrameProvider>& out) override;
};

}  // namespace cq

#endif  // CQ_CORE_MEDIA_CHQ_PLATFORM_FRAME_PROVIDER_H_
