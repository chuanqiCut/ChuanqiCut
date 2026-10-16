// ChuanqiCut — 预览渲染器实现（BIND-003 子步骤 4；B0 起经 RenderGraph）
//
// 渲染一帧的完整链路（每一环都有对应的既有验收证据）：
//   ChqGraphAssembler：ChqTimeline::FindClipAt(pts) + ChqAssetRegistry::Find → 一张 RenderGraph
//   ChqRenderEvaluator::Prepare：ChqFrameProvider::AcquireFrame(src_t)（真实硬解）
//                                + ChqINativeImageImporter::Import（零拷贝，IOSurface 一致）
//   ChqIGfxDevice::RenderFrame：回调 evaluator 编码 ChqIBlitPass（读回像素断言）
//
// 硬约束：零平台类型（本 TU 只经 Platform/GFX 的 opaque 句柄工作）、禁用异常。

#include "cq/preview/chq_preview_renderer.h"

#include <chrono>
#include <utility>  // std::move

#include "cq/base/chq_logging.h"  // CQ_LOG_*_WF：带 workflow 的分级日志（CORE-010）
#include "cq/render/chq_fit_viewport.h"  // 视口计算（与 RenderGraph 共用同一份，避免两套）

namespace cq {
namespace {

using Clock = std::chrono::steady_clock;

int64_t ElapsedNs(Clock::time_point from) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - from).count();
}

// 总耗时的 RAII 记账：提前返回的路径太多，逐条写 total_ns 必然漏。
class TotalTimer {
public:
    explicit TotalTimer(ChqPreviewRenderer::Timings& t) : t_(t) {}
    ~TotalTimer() { t_.total_ns = ElapsedNs(t0_); }

    TotalTimer(const TotalTimer&) = delete;
    TotalTimer& operator=(const TotalTimer&) = delete;

private:
    ChqPreviewRenderer::Timings& t_;
    Clock::time_point t0_ = Clock::now();
};

// 源帧 → 画布的目标视口矩形（ADR-0018）：实现已移至 render/chq_fit_viewport.h，
// 由预览与 RenderGraph 的执行器共用（两份实现必然漂移，ADR-0034）。

// 只清屏、不画任何东西（空隙帧 / 兜底路径）。
class ClearClient final : public ChqIFrameEncoderClient {
public:
    ChqStatus Encode(ChqIGfxEncoder&, const ChqFrameContext&, const ChqCancelToken&) override {
        return ChqStatus::Ok();
    }
};

}  // namespace

ChqPreviewRenderer::ChqPreviewRenderer(ChqIGfxDevice* gfx, ChqIBlitPass* blit,
                                 ChqIFrameProviderFactory* providers,
                                 ChqIModelSnapshotProvider* snapshots, const Config& cfg)
    : gfx_(gfx),
      blit_(blit),
      providers_(providers),
      snapshots_(snapshots),
      cfg_(cfg),
      fit_mode_(static_cast<int>(cfg.fit_mode)) {}

ChqPreviewRenderer::~ChqPreviewRenderer() {
    // 上一帧导入的纹理必须显式释放：Import 返回裸句柄且不接管所有权。
    if (imported_ != nullptr && importer_) {
        importer_->ReleaseTexture(imported_);
        imported_ = nullptr;
    }
}

ChqStatus ChqPreviewRenderer::EnsureTarget() {
    if (target_) return ChqStatus::Ok();
    if (gfx_ == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    ChqRenderTargetDesc rd;
    rd.width = cfg_.width;
    rd.height = cfg_.height;
    rd.color_format = cfg_.format;
    return gfx_->CreateRenderTarget(rd, target_);
}

ChqStatus ChqPreviewRenderer::EnsureImporter() {
    if (importer_) return ChqStatus::Ok();
    if (gfx_ == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    return gfx_->CreateNativeImageImporter(importer_);
}

ChqStatus ChqPreviewRenderer::Resize(uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) return ChqStatus(ChqStatusCode::kInvalidArgument);
    cfg_.width = width;
    cfg_.height = height;
    target_.reset();  // 丢弃旧 RT（其纹理句柄随之失效）
    return EnsureTarget();
}

ChqStatus ChqPreviewRenderer::ClearTarget(const ChqCancelToken& token) {
    if (gfx_ == nullptr || !target_) return ChqStatus(ChqStatusCode::kInvalidArgument);
    ChqFrameContext ctx;
    ctx.target = target_->Handle();
    ClearClient client;
    return gfx_->RenderFrame(ctx, target_.get(), client, token);
}

ChqStatus ChqPreviewRenderer::GetProvider(uint64_t asset_id, const ChqAssetRegistry& assets,
                                    ChqFrameProvider*& out) {
    out = nullptr;
    if (providers_ == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    const ChqMediaSource* src = assets.Find(asset_id);
    if (src == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);  // 素材未注册

    auto it = providers_by_asset_.find(asset_id);
    if (it != providers_by_asset_.end()) {
        if (it->second.opened_path == src->path) {
            out = it->second.provider.get();
            return ChqStatus::Ok();
        }
        // 同 id 重注册为新路径（素材替换）：关闭旧解码会话再重建。
        providers_by_asset_.erase(it);
    }
    std::unique_ptr<ChqFrameProvider> provider;
    ChqStatus s = providers_->Create(*src, provider);
    if (!s.IsOk()) return s;
    out = provider.get();
    providers_by_asset_.emplace(asset_id,
                                ProviderEntry{std::move(provider), src->path});
    return ChqStatus::Ok();
}

ChqStatus ChqPreviewRenderer::RenderFrame(const ChqRationalTime& pts, TextureHandle& out_texture,
                                    const ChqCancelToken& token, int32_t seek_policy) {
    // P142：本帧 seek 策略存成员，供同帧的 Acquire 读取（两者同在泵线程）。
    seek_policy_ = seek_policy;
    out_texture = nullptr;
    last_hit_clip_ = false;
    timings_ = Timings{};
    TotalTimer total(timings_);
    if (gfx_ == nullptr || snapshots_ == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    // ---- 0. 加载模型快照（UIA-009 子步骤 2）----
    // 一次加载、本帧全程使用：渲染期间 session 线程再变更也不影响本帧
    // （不可变数据，无竞争）；下帧自然看到新快照（最终一致）。
    // CORE-010：Release 也记账（看门狗数据源），开销仅一次 atomic store。
    DebugStageGuard g0(debug_stage_, debug_stage_since_, "snapshot");
    std::shared_ptr<const ChqModelSnapshot> snapshot = snapshots_->CurrentSnapshot();
    if (!snapshot || !snapshot->timeline || !snapshot->assets) {
        return ChqStatus(ChqStatusCode::kInternal);
    }
    const ChqTimeline& timeline = *snapshot->timeline;
    const ChqAssetRegistry& assets = *snapshot->assets;

    ChqStatus s = EnsureTarget();
    if (!s.IsOk()) return s;
    // RT 背后的纹理句柄在 RT 重建前一直有效，故可先给出，便于失败时 UI 仍有可显示目标。
    out_texture = target_->GetColorTexture();

    // CORE-010：Release 也记账（看门狗数据源），开销仅一次 atomic store。
    DebugStageGuard g1(debug_stage_, debug_stage_since_, "assemble");
    // ---- 1. 装配 RenderGraph（B0）：片段定位与素材内时间由**装配器**负责 ----
    // 预览与导出共用同一个装配器（红线 #9），差别只在 purpose 与时钟源；
    // 装配结果里的 multi_track_ignored / effects_dropped 会在发生时发 Warn（Release 可见），
    // 不再像以前那样只写在代码注释里。
    ChqAssembleInput in;
    in.timeline = &timeline;
    in.pts = pts;
    in.fit_mode = GetFitMode();
    in.target_width = cfg_.width;
    in.target_height = cfg_.height;
    in.purpose = ChqGraphPurpose::kPreview;
    ChqAssembleResult assembled;
    s = assembler_.Assemble(in, graph_, assembled);
    if (s.code == ChqStatusCode::kIoNotFound) {
        // 空隙：清屏为黑，并如实返回「此处无内容」，不伪造成功。
        // CORE-010：Release 也记账（看门狗数据源），开销仅一次 atomic store。
        DebugStageGuard gc(debug_stage_, debug_stage_since_, "clear-gap");
        ChqStatus cs = ClearTarget(token);
        if (!cs.IsOk()) return cs;
        return ChqStatus(ChqStatusCode::kIoNotFound);
    }
    if (!s.IsOk()) return s;
    last_hit_clip_ = true;
    last_source_time_ = assembled.source_time;

    // ---- 2. Prepare（CPU 侧）：执行器的 source 节点回调本类的 Acquire ----
    // 取帧可能耗时毫秒级（seek + 解码），**不能**塞进 GPU 编码回调里：
    // 那会让 GPU 空转，也会把「取帧慢」和「GPU 慢」混成一个数。
    ChqRenderEvaluator::Resources res;
    res.blit = blit_;
    res.frames = this;
    res.assets = &assets;
    ChqRenderEvaluator::Timings eval_timings;
    // CORE-010：Release 也记账（看门狗数据源），开销仅一次 atomic store。
    DebugStageGuard g3(debug_stage_, debug_stage_since_, "provider+acquire");
    s = evaluator_.Prepare(graph_, res, token, eval_timings);
    // 分段沿用既有语义：acquire = 取帧，import = 导入（两者都在 Acquire 内部发生，
    // 由成员 staged_*_ns 带回；复用命中时两段均为 0）。
    timings_.acquire_ns = staged_acquire_ns_;
    timings_.import_ns = staged_import_ns_;
    if (!s.IsOk()) return s;

    // ---- 3. 绘制（GPU 侧）：RenderFrame 回调 evaluator 编码 blit pass ----
    // ⚠️ 这里的耗时不只是"编码"：gfx_device.cpp 的 RenderFrame 结尾是
    //    WaitUntilCompleted，故含 GPU 执行时间（这是有意的 —— 预览每帧都要
    //    等 GPU，否则解码与导入会无界地跑在 GPU 前面）。
    ChqFrameContext ctx;
    ctx.pts = pts;
    ctx.target = target_->Handle();
    // CORE-010：Release 也记账（看门狗数据源），开销仅一次 atomic store。
    DebugStageGuard g5(debug_stage_, debug_stage_since_, "draw");
    const Clock::time_point t_draw = Clock::now();
    s = gfx_->RenderFrame(ctx, target_.get(), evaluator_, token);
    if (s.IsOk()) timings_.draw_ns = ElapsedNs(t_draw);
    return s;
}

// ---- ChqIFrameSource：取帧 + 零拷贝导入（供 RenderGraph 执行器的 source 节点消费）----
//
// 跨帧状态（provider 表 + MEDIA-024 展示区间复用）留在本类，执行器不复制一份 ——
// 复制就又是一套逻辑（ADR-0034）。
ChqStatus ChqPreviewRenderer::Acquire(uint64_t asset_id, const ChqRationalTime& src_time,
                                      const ChqAssetRegistry& assets, TextureHandle& out_tex,
                                      uint32_t& out_w, uint32_t& out_h, bool* out_reused,
                                      uint32_t* out_rotation, const ChqCancelToken& token) {
    out_tex = nullptr;
    out_w = 0;
    out_h = 0;
    if (out_reused != nullptr) *out_reused = false;
    if (out_rotation != nullptr) *out_rotation = 0;
    staged_acquire_ns_ = 0;
    staged_import_ns_ = 0;
    if (providers_ == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    // ---- 1. 展示区间内复用（MEDIA-024）：src_time 落在上一导入帧的展示区间
    // 且同一素材 → 直接重画已导入纹理，**跳过 acquire+import**。
    //
    // 为什么：落在区间内的重复/微进请求走 provider 慢路径 = seek + 重解整个 GOP
    // （ADR-0017「已知限制」第 1 条，实测 p95 253ms 尖刺）。60fps 素材 + 60Hz
    // 请求时高频触发（请求节奏与帧率同阶，catch-up 后必落区间内）—— golden
    // 30fps + 10fps 场景永远测不出来。lease 语义零违反：复用的是**我们自己
    // 持有的导入纹理**（imported_ 本就存活到下一次导入），不经手 provider 帧。
    {
        ChqRationalTime last_end{0, 1};
        if (last_import_valid_ && last_import_asset_ == asset_id && imported_ != nullptr &&
            CompareRational(src_time, last_import_pts_) >= 0 &&
            AddRational(last_import_pts_, last_import_dur_, last_end).IsOk() &&
            CompareRational(src_time, last_end) < 0) {
            out_tex = imported_;
            out_w = last_import_w_;
            out_h = last_import_h_;
            if (out_reused != nullptr) *out_reused = true;
            if (out_rotation != nullptr) *out_rotation = last_import_rotation_;
            last_frame_pts_ = last_import_pts_;  // 展示的仍是上一导入帧
            if (debug_reuse_logs_ < 3) {
                ++debug_reuse_logs_;
                CQ_LOG_TRACE_WF(ChqWorkflow::kFrameCache, "reuse 命中 pts=%lld/%d",
                                static_cast<long long>(last_import_pts_.value),
                                static_cast<int>(last_import_pts_.timescale));
            }
            return ChqStatus::Ok();
        }
    }

    // ---- 2. 取帧（AcquireFrame 内部按需 seek，未 seek 或目标变化时幂等对齐）----
    ChqFrameProvider* provider = nullptr;
    ChqStatus s = GetProvider(asset_id, assets, provider);
    if (!s.IsOk()) return s;

    ChqFrameRequest req;
    req.at = src_time;
    // P142：seek 策略由调用方（预览泵 → RenderFrame）存入成员，scrub 拖动传
    // kKeyframeBefore 取廉价关键帧定位（跟手优先），播放 / 松手确认传 kExact。
    // 此前无条件硬编码 kExact，让每次拖动 delta 都精确 seek 重解整个 GOP → 拖动卡顿。
    req.policy = static_cast<ChqSeekPolicy>(seek_policy_);
    ChqMediaFrame frame;
    const Clock::time_point t_acquire = Clock::now();
    s = provider->AcquireFrame(req, frame, token);
    // ⚠️ 段耗时只记**成功**路径。失败路径的耗时是另一回事（含重试/恢复），
    //    混进均值会把"解码多快"这个量算歪。失败次数由调用方的状态码统计。
    if (s.IsOk()) staged_acquire_ns_ = ElapsedNs(t_acquire);
    if (!s.IsOk()) return s;
    if (frame.type != ChqMediaType::kVideo || frame.video.image == nullptr) {
        provider->ReleaseFrame(frame);
        return ChqStatus(ChqStatusCode::kDecodeError);
    }
    // 记录实际帧 pts：素材内容静态时像素无法区分「取对了帧」与「复用旧帧」，
    // 这个量是可验证的差异点（单测据此断言渲染帧随时间推进）。
    last_frame_pts_ = frame.video.pts;
    // ⚠️ 以下字段必须在 ReleaseFrame 前捕获：lease 归约会把整个 frame 重置
    //    为空（ChqMediaFrame{}），此后读到的任何字段都是默认值 {0,1}/0
    //    （MEDIA-024 首版即在 pts/duration 上踩此坑，复用永不命中）。
    out_w = frame.video.width;
    out_h = frame.video.height;
    const uint16_t frame_rotation = frame.video.rotation;  // #21：ReleaseFrame 前捕获
    if (out_rotation != nullptr) *out_rotation = frame_rotation;
    const ChqRationalTime frame_pts = frame.video.pts;
    const ChqRationalTime frame_dur = frame.video.duration;

    // ---- 3. 零拷贝导入：CVPixelBuffer → 纹理 ----
    s = EnsureImporter();
    if (!s.IsOk()) {
        provider->ReleaseFrame(frame);
        return s;
    }
    bool cpu_fallback = false;
    TextureHandle tex = nullptr;
    const Clock::time_point t_import = Clock::now();
    s = importer_->Import(frame.video.image, ChqTextureUsage::kSampled, tex, cpu_fallback);
    if (s.IsOk()) staged_import_ns_ = ElapsedNs(t_import);
    // 导入完成即可归还帧：零拷贝路径的纹理持 CVMetalTextureRef（锁住源 IOSurface），
    // CPU 退化路径已把像素拷进纹理——两条路径都不再依赖源 buffer 存活。
    provider->ReleaseFrame(frame);
    if (!s.IsOk()) return s;
    if (tex == nullptr) return ChqStatus(ChqStatusCode::kInternal);
    last_cpu_fallback_ = cpu_fallback;

    // 释放上一帧的导入纹理，否则每帧泄漏一张（含其 IOSurface 引用）。
    if (imported_ != nullptr) importer_->ReleaseTexture(imported_);
    imported_ = tex;

    // 记录展示区间（MEDIA-024 复用判据）：素材内时间 = frame pts（同为素材
    // 时间轴），区间 = [pts, pts + duration)；素材 id 与尺寸一并记录。
    // ⚠️ 用 ReleaseFrame **前**捕获的副本（frame 已被 lease 归约重置）。
    last_import_asset_ = asset_id;
    last_import_pts_ = frame_pts;
    last_import_dur_ = frame_dur;
    last_import_w_ = out_w;
    last_import_h_ = out_h;
    last_import_rotation_ = frame_rotation;  // #21：复用判据一并携带旋转角
    last_import_valid_ = frame_dur.value > 0;
    if (debug_import_logs_ < 3) {
        ++debug_import_logs_;
        // ⚠️ 这里打的是**已 Record 的 last_import_* 字段**：MEDIA-027 期间这行打的是
        //    frame.video.* —— 而那时 frame 已被 ReleaseFrame 清零，输出恒为
        //    pts=0/1 dur=0/1，是条看着正常、实为废纸的诊断（该陷阱在本仓库第 4 次）。
        //    **别改回 frame.video.***。
        CQ_LOG_TRACE_WF(ChqWorkflow::kRender,
                        "import 已记录 pts=%lld/%d dur=%lld/%d %ux%u",
                        static_cast<long long>(last_import_pts_.value),
                        static_cast<int>(last_import_pts_.timescale),
                        static_cast<long long>(last_import_dur_.value),
                        static_cast<int>(last_import_dur_.timescale), out_w, out_h);
    }

    out_tex = tex;
    return ChqStatus::Ok();
}

}  // namespace cq
