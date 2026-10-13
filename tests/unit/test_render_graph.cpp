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
                          uint32_t& out_h, bool* out_reused, const cq::ChqCancelToken&) override {
        ++calls;
        last_asset = asset_id;
        last_src_time = src_time;
        out_tex = reinterpret_cast<cq::TextureHandle>(this);  // 哨兵：只要非 null
        out_w = src_width;
        out_h = src_height;
        if (out_reused != nullptr) *out_reused = false;
        return cq::ChqStatus::Ok();
    }
    int calls = 0;
    uint64_t last_asset = 0;
    cq::ChqRationalTime last_src_time{0, 1};
    uint32_t src_width = 1920;
    uint32_t src_height = 1080;
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
    cq::ChqStatus Encode(cq::ChqICommandEncoder&, cq::TextureHandle tex) override {
        ++calls;
        last_tex = tex;
        return fail_next ? cq::ChqStatus(cq::ChqStatusCode::kInternal) : cq::ChqStatus::Ok();
    }
    void Destroy() override {}
    int calls = 0;
    cq::TextureHandle last_tex = nullptr;
    bool fail_next = false;
};

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
        const cq::ChqRationalTime start{120000, 120000};   // 1.0s
        const cq::ChqRationalTime dur{600000, 120000};     // 5.0s
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
        Check(g.NodeCount() == 3, "装配出 3 个节点（source/blit/sink）");
        Check(r.hit_clip_id == cid && r.hit_asset_id == 42, "命中片段与素材 id 正确");
        // source_time = source_in(0) + (pts 3.0s - start 1.0s) = 2.0s
        Check(cq::CompareRational(r.source_time, cq::ChqRationalTime{240000, 120000}) == 0,
              "素材内时间 = 2.0s（source_in + (pts - start)）");
        Check(!r.multi_track_ignored, "单轨：未标记多轨忽略");
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
        Check(blit.calls == 1, "Encode 只画一次（1 个 blit 节点）");
        Check(genc.viewport_calls == 0, "stretch：不设视口（与引入 RenderGraph 前逐该厂商一致）");
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
        Check(genc.viewport_calls == 1, "contain：设了视口（不是整目标）");
        // 16:9 装进 1080x1920（9:16）→ 内切宽度贴边：w=1080, h=607.5，上下留 bar
        Check(penc.has_viewport && penc.vp[2] > 1079.0f && penc.vp[2] < 1081.0f,
              "contain 视口宽 = 目标宽（宽度贴边）");
        Check(penc.vp[3] > 600.0f && penc.vp[3] < 615.0f, "contain 视口高 ≈ 607.5（16:9 内切）");
        Check(penc.vp[1] > 650.0f && penc.vp[1] < 660.0f, "contain 视口 y ≈ 656（垂直居中）");
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
        cq::ChqSteppedClock clk(cq::ChqRationalTime{0, 120000},      // start = 0
                                cq::ChqRationalTime{4000, 120000},   // 帧时长 = 1/30 s
                                cq::ChqRationalTime{12000, 120000}); // end = 0.1s
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
