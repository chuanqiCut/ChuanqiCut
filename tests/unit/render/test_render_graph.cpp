// ChuanqiCut — RenderGraph 单测（RENDER-001 / B0）
//
// 为什么**不**走真 Metal（与 test_preview_renderer.cpp 不同）：
//   图的结构性质（拓扑序、环检测、校验规则、装配结果、视口决策）是**纯逻辑**，
//   用假 frame source + 假 encoder 就能确定性断言，还能覆盖真机上根本跑不到的分支
//   （有环的图、两个 sink、未 Prepare 就 Encode）。
//   真机/真 GPU 的像素一致性由 test_preview_renderer.cpp 守（它跑完整链路）。
//
// 覆盖：
//   A. 图结构：空图 / 正常三节点 / 重复边去重 / 无 sink / 双 sink / blit 无输入 / 有环
//   B. 指纹：同结构同指纹，改任一结构字段则变
//   C. 装配器：单轨命中（source_time 正确）/ 空隙 / 纯音频 / 多轨命中（Warn 且只取一条）
//   D. 执行器：Prepare 取帧次数、Encode 的 blit 次数与**视口决策**（stretch 不设视口）
//   E. 时钟源：步进时钟的三帧时刻与耗尽；实时时钟 Advance 语义不匹配

#include <cstdint>
#include <cstdio>

#include "cq/base/chq_rational_time.h"
#include "cq/base/chq_status.h"
#include "cq/gfx/chq_gfx_device.h"
#include "cq/model/chq_timeline.h"
#include "cq/platform/chq_gfx.h"
#include "cq/render/chq_clock_source.h"
#include "cq/render/chq_graph_assembler.h"
#include "cq/render/chq_render_evaluator.h"
#include "cq/render/chq_render_graph.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (cond) {
        std::printf("  ok  : %s\n", msg);
    } else {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

// ---- 假的取帧接缝：不解码，返回"纹理"哨兵 ----
class FakeFrameSource final : public cq::ChqIFrameSource {
public:
    cq::ChqStatus Acquire(uint64_t asset_id, const cq::ChqRationalTime& src_time,
                          const cq::ChqAssetRegistry&, cq::TextureHandle& out_tex, uint32_t& out_w,
                          uint32_t& out_h, bool* out_reused, uint32_t* out_rotation,
                          const cq::ChqCancelToken&) override {
        ++calls;
        last_asset = asset_id;
        last_src_time = src_time;
        out_tex = reinterpret_cast<cq::TextureHandle>(this);  // 哨兵：只要非 null
        out_w = src_width;
        out_h = src_height;
        if (out_reused != nullptr) *out_reused = false;
        if (out_rotation != nullptr) *out_rotation = src_rotation;
        return cq::ChqStatus::Ok();
    }
    int calls = 0;
    uint64_t last_asset = 0;
    cq::ChqRationalTime last_src_time{0, 1};
    uint32_t src_width = 1920;
    uint32_t src_height = 1080;
    uint16_t src_rotation = 0;  // #21：可配置源帧旋转角（默认 0，横屏）
};

// ---- 假的 Platform 编码器（blit pass 需要它）----
class FakeCommandEncoder final : public cq::ChqICommandEncoder {
public:
    void SetViewport(float x, float y, float w, float h) override {
        has_viewport = true;
        vp[0] = x;
        vp[1] = y;
        vp[2] = w;
        vp[3] = h;
    }
    void Destroy() override {}
    // 其余接口本用例不涉及
    cq::ChqStatus BeginRenderPass(cq::RenderTargetHandle, const float[4]) override {
        return cq::ChqStatus::Ok();
    }
    void SetPipeline(cq::PipelineHandle) override {}
    void SetVertexBuffer(cq::BufferHandle, uint32_t) override {}
    void SetTexture(cq::TextureHandle, uint32_t) override {}
    void SetSampler(cq::SamplerHandle, uint32_t) override {}
    void Draw(uint32_t) override {}
    void DrawIndexed(uint32_t) override {}
    void End() override {}

    bool has_viewport = false;
    float vp[4] = {};
};

// ---- 假的 GFX 编码器（执行器只用它设视口 + 取 Platform 编码器）----
class FakeGfxEncoder final : public cq::ChqIGfxEncoder {
public:
    explicit FakeGfxEncoder(FakeCommandEncoder* platform) : platform_(platform) {}
    void SetViewport(float x, float y, float w, float h) override {
        ++viewport_calls;
        platform_->SetViewport(x, y, w, h);
    }
    cq::ChqICommandEncoder* PlatformEncoder() override { return platform_; }
    void Destroy() override {}
    void SetPipeline(cq::PipelineHandle) override {}
    void SetVertexBuffer(cq::BufferHandle, uint32_t) override {}
    void SetTexture(cq::TextureHandle, uint32_t) override {}
    void SetSampler(cq::SamplerHandle, uint32_t) override {}
    void Draw(uint32_t) override {}
    void DrawIndexed(uint32_t) override {}
    void End() override {}

    int viewport_calls = 0;

private:
    FakeCommandEncoder* platform_;
};

// ---- 假的 blit pass：只记录调用次数 ----
class FakeBlitPass final : public cq::ChqIBlitPass {
public:
    cq::ChqStatus Encode(cq::ChqICommandEncoder&, cq::TextureHandle tex,
                         uint32_t rotation_deg) override {
        ++calls;
        last_tex = tex;
        last_rotation = rotation_deg;
        return fail_next ? cq::ChqStatus(cq::ChqStatusCode::kInternal) : cq::ChqStatus::Ok();
    }
    // RENDER-010：变换层。整份顶点抄下来，供执行器分支断言传进来的就是烘焙好的那份。
    cq::ChqStatus EncodeLayer(cq::ChqICommandEncoder&, cq::TextureHandle tex,
                              const float* vertices, uint32_t vertex_count) override {
        ++layer_calls;
        last_tex = tex;
        last_layer_count = vertex_count;
        const uint32_t n = vertex_count < kMaxRecordedVerts ? vertex_count : kMaxRecordedVerts;
        for (uint32_t i = 0; i < n * 5; ++i) last_layer_verts[i] = vertices[i];
        return fail_next ? cq::ChqStatus(cq::ChqStatusCode::kInternal) : cq::ChqStatus::Ok();
    }
    void Destroy() override {}
    static constexpr uint32_t kMaxRecordedVerts = 6;
    int calls = 0;
    int layer_calls = 0;
    cq::TextureHandle last_tex = nullptr;
    uint32_t last_rotation = 0;  // #21：记录传给 blit 的旋转角
    uint32_t last_layer_count = 0;
    float last_layer_verts[kMaxRecordedVerts * 5] = {};
    bool fail_next = false;
};

// 变换层顶点里 pos 的包围盒（RENDER-010：适配矩形现在烤进顶点，不再靠视口）。
// 顶点顺序由 core 烘焙，测试只关心覆盖了哪块画面，故取 min/max 而非逐顶点比对。
void LayerPosBounds(const float* v, uint32_t count, float out[4]) {
    float minx = v[0], maxx = v[0], miny = v[1], maxy = v[1];
    for (uint32_t i = 1; i < count; ++i) {
        const float x = v[i * 5 + 0];
        const float y = v[i * 5 + 1];
        if (x < minx) minx = x;
        if (x > maxx) maxx = x;
        if (y < miny) miny = y;
        if (y > maxy) maxy = y;
    }
    out[0] = minx;
    out[1] = maxx;
    out[2] = miny;
    out[3] = maxy;
}

// ---- 实时时钟（预览语义）：Advance 必须拒绝 ----
class RealtimeClock final : public cq::ChqIClockSource {
public:
    cq::ChqClockKind Kind() const override { return cq::ChqClockKind::kRealtime; }
    cq::ChqStatus Now(cq::ChqRationalTime& out) const override {
        out = now;
        return cq::ChqStatus::Ok();
    }
    cq::ChqStatus Advance() override { return cq::ChqStatus(cq::ChqStatusCode::kInvalidArgument); }
    bool Exhausted() const override { return false; }
    uint64_t FrameIndex() const override { return 0; }
    cq::ChqRationalTime now{0, 1};
};

// 造一条单视频轨 + 一个片段的时间线
bool MakeTimeline(cq::ChqTimeline& tl, uint64_t& out_track_id, uint64_t& out_clip_id,
                  uint64_t asset_id, const cq::ChqRationalTime& start,
                  const cq::ChqRationalTime& duration) {
    if (!tl.AddTrack(cq::ChqTrackKind::kVideo, out_track_id).IsOk()) return false;
    cq::ChqClip clip;
    clip.kind = cq::ChqClipKind::kVideo;
    clip.source.asset_id = asset_id;
    clip.source.source_in = cq::ChqRationalTime{0, 120000};
    clip.source.source_duration = duration;
    clip.start = start;
    clip.duration = duration;
    return tl.InsertClip(out_track_id, clip, out_clip_id).IsOk();
}

}  // namespace

int main() {
    std::printf("== RenderGraph 单测（RENDER-001 / B0）==\n");

    // ---------- A. 图结构 ----------
    std::printf("\n[A] 图结构与校验\n");
    {
        cq::ChqRenderGraph g;
        Check(!g.Validate().IsOk(), "空图 Validate 失败（连 sink 都没有）");
    }
    {
        cq::ChqRenderGraph g;
        uint32_t s = 0, b = 0, k = 0;
        cq::ChqRenderNodeDesc n;
        n.kind = cq::ChqRenderNodeKind::kSource;
        g.AddNode(n, s);
        n.kind = cq::ChqRenderNodeKind::kBlit;
        g.AddNode(n, b);
        n.kind = cq::ChqRenderNodeKind::kSink;
        g.AddNode(n, k);
        g.Connect(s, b);
        g.Connect(b, k);
        Check(g.Validate().IsOk(), "source → blit → sink 校验通过");

        uint32_t order[cq::kMaxGraphNodes] = {};
        uint32_t count = 0;
        Check(g.TopoOrder(order, count).IsOk() && count == 3, "拓扑序排出 3 个节点");
        Check(count == 3 && order[0] == s && order[1] == b && order[2] == k,
              "拓扑序 = source, blit, sink（依赖顺序正确）");

        // 重复边去重：入度不能翻倍
        g.Connect(s, b);
        const cq::ChqRenderNodeDesc* bn = g.Node(b);
        Check(bn != nullptr && bn->input_count == 1, "重复 Connect 去重（input_count 仍为 1）");
        Check(g.Validate().IsOk(), "重复边后仍校验通过（不会假报有环）");
    }
    {
        cq::ChqRenderGraph g;  // 无 sink
        uint32_t s = 0, b = 0;
        cq::ChqRenderNodeDesc n;
        n.kind = cq::ChqRenderNodeKind::kSource;
        g.AddNode(n, s);
        n.kind = cq::ChqRenderNodeKind::kBlit;
        g.AddNode(n, b);
        g.Connect(s, b);
        Check(!g.Validate().IsOk(), "无 sink 校验失败");
    }
    {
        cq::ChqRenderGraph g;  // 两个 sink
        uint32_t a = 0, b = 0;
        cq::ChqRenderNodeDesc n;
        n.kind = cq::ChqRenderNodeKind::kSource;
        g.AddNode(n, a);
        n.kind = cq::ChqRenderNodeKind::kSink;
        g.AddNode(n, b);
        g.AddNode(n, b);
        Check(!g.Validate().IsOk(), "两个 sink 校验失败");
    }
    {
        cq::ChqRenderGraph g;  // blit 无输入
        uint32_t b = 0, k = 0;
        cq::ChqRenderNodeDesc n;
        n.kind = cq::ChqRenderNodeKind::kBlit;
        g.AddNode(n, b);
        n.kind = cq::ChqRenderNodeKind::kSink;
        g.AddNode(n, k);
        g.Connect(b, k);
        Check(!g.Validate().IsOk(), "blit 无输入校验失败");
    }
    {
        // 有环：两个 blit 互为输入（source 不允许有输入，故用 blit 构造）
        cq::ChqRenderGraph g;
        uint32_t a = 0, b = 0, k = 0;
        cq::ChqRenderNodeDesc n;
        n.kind = cq::ChqRenderNodeKind::kBlit;
        g.AddNode(n, a);
        g.AddNode(n, b);
        g.Connect(a, b);
        g.Connect(b, a);  // 环
        n.kind = cq::ChqRenderNodeKind::kSink;
        g.AddNode(n, k);
        g.Connect(b, k);
        Check(!g.Validate().IsOk(), "有环的图校验失败（不会死循环）");
    }

    // ---------- B. 指纹 ----------
    std::printf("\n[B] 结构指纹\n");
    {
        auto build = [](cq::ChqFitMode mode) {
            cq::ChqRenderGraph g;
            uint32_t s = 0, b = 0, k = 0;
            cq::ChqRenderNodeDesc n;
            n.kind = cq::ChqRenderNodeKind::kSource;
            n.asset_id = 7;
            g.AddNode(n, s);
            n = cq::ChqRenderNodeDesc{};
            n.kind = cq::ChqRenderNodeKind::kBlit;
            n.fit_mode = mode;
            n.target_width = 1080;
            n.target_height = 1920;
            g.AddNode(n, b);
            n = cq::ChqRenderNodeDesc{};
            n.kind = cq::ChqRenderNodeKind::kSink;
            g.AddNode(n, k);
            g.Connect(s, b);
            g.Connect(b, k);
            return g;
        };
        const uint64_t f1 = build(cq::ChqFitMode::kStretch).Fingerprint();
        const uint64_t f2 = build(cq::ChqFitMode::kStretch).Fingerprint();
        const uint64_t f3 = build(cq::ChqFitMode::kContain).Fingerprint();
        Check(f1 == f2, "同结构 → 同指纹（装配缓存可命中）");
        Check(f1 != f3, "改 fit_mode → 指纹变化（缓存不会误命中）");
    }

    // ---------- C. 装配器 ----------
    std::printf("\n[C] 装配器（三图同源）\n");
    {
        cq::ChqTimeline tl;
        uint64_t tid = 0, cid = 0;
        const cq::ChqRationalTime start{120000, 120000};  // 1.0s
        const cq::ChqRationalTime dur{600000, 120000};    // 5.0s
        Check(MakeTimeline(tl, tid, cid, 42, start, dur), "造时间线：一条视频轨 + 一个片段");

        cq::ChqGraphAssembler asm0;
        cq::ChqRenderGraph g;
        cq::ChqAssembleResult r;
        cq::ChqAssembleInput in;
        in.timeline = &tl;
        in.pts = cq::ChqRationalTime{360000, 120000};  // 3.0s → 素材内 2.0s
        in.fit_mode = cq::ChqFitMode::kStretch;
        in.target_width = 1080;
        in.target_height = 1920;
        in.purpose = cq::ChqGraphPurpose::kPreview;
        const cq::ChqStatus s = asm0.Assemble(in, g, r);
        Check(s.IsOk(), "单轨命中：装配成功");
        Check(g.NodeCount() == 3, "装配出 3 个节点（source/绘制/sink）");
        Check(r.hit_clip_id == cid && r.hit_asset_id == 42, "命中片段与素材 id 正确");
        // source_time = source_in(0) + (pts 3.0s - start 1.0s) = 2.0s
        Check(cq::CompareRational(r.source_time, cq::ChqRationalTime{240000, 120000}) == 0,
              "素材内时间 = 2.0s（source_in + (pts - start)）");
        Check(!r.multi_track_ignored, "单轨：未标记多轨忽略");
        // RENDER-010：时间线路径的绘制节点一律是 kTransform（恒等也不例外，
        // 分两条路就是两套渲染逻辑 —— ADR-0034）。
        const cq::ChqRenderNodeDesc* draw = nullptr;
        for (uint32_t i = 0; i < g.NodeCount(); ++i) {
            const cq::ChqRenderNodeDesc* n = g.Node(i);
            if (n != nullptr && n->kind == cq::ChqRenderNodeKind::kTransform) draw = n;
        }
        Check(draw != nullptr, "绘制节点是 kTransform");
        Check(draw != nullptr && draw->input_count == 1, "kTransform 恰好一个输入");
        Check(draw != nullptr && draw->clip_transform.IsIdentity() &&
                  draw->track_transform.IsIdentity(),
              "未设变换：两份 transform 都是恒等（像素判据的前提）");
        const uint64_t fp_identity = g.Fingerprint();
        cq::ChqTransform moved;
        moved.translate_x = 0.1f;
        Check(tl.SetClipTransform(cid, moved).IsOk(), "给片段设一个位移（画中画）");
        Check(asm0.Assemble(in, g, r).IsOk(), "重新装配（位移变换）");
        Check(g.Fingerprint() != fp_identity, "位移 → 指纹变化（缓存不会端着旧图不放）");
        const cq::ChqRenderNodeDesc* draw2 = nullptr;
        for (uint32_t i = 0; i < g.NodeCount(); ++i) {
            const cq::ChqRenderNodeDesc* n = g.Node(i);
            if (n != nullptr && n->kind == cq::ChqRenderNodeKind::kTransform) draw2 = n;
        }
        Check(draw2 != nullptr && draw2->clip_transform.translate_x == 0.1f,
              "位移写进绘制节点，供执行器烘焙");
    }
    {
        cq::ChqTimeline tl;
        uint64_t tid = 0, cid = 0;
        Check(MakeTimeline(tl, tid, cid, 42, cq::ChqRationalTime{120000, 120000},
                           cq::ChqRationalTime{600000, 120000}),
              "造时间线（空隙用）");
        cq::ChqGraphAssembler asm0;
        cq::ChqRenderGraph g;
        cq::ChqAssembleResult r;
        cq::ChqAssembleInput in;
        in.timeline = &tl;
        in.pts = cq::ChqRationalTime{0, 120000};  // 0s，片段从 1.0s 才开始
        in.target_width = 1080;
        in.target_height = 1920;
        const cq::ChqStatus s = asm0.Assemble(in, g, r);
        Check(s.code == cq::ChqStatusCode::kIoNotFound, "空隙帧：返回 kIoNotFound（不伪造成功）");
        Check(g.NodeCount() == 0, "空隙帧：不产出节点（由调用方清屏）");
    }
    {
        cq::ChqTimeline tl;
        uint64_t tid = 0, cid = 0;
        Check(MakeTimeline(tl, tid, cid, 42, cq::ChqRationalTime{0, 120000},
                           cq::ChqRationalTime{600000, 120000}),
              "造时间线（纯音频用）");
        cq::ChqGraphAssembler asm0;
        cq::ChqRenderGraph g;
        cq::ChqAssembleResult r;
        cq::ChqAssembleInput in;
        in.timeline = &tl;
        in.pts = cq::ChqRationalTime{120000, 120000};
        in.target_width = 1080;
        in.target_height = 1920;
        in.purpose = cq::ChqGraphPurpose::kAudioOnly;
        const cq::ChqStatus s = asm0.Assemble(in, g, r);
        Check(s.IsOk(), "纯音频用途：装配成功（命中片段）");
        Check(g.NodeCount() == 0, "纯音频用途：不装配任何 GPU 节点");
    }
    {
        // 两条视频轨在同一时刻都有片段 → 只取第一条，且如实标记
        cq::ChqTimeline tl;
        uint64_t t1 = 0, t2 = 0, c1 = 0, c2 = 0;
        Check(MakeTimeline(tl, t1, c1, 42, cq::ChqRationalTime{0, 120000},
                           cq::ChqRationalTime{600000, 120000}),
              "轨 1");
        if (tl.AddTrack(cq::ChqTrackKind::kVideo, t2).IsOk()) {
            cq::ChqClip clip;
            clip.kind = cq::ChqClipKind::kVideo;
            clip.source.asset_id = 43;
            clip.source.source_in = cq::ChqRationalTime{0, 120000};
            clip.source.source_duration = cq::ChqRationalTime{600000, 120000};
            clip.start = cq::ChqRationalTime{0, 120000};
            clip.duration = cq::ChqRationalTime{600000, 120000};
            tl.InsertClip(t2, clip, c2);
        }
        cq::ChqGraphAssembler asm0;
        cq::ChqRenderGraph g;
        cq::ChqAssembleResult r;
        cq::ChqAssembleInput in;
        in.timeline = &tl;
        in.pts = cq::ChqRationalTime{120000, 120000};
        in.target_width = 1080;
        in.target_height = 1920;
        const cq::ChqStatus s = asm0.Assemble(in, g, r);
        Check(s.IsOk() && r.multi_track_ignored, "多轨命中：multi_track_ignored = true（不再静默）");
        Check(g.NodeCount() == 3, "多轨命中：仍只装配一条轨的 3 个节点（B0 边界）");
    }
    {
        // MODEL-003：带**启用**效果的片段 → effects_dropped 如实为真。
        // B0 不应用效果（归 RENDER-011），但这个标志必须为真 ——
        // 否则 UI 会显示一个"加了却没效果"的静默失败。
        cq::ChqTimeline tl;
        uint64_t tid = 0, cid = 0;
        Check(MakeTimeline(tl, tid, cid, 42, cq::ChqRationalTime{0, 120000},
                           cq::ChqRationalTime{600000, 120000}),
              "造时间线（效果用）");
        cq::ChqEffectBinding effect;
        effect.effect_id = "cq.effect.test";
        effect.effect_name = "测试效果";
        effect.params.Set("opacity", cq::ChqPropertyValue::F(0.5f));
        Check(tl.AddClipEffect(cid, effect).IsOk(), "给片段挂一个启用效果");

        cq::ChqGraphAssembler asm0;
        cq::ChqRenderGraph g;
        cq::ChqAssembleResult r;
        cq::ChqAssembleInput in;
        in.timeline = &tl;
        in.pts = cq::ChqRationalTime{120000, 120000};
        in.target_width = 1080;
        in.target_height = 1920;
        Check(asm0.Assemble(in, g, r).IsOk(), "带效果片段：装配成功");
        Check(r.effects_dropped, "带启用效果：effects_dropped = true（不再静默）");
        Check(g.NodeCount() == 3, "带效果片段：仍装配 3 节点（效果应用归 RENDER-011）");

        // 禁用后不再上报：禁用效果不影响像素，"丢弃"它是无信息噪声
        Check(tl.SetClipEffectEnabled(cid, "cq.effect.test", false).IsOk(), "禁用该效果");
        Check(asm0.Assemble(in, g, r).IsOk() && !r.effects_dropped,
              "效果禁用后：effects_dropped = false（禁用效果无像素影响）");
    }

    // ---------- D. 执行器 ----------
    std::printf("\n[D] 执行器（CPU Prepare / GPU Encode 两阶段）\n");
    {
        cq::ChqTimeline tl;
        uint64_t tid = 0, cid = 0;
        Check(MakeTimeline(tl, tid, cid, 42, cq::ChqRationalTime{0, 120000},
                           cq::ChqRationalTime{600000, 120000}),
              "造时间线（执行器用）");

        cq::ChqGraphAssembler asm0;
        cq::ChqRenderGraph g;
        cq::ChqAssembleResult r;
        cq::ChqAssembleInput in;
        in.timeline = &tl;
        in.pts = cq::ChqRationalTime{120000, 120000};
        in.fit_mode = cq::ChqFitMode::kStretch;
        in.target_width = 1080;
        in.target_height = 1920;
        Check(asm0.Assemble(in, g, r).IsOk(), "装配成功");

        cq::ChqAssetRegistry assets;
        FakeFrameSource frames;
        FakeBlitPass blit;
        FakeCommandEncoder penc;
        FakeGfxEncoder genc(&penc);
        cq::ChqRenderEvaluator ev;
        cq::ChqRenderEvaluator::Resources res;
        res.blit = &blit;
        res.frames = &frames;
        res.assets = &assets;

        cq::ChqCancelToken token;
        cq::ChqRenderEvaluator::Timings tm;
        Check(ev.Prepare(g, res, token, tm).IsOk(), "Prepare 成功");
        Check(frames.calls == 1, "Prepare 只取一次帧（1 个 source 节点）");
        Check(frames.last_asset == 42, "取帧用的 asset_id 来自 source 节点");
        // 源尺寸已回填到 source 节点（视口计算的输入）
        uint32_t order[cq::kMaxGraphNodes] = {};
        uint32_t count = 0;
        g.TopoOrder(order, count);
        const cq::ChqRenderNodeDesc* src_node = g.Node(order[0]);
        Check(src_node != nullptr && src_node->source_width == 1920 && src_node->source_height == 1080,
              "源尺寸回填到 source 节点（视口计算的输入）");

        cq::ChqFrameContext ctx;
        ctx.pts = in.pts;
        Check(ev.Encode(genc, ctx, token).IsOk(), "Encode 成功");
        // RENDER-010：时间线路径的绘制节点是 kTransform（不分两条路，见装配器注释）。
        Check(blit.calls == 0 && blit.layer_calls == 1, "Encode 走变换层一次，不走全屏拷贝");
        Check(blit.last_layer_count == 6, "一层 = 6 顶点（两个三角形）");
        Check(genc.viewport_calls == 0, "stretch：不设视口（适配矩形烤进顶点）");
        float bounds[4] = {};
        LayerPosBounds(blit.last_layer_verts, blit.last_layer_count, bounds);
        Check(bounds[0] < -0.999f && bounds[1] > 0.999f && bounds[2] < -0.999f && bounds[3] > 0.999f,
              "stretch 顶点铺满整个目标（NDC ±1）");
        Check(blit.last_layer_verts[4] == 1.0f, "alpha = 1（未设变换时不半透明）");
    }
    {
        // contain：源 16:9 → 目标 9:16，视口必须非整目标（否则静默退化成 stretch）
        cq::ChqTimeline tl;
        uint64_t tid = 0, cid = 0;
        MakeTimeline(tl, tid, cid, 42, cq::ChqRationalTime{0, 120000},
                     cq::ChqRationalTime{600000, 120000});
        cq::ChqGraphAssembler asm0;
        cq::ChqRenderGraph g;
        cq::ChqAssembleResult r;
        cq::ChqAssembleInput in;
        in.timeline = &tl;
        in.pts = cq::ChqRationalTime{120000, 120000};
        in.fit_mode = cq::ChqFitMode::kContain;
        in.target_width = 1080;
        in.target_height = 1920;
        Check(asm0.Assemble(in, g, r).IsOk(), "装配成功（contain）");

        cq::ChqAssetRegistry assets;
        FakeFrameSource frames;  // 1920x1080
        FakeBlitPass blit;
        FakeCommandEncoder penc;
        FakeGfxEncoder genc(&penc);
        cq::ChqRenderEvaluator ev;
        cq::ChqRenderEvaluator::Resources res;
        res.blit = &blit;
        res.frames = &frames;
        res.assets = &assets;
        cq::ChqCancelToken token;
        cq::ChqRenderEvaluator::Timings tm;
        Check(ev.Prepare(g, res, token, tm).IsOk(), "Prepare 成功（contain）");
        cq::ChqFrameContext ctx;
        ctx.pts = in.pts;
        Check(ev.Encode(genc, ctx, token).IsOk(), "Encode 成功（contain）");
        // RENDER-010 改的机制不是像素：contain 由视口改成把内切矩形烤进顶点。
        // 判据跟着换成顶点的 NDC 包围盒 —— 数值与原视口矩形一一对应：
        //   16:9 装进 1080x1920 → w=1080（x 铺满）、h=607.5、y=656.25
        //   → y_ndc = 1 - 2y/1920 = ±0.31641
        Check(genc.viewport_calls == 0, "contain：不再设视口（矩形进了顶点）");
        float bounds[4] = {};
        LayerPosBounds(blit.last_layer_verts, blit.last_layer_count, bounds);
        Check(bounds[0] < -0.999f && bounds[1] > 0.999f, "contain：宽度贴边（x 铺满）");
        Check(bounds[2] > -0.325f && bounds[2] < -0.308f, "contain：下边 y_ndc ≈ -0.316（h=607.5）");
        Check(bounds[3] > 0.308f && bounds[3] < 0.325f, "contain：上边 y_ndc ≈ +0.316（垂直居中）");
    }
    {
        // 未 Prepare 就 Encode → 必须报错（顺序契约）
        cq::ChqRenderEvaluator ev;
        FakeCommandEncoder penc;
        FakeGfxEncoder genc(&penc);
        cq::ChqFrameContext ctx;
        cq::ChqCancelToken token;
        Check(!ev.Encode(genc, ctx, token).IsOk(), "未 Prepare 就 Encode → 报错（顺序契约）");
    }

    // ---------- E. 时钟源 ----------
    std::printf("\n[E] 时钟源（预览=实时 / 导出=步进）\n");
    {
        cq::ChqSteppedClock clk(cq::ChqRationalTime{0, 120000},       // start = 0
                                cq::ChqRationalTime{4000, 120000},    // 帧时长 = 1/30 s
                                cq::ChqRationalTime{12000, 120000});  // end = 0.1s
        Check(clk.Kind() == cq::ChqClockKind::kStepped, "步进时钟 Kind 正确");
        cq::ChqRationalTime t{0, 1};
        Check(clk.Now(t).IsOk() && cq::CompareRational(t, cq::ChqRationalTime{0, 120000}) == 0,
              "第 0 帧 = start");
        clk.Advance();
        clk.Now(t);
        Check(cq::CompareRational(t, cq::ChqRationalTime{4000, 120000}) == 0, "第 1 帧 = start + 1 帧");
        clk.Advance();
        clk.Now(t);
        Check(cq::CompareRational(t, cq::ChqRationalTime{8000, 120000}) == 0, "第 2 帧 = start + 2 帧");
        Check(!clk.Exhausted(), "第 2 帧未耗尽");
        clk.Advance();
        clk.Now(t);
        Check(cq::CompareRational(t, cq::ChqRationalTime{12000, 120000}) == 0, "第 3 帧 = start + 3 帧");
        Check(clk.Exhausted(), "到达 end 后 Exhausted = true");
    }
    {
        RealtimeClock rt;
        rt.now = cq::ChqRationalTime{60000, 120000};
        cq::ChqRationalTime t{0, 1};
        Check(rt.Now(t).IsOk(), "实时时钟 Now 可用");
        Check(rt.Advance().code == cq::ChqStatusCode::kInvalidArgument,
              "实时时钟 Advance 返回语义不匹配（不静默成功）");
        Check(!rt.Exhausted(), "实时时钟恒不耗尽（没有终点）");
    }

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
