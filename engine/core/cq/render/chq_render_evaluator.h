// ChuanqiCut — RenderGraph 执行器（RENDER-001 / B0）
//
// 职责：把一张装配好的图**执行**成一帧。分两个阶段，这个划分不是随意的：
//
//   Prepare（CPU 侧，在 RenderFrame 之前）
//     kSource 节点：取帧 + 导入 → 纹理。它可能耗时毫秒级（seek + 解码），
//     **绝不能**塞进 GPU 编码回调里 —— 编码器持有的是命令缓冲，在里面做同步 I/O
//     会让 GPU 空转，也会让"取帧耗时"和"GPU 耗时"混成一个数（现有 Timings 分段
//     就是为了不让它们混，见 chq_preview_renderer.h 的阶段说明）。
//
//   Encode（GPU 侧，作为 ChqIFrameEncoderClient 被 ChqIGfxDevice::RenderFrame 回调）
//     kBlit 节点：按拓扑序把输入纹理画进目标（含适配视口）。
//
// 本类**不持有**任何 GPU/解码资源（全部由 Resources 注入，非拥有指针）——
// 图可以每帧重建，资源不能每帧重建。
//
// 硬约束：零平台类型（只用 opaque 句柄 + GFX/Platform 接口）、禁用异常。

#ifndef CQ_CORE_RENDER_CHQ_RENDER_EVALUATOR_H_
#define CQ_CORE_RENDER_CHQ_RENDER_EVALUATOR_H_

#include <cstdint>

#include "cq/base/chq_concurrency.h"
#include "cq/base/chq_status.h"
#include "cq/gfx/chq_gfx_device.h"  // ChqIGfxEncoder / ChqIFrameEncoderClient / ChqFrameContext
#include "cq/media/chq_asset_registry.h"
#include "cq/platform/chq_common.h"
#include "cq/platform/chq_gfx.h"  // ChqIBlitPass
#include "cq/render/chq_frame_source.h"
#include "cq/render/chq_render_graph.h"

namespace cq {

class ChqRenderEvaluator final : public ChqIFrameEncoderClient {
public:
    // 注入资源（全部非拥有，生命周期归调用方）。
    struct Resources {
        ChqIBlitPass* blit = nullptr;              // Platform 绘制 pass（全屏拷贝 + 变换层，同一对象）
        ChqIFrameSource* frames = nullptr;         // 取帧接缝
        const ChqAssetRegistry* assets = nullptr;  // 当前帧素材表（转发给取帧接缝）
    };

    // 执行阶段的耗时分段（ns）。与 ChqPreviewRenderer::Timings 是同一套语义：
    // 拆开记是因为「慢在取帧还是慢在 GPU」决定了完全不同的优化动作。
    struct Timings {
        int64_t prepare_ns = 0;  // CPU：source 取帧 + 导入
        int64_t encode_ns = 0;   // GPU pass 编码（不含提交与等待，那在 GFX 层）
    };

    // 每个节点的产出纹理（Prepare 阶段填充，Encode 阶段消费）。
    static constexpr uint32_t kMaxOutputs = kMaxGraphNodes;

    // ⚠️ 图**非 const**：Prepare 会把取到的实际源尺寸回填进 source 节点（视口计算要用，
    //    装配时尚未取帧、尺寸未知）。这是图里唯一的运行期可变字段。
    ChqStatus Prepare(ChqRenderGraph& graph, const Resources& res, const ChqCancelToken& token,
                      Timings& out_timings);

    // ChqIFrameEncoderClient：GPU 编码阶段。必须在 Prepare 之后调用。
    ChqStatus Encode(ChqIGfxEncoder& encoder, const ChqFrameContext& ctx,
                     const ChqCancelToken& token) override;

    // 上一帧的执行观测（诊断与单测用，不是渲染结果本身）。
    uint32_t PreparedSources() const { return prepared_sources_; }
    uint32_t EncodedBlits() const { return encoded_blits_; }
    // RENDER-010：时间线路径的绘制节点（与 EncodedBlits 分开记，
    // 混成一个数就看不出"这帧走的是老 blit 还是变换层"）。
    uint32_t EncodedTransforms() const { return encoded_transforms_; }
    bool LastSourceReused() const { return last_source_reused_; }
    // 上一帧 GPU 命令录制耗时（ns）。**不含**提交与 GPU 等待 —— 那部分在 GFX 层
    // （ChqIGfxDevice::RenderFrame 结尾是 WaitUntilCompleted），由调用方计入 draw_ns。
    int64_t LastEncodeNs() const { return last_encode_ns_; }

private:
    const ChqRenderGraph* graph_ = nullptr;
    Resources res_{};
    TextureHandle outputs_[kMaxOutputs] = {};  // 节点索引 → 产出纹理（仅 kSource 有）
    uint32_t prepared_sources_ = 0;
    uint32_t encoded_blits_ = 0;
    uint32_t encoded_transforms_ = 0;
    bool last_source_reused_ = false;
    int64_t last_encode_ns_ = 0;
    bool prepared_ = false;
};

}  // namespace cq

#endif  // CQ_CORE_RENDER_CHQ_RENDER_EVALUATOR_H_
