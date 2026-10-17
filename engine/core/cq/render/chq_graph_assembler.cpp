// ChuanqiCut — RenderGraph 装配器实现（RENDER-001 / B0）

#include "cq/render/chq_graph_assembler.h"

#include "cq/base/chq_logging.h"
#include "cq/render/chq_fit_viewport.h"

namespace cq {
namespace {

constexpr uint64_t kFnvOffset = 14695981039346656037ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

inline void FnvUpdate(uint64_t& h, uint64_t v) {
    for (int i = 0; i < 8; ++i) {
        h ^= (v >> (i * 8)) & 0xff;
        h *= kFnvPrime;
    }
}

// 结构指纹：**只覆盖影响图结构的输入**（命中片段 / 素材内时间 / 画布 / 适配模式 / 用途）。
// 不把 pts 本身算进去 —— 同片段内每帧的 pts 都不同，算进去等于缓存永不命中。
uint64_t InputFingerprint(const ChqAssembleInput& in, const ChqAssembleResult& r) {
    uint64_t h = kFnvOffset;
    FnvUpdate(h, r.hit_clip_id);
    FnvUpdate(h, r.hit_asset_id);
    FnvUpdate(h, static_cast<uint64_t>(r.source_time.value));
    FnvUpdate(h, static_cast<uint64_t>(r.source_time.timescale));
    FnvUpdate(h, static_cast<uint64_t>(in.fit_mode));
    FnvUpdate(h, in.target_width);
    FnvUpdate(h, in.target_height);
    FnvUpdate(h, static_cast<uint64_t>(in.purpose));
    return h;
}

}  // namespace

ChqStatus ChqGraphAssembler::Assemble(const ChqAssembleInput& in, ChqRenderGraph& out_graph,
                                      ChqAssembleResult& out_result) {
    out_graph.Clear();
    out_result = ChqAssembleResult{};

    if (in.timeline == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    // 画布尺寸：未显式指定时用时间线的画布（UIA-040 起画布是项目属性）。
    uint32_t tw = in.target_width;
    uint32_t th = in.target_height;
    if (tw == 0 || th == 0) {
        tw = static_cast<uint32_t>(in.timeline->CanvasWidth());
        th = static_cast<uint32_t>(in.timeline->CanvasHeight());
    }
    if (tw == 0 || th == 0) return ChqStatus(ChqStatusCode::kInvalidArgument);

    // 时刻：步进/实时时钟优先，否则用请求的 pts。
    ChqRationalTime pts = in.pts;
    if (in.clock != nullptr) {
        ChqStatus s = in.clock->Now(pts);
        if (!s.IsOk()) return s;
    }

    // ---- 1. 定位命中的视频轨片段 ----
    // 与引入 RenderGraph 前逐该厂商一致的语义：**第一条命中的视频轨**。
    // 多轨混合语义（alpha/转场）归 RENDER-011（B7），在此之前命中多轨只能取一条 ——
    // 关键是要**说出来**（Warn，Release 可见），不能像以前那样只有一句代码注释。
    const ChqClip* clip = nullptr;
    const ChqTrack* hit_track = nullptr;  // 片段空间参数的父级（轨级变换）
    int hit_track_count = 0;
    for (const ChqTrack& track : in.timeline->Tracks()) {
        if (track.kind != ChqTrackKind::kVideo || !track.enabled) continue;
        const ChqClip* hit = in.timeline->FindClipAt(track.id, pts);
        if (hit == nullptr) continue;
        ++hit_track_count;
        if (clip == nullptr) {
            clip = hit;  // 只保留第一条（保持既有像素行为）
            hit_track = &track;
        }
    }
    out_result.multi_track_ignored = (hit_track_count > 1);
    if (out_result.multi_track_ignored) {
        CQ_LOG_WARN_WF(ChqWorkflow::kGfx,
                       "多轨命中 %d 条但 B0 只渲染第一条（多轨合成归 RENDER-011）", hit_track_count);
    }

    // 空隙帧：不产出节点，由调用方清屏（kIoNotFound 语义不变）。
    if (clip == nullptr) {
        out_result = ChqAssembleResult{};
        last_fingerprint_ = InputFingerprint(in, out_result);
        ++assemble_count_;
        return ChqStatus(ChqStatusCode::kIoNotFound);
    }

    // ---- 2. 素材内时间 = source_in + (pts - clip->start) ----
    // MODEL-001 无变速字段，故时间线时长与素材时长 1:1（retime 落地后此处需改）。
    ChqRationalTime offset{0, 1};
    if (!SubRational(pts, clip->start, offset).IsOk()) {
        return ChqStatus(ChqStatusCode::kOverflow);
    }
    ChqRationalTime src_time{0, 1};
    if (!AddRational(clip->source.source_in, offset, src_time).IsOk()) {
        return ChqStatus(ChqStatusCode::kOverflow);
    }

    out_result.hit_clip_id = clip->id;
    out_result.hit_asset_id = clip->source.asset_id;
    out_result.source_time = src_time;
    // 诚实上报「本批渲染吃不下的东西」：转场（RENDER-011）与效果栈（同卡）。
    // 效果只算**启用**的 —— 禁用效果不影响像素，"丢弃"它是无信息的噪声。
    // B0 之后效果仍不改变预览/导出像素（与引入 RenderGraph 前一致），
    // 但这个标志必须为真：否则 UI 会显示一个"加了却没效果"的静默失败。
    bool has_enabled_effect = false;
    for (const ChqEffectBinding& e : clip->effects.Effects()) {
        if (e.enabled) {
            has_enabled_effect = true;
            break;
        }
    }
    out_result.effects_dropped =
        (clip->in_transition != ChqTransitionKind::kNone) ||
        (clip->out_transition != ChqTransitionKind::kNone) || has_enabled_effect;
    if (has_enabled_effect) {
        CQ_LOG_WARN_WF(ChqWorkflow::kGfx,
                       "片段 %llu 带启用效果但 B0 渲染未消费（效果应用归 RENDER-011）",
                       static_cast<unsigned long long>(clip->id));
    } else if (out_result.effects_dropped) {
        CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "片段 %llu 带转场但 B0 渲染未消费（归 RENDER-011）",
                       static_cast<unsigned long long>(clip->id));
    }

    // MODEL-004 的关键帧通道本批**不插值**（求值引擎归 B8 anim）：带关键帧的片段
    // 只会用静态 transform 画，动画不动。这必须说出来，不能让用户以为"加了没生效"是 bug。
    if (!clip->keyframes.Empty()) {
        CQ_LOG_WARN_WF(ChqWorkflow::kGfx,
                       "片段 %llu 有 %zu 个关键帧但变换按静态值取（关键帧求值归 B8）",
                       static_cast<unsigned long long>(clip->id), clip->keyframes.Size());
    }

    // 仅音频用途：不装配任何 GPU 节点（导出音轨 / 音频预览走这条路）。
    if (in.purpose == ChqGraphPurpose::kAudioOnly) {
        last_fingerprint_ = InputFingerprint(in, out_result);
        ++assemble_count_;
        return ChqStatus::Ok();
    }

    // ---- 3. 装配节点：source → blit → sink ----
    uint32_t src_index = 0;
    {
        ChqRenderNodeDesc n;
        n.kind = ChqRenderNodeKind::kSource;
        n.asset_id = clip->source.asset_id;
        n.clip_id = clip->id;
        n.source_time = src_time;
        ChqStatus s = out_graph.AddNode(n, src_index);
        if (!s.IsOk()) return s;
    }
    uint32_t draw_index = 0;
    {
        // RENDER-010：时间线路径改走 kTransform（**不是**"非恒等才走"）。
        // 理由：分两条路就是两套渲染逻辑（ADR-0034 的老坑），而且恒等档必须被现有
        // 像素断言覆盖到，否则"变换没改写 blit"这句话永远只能靠眼睛验。
        // 几何不在这里算，装配只搬运模型里的两份 ChqTransform。
        ChqRenderNodeDesc n;
        n.kind = ChqRenderNodeKind::kTransform;
        n.fit_mode = in.fit_mode;
        n.target_width = tw;
        n.target_height = th;
        n.clip_transform = clip->transform;
        n.track_transform = hit_track != nullptr ? hit_track->transform : ChqTransform();
        ChqStatus s = out_graph.AddNode(n, draw_index);
        if (!s.IsOk()) return s;
        s = out_graph.Connect(src_index, draw_index);
        if (!s.IsOk()) return s;
    }
    {
        ChqRenderNodeDesc n;
        n.kind = ChqRenderNodeKind::kSink;
        n.target_width = tw;
        n.target_height = th;
        uint32_t sink_index = 0;
        ChqStatus s = out_graph.AddNode(n, sink_index);
        if (!s.IsOk()) return s;
        s = out_graph.Connect(draw_index, sink_index);
        if (!s.IsOk()) return s;
    }

    ChqStatus s = out_graph.Validate();
    if (!s.IsOk()) return s;

    last_fingerprint_ = out_graph.Fingerprint();
    ++assemble_count_;
    return ChqStatus::Ok();
}

}  // namespace cq
