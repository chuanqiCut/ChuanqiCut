// ChuanqiCut — PAL 帧提供器适配器（BIND-003 子步骤 5）
//
// 作用：把 PAL 的 `IFrameProvider`（pal/media.h，平台能力）包成 core 的
// `FrameProvider`（cq/media/frame_provider.h，编辑侧编排抽象），
// 使 core 的预览渲染器、以及 core 侧的 C ABI 门面，都能经 PAL 工厂拿到取帧能力，
// 而**不需要** core 反向依赖任何平台实现。
//
// 为什么要这一层：
//   PAL 的 IFrameProvider 是「平台后端」（demux + 解码 + 精确 seek 的平台实现）；
//   core 的 FrameProvider 是「编辑侧抽象」（带 SeekPolicy、帧缓存、解码器池编排）。
//   两者语义重叠但层次不同。PAL 侧的实现内部仍然用 MEDIA-020 SystemFrameProvider
//   做编排（见 pal/apple/frame_provider_apple.mm），故这里只是**形状适配**，
//   不引入第二套取帧逻辑。
//
// ⚠️ 适配不完美之处（写明，不要假装等价）：
//   * PAL 契约只承诺「精确 seek」，无 policy 概念 —— 故非 kExact 策略一律拒绝，
//     不静默降级（真需要 kKeyframeBefore/kNearest 时，应先扩展 PAL 接口携带策略）。
//   * PAL IFrameProvider 未暴露帧缓存 / 解码器池注入点 —— SetFrameCache /
//     SetDecoderPool 在此**不生效**。预览若要接 MEDIA-011 缓存，需先扩展 PAL 契约。

#ifndef CQ_MEDIA_PAL_FRAME_PROVIDER_H_
#define CQ_MEDIA_PAL_FRAME_PROVIDER_H_

#include <memory>

#include "cq/base/concurrency.h"
#include "cq/base/status.h"
#include "cq/base/rational_time.h"
#include "cq/media/frame_provider.h"
#include "cq/media/frame_provider_factory.h"
#include "cq/pal/media.h"

namespace cq {

class PalFrameProvider final : public FrameProvider {
public:
    explicit PalFrameProvider(PalPtr<IFrameProvider> pal) : pal_(std::move(pal)) {}

    // PAL 工厂 `CreateFrameProvider` 内部已完成 Open，此处只校验有效性（幂等）。
    Status Open(const MediaSource& src) override;

    Status Seek(const RationalTime& target, SeekPolicy policy,
                const CancelToken& token) override;

    Status AcquireFrame(const FrameRequest& req, MediaFrame& out_frame,
                        const CancelToken& token) override;

    void ReleaseFrame(MediaFrame& frame) override;

    Status GetDuration(RationalTime& out) const override;

    void SetFrameCache(IFrameCache* cache) override { cache_ = cache; }
    void SetDecoderPool(IDecoderPool* pool) override { pool_ = pool; }

private:
    PalPtr<IFrameProvider> pal_;
    IFrameCache* cache_ = nullptr;  // 当前不生效，见文件头说明
    IDecoderPool* pool_ = nullptr;  // 同上
};

// 默认工厂：经 PAL 的 `CreateFrameProvider` 产出 FrameProvider。
// 用途：core 侧（含 C ABI 门面）在**不引用任何平台符号**的前提下拿到取帧能力 ——
// 平台差异全部由 PAL 工厂吸收，这正是 PAL 存在的意义。
class PalFrameProviderFactory final : public IFrameProviderFactory {
public:
    Status Create(const MediaSource& src, std::unique_ptr<FrameProvider>& out) override;
};

}  // namespace cq

#endif  // CQ_MEDIA_PAL_FRAME_PROVIDER_H_
