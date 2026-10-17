// ChuanqiCut — RenderGraph 装配器（RENDER-001 / B0）
//
// 职责：把「时间线 + 画布 + 用途」装配成一张 RenderGraph。
//
// 为什么装配器要单独存在（RESEARCH-014 §5 的核心建议，不是多一层包装）：
//   红线 #9 要求预览与导出共用同一张 RenderGraph。如果「装配」散在预览渲染器和
//   （未来的）导出器里各写一份，它们必然随时间漂移 —— 那就是本仓库已经付过代价的
//   「两套渲染路径」（ADR-0014 / ADR-0034）。**同一装配器产出两种用途的图**，
//   才是「共用同一张图」的可执行形式：
//     * kPreview —— 实时时钟，请求即渲染当前 pts，允许漏帧
//     * kExport  —— 步进时钟，逐帧推进，一帧不漏
//     * kAudioOnly —— 只要音频，不装配任何 GPU 节点（B5/导出音轨用）
//   三者调用的是同一段装配代码，差别只在 purpose 与时钟。
//
// B0 的能力边界（如实声明，不要假装支持）：
//   * **单轨**：命中多条视频轨时只取第一条（与引入 RenderGraph 前逐像素一致），
//     并发 Warn（Release 可见）——多轨混合语义归 RENDER-011（B7）。
//   * **无转场 / 无滤镜**：ChqClip 上的 transition 字段存在但渲染不消费（B7）。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常、时间一律 ChqRationalTime。

#ifndef CQ_CORE_RENDER_CHQ_GRAPH_ASSEMBLER_H_
#define CQ_CORE_RENDER_CHQ_GRAPH_ASSEMBLER_H_

#include <cstdint>

#include "cq/base/chq_rational_time.h"
#include "cq/base/chq_status.h"
#include "cq/model/chq_timeline.h"
#include "cq/render/chq_clock_source.h"
#include "cq/render/chq_fit_mode.h"
#include "cq/render/chq_render_graph.h"

namespace cq {

// 图的用途。**同一装配器**按用途产出不同的图（见文件头说明）。
enum class ChqGraphPurpose : int32_t {
    kPreview = 0,    // 预览：实时时钟，允许漏帧
    kExport = 1,     // 导出：步进时钟，逐帧推进
    kAudioOnly = 2,  // 仅音频：不装配 GPU 节点
};

struct ChqAssembleInput {
    const ChqTimeline* timeline = nullptr;
    const ChqIClockSource* clock = nullptr;  // 可空：空 = 用 in.pts（预览现状）
    ChqRationalTime pts{0, 1};               // clock 为空时的请求时刻
    ChqFitMode fit_mode = ChqFitMode::kStretch;
    uint32_t target_width = 0;  // 画布像素尺寸（0 = 用 timeline 的画布尺寸）
    uint32_t target_height = 0;
    ChqGraphPurpose purpose = ChqGraphPurpose::kPreview;
};

struct ChqAssembleResult {
    // 本帧实际渲染的片段（0 = 空隙帧）；空隙帧不产出 source/blit 节点，
    // 由调用方清屏（返回 kIoNotFound，与既有语义一致）。
    uint64_t hit_clip_id = 0;
    uint64_t hit_asset_id = 0;
    ChqRationalTime source_time{0, 1};
    // 命中了多条视频轨但只渲染了第一条（B0 的诚实边界，非静默）。
    bool multi_track_ignored = false;
    // 命中的片段带转场 / 非拉伸适配之外的效果：本帧渲染未消费（B7 前一律如此）。
    bool effects_dropped = false;
};

class ChqGraphAssembler {
public:
    ChqStatus Assemble(const ChqAssembleInput& in, ChqRenderGraph& out_graph,
                       ChqAssembleResult& out_result);

    // 上一次装配的指纹（图结构 + 影响结构的输入）。调用方可据此跳过重复装配：
    // 60Hz 预览下"命中片段没变"是常态，省掉每帧重建节点是实打实的开销。
    uint64_t LastFingerprint() const { return last_fingerprint_; }

    // 装配计数（诊断用：与渲染帧数对照可看出装配缓存命中率）。
    uint64_t AssembleCount() const { return assemble_count_; }

private:
    uint64_t last_fingerprint_ = 0;
    uint64_t assemble_count_ = 0;
};

}  // namespace cq

#endif  // CQ_CORE_RENDER_CHQ_GRAPH_ASSEMBLER_H_
