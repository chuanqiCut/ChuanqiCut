// ChuanqiCut — RenderGraph 执行器实现（RENDER-001 / B0）

#include "cq/render/chq_render_evaluator.h"

#include <chrono>

#include "cq/base/chq_logging.h"
#include "cq/render/chq_fit_viewport.h"

namespace cq {
namespace {

using Clock = std::chrono::steady_clock;

int64_t ElapsedNs(Clock::time_point from) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - from).count();
}

}  // namespace

ChqStatus ChqRenderEvaluator::Prepare(ChqRenderGraph& graph, const Resources& res,
                                      const ChqCancelToken& token, Timings& out_timings) {
    graph_ = &graph;
    res_ = res;
    prepared_sources_ = 0;
    encoded_blits_ = 0;
    last_source_reused_ = false;
    last_encode_ns_ = 0;
    prepared_ = false;
    for (uint32_t i = 0; i < kMaxOutputs; ++i) outputs_[i] = nullptr;

    if (res_.frames == nullptr || res_.assets == nullptr) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    if (graph.NodeCount() > kMaxOutputs) return ChqStatus(ChqStatusCode::kResourceExhausted);

    // 拓扑序：source 之间没有依赖，但按拓扑序遍历是**唯一正确的顺序** ——
    // 将来 filter 节点（输入输出都是纹理）必须等上游产出后才轮到它。
    uint32_t order[kMaxGraphNodes] = {};
    uint32_t order_count = 0;
    ChqStatus s = graph.TopoOrder(order, order_count);
    if (!s.IsOk()) return s;
    if (order_count != graph.NodeCount()) {
        // 有环：Validate 应该已经拦住；能走到这里说明调用方跳过了校验。
        CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "执行器收到含环的图（%u/%u 可排序），拒绝执行",
                       static_cast<unsigned>(order_count), static_cast<unsigned>(graph.NodeCount()));
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }

    const Clock::time_point t0 = Clock::now();
    for (uint32_t k = 0; k < order_count; ++k) {
        const uint32_t index = order[k];
        const ChqRenderNodeDesc* node = graph.Node(index);
        if (node == nullptr) return ChqStatus(ChqStatusCode::kInternal);
        if (node->kind != ChqRenderNodeKind::kSource) continue;

        TextureHandle tex = nullptr;
        uint32_t w = 0;
        uint32_t h = 0;
        bool reused = false;
        uint32_t rotation = 0;
        s = res_.frames->Acquire(node->asset_id, node->source_time, *res_.assets, tex, w, h,
                                 &reused, &rotation, token);
        if (!s.IsOk()) return s;
        if (tex == nullptr) return ChqStatus(ChqStatusCode::kInternal);
        outputs_[index] = tex;
        last_source_reused_ = reused;
        // 回填实际源尺寸与显示旋转角：视口计算与 blit UV 旋转都要用（装配时还不知道帧多大）。
        ChqRenderNodeDesc* mutable_node = graph.MutableNode(index);
        if (mutable_node != nullptr) {
            mutable_node->source_width = w;
            mutable_node->source_height = h;
            mutable_node->source_rotation = static_cast<uint16_t>(rotation);
        }
        ++prepared_sources_;
    }
    out_timings.prepare_ns = ElapsedNs(t0);
    prepared_ = true;
    return ChqStatus::Ok();
}

ChqStatus ChqRenderEvaluator::Encode(ChqIGfxEncoder& encoder, const ChqFrameContext&,
                                     const ChqCancelToken&) {
    if (!prepared_ || graph_ == nullptr) return ChqStatus(ChqStatusCode::kInternal);
    if (res_.blit == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    uint32_t order[kMaxGraphNodes] = {};
    uint32_t order_count = 0;
    ChqStatus s = graph_->TopoOrder(order, order_count);
    if (!s.IsOk()) return s;

    const Clock::time_point t0 = Clock::now();
    // ChqIBlitPass 在 Platform 层，收的是 Platform 的 ChqICommandEncoder
    // （Platform 不能反向依赖 GFX；与既有 BlitClient 同一套路）。
    ChqICommandEncoder* platform_encoder = encoder.PlatformEncoder();
    if (platform_encoder == nullptr) return ChqStatus(ChqStatusCode::kInternal);

    for (uint32_t k = 0; k < order_count; ++k) {
        const uint32_t index = order[k];
        const ChqRenderNodeDesc* node = graph_->Node(index);
        if (node == nullptr) return ChqStatus(ChqStatusCode::kInternal);
        if (node->kind != ChqRenderNodeKind::kBlit) continue;  // sink 无动作；source 已 Prepare

        if (node->input_count != 1) return ChqStatus(ChqStatusCode::kInvalidArgument);
        const ChqRenderNodeDesc* src_node = graph_->Node(node->inputs[0]);
        if (src_node == nullptr) return ChqStatus(ChqStatusCode::kInternal);
        const TextureHandle src = outputs_[node->inputs[0]];
        if (src == nullptr) return ChqStatus(ChqStatusCode::kInternal);

        // #21：显示旋转角 → 视口用「旋转后」的源尺寸。90/270 旋转会交换宽高
        // （landscape 编码帧 → portrait 显示），否则 contain/cover 会把竖屏误判成横屏。
        const uint16_t rot = src_node->source_rotation;
        const bool swap = (rot == 90 || rot == 270);
        const uint32_t eff_w = swap ? src_node->source_height : src_node->source_width;
        const uint32_t eff_h = swap ? src_node->source_width : src_node->source_height;

        // 适配视口：**源尺寸在上游 source 节点上**（Prepare 阶段取到帧后回填到那里，
        // 装配时帧还没取、尺寸未知）。取 blit 节点自己的 source_width 会恒为 0
        // → 视口算成整目标 → contain/cover 静默退化成 stretch（像素断言当场抓出）。
        float vp[4] = {};
        ComputeFitViewport(node->fit_mode, eff_w, eff_h, node->target_width, node->target_height,
                           vp);
        if (!IsFullTargetViewport(vp, node->target_width, node->target_height)) {
            encoder.SetViewport(vp[0], vp[1], vp[2], vp[3]);
        }
        // 旋转角交给 blit：全屏拷贝时在 UV 层旋转还原显示朝向（color-safe 直通，
        // 不动色彩空间；预览/导出共用 → 红线 #9）。
        s = res_.blit->Encode(*platform_encoder, src, rot);
        if (!s.IsOk()) return s;
        ++encoded_blits_;
    }
    // 编码耗时只统计命令录制；提交与 GPU 等待在 GFX 层（RenderFrame 内），
    // 与既有 Timings::draw_ns 的口径保持一致（含 GPU 执行的部分在调用方记）。
    last_encode_ns_ = ElapsedNs(t0);
    return ChqStatus::Ok();
}

}  // namespace cq
