// ChuanqiCut — 预览渲染器实现（BIND-003 子步骤 4）
//
// 渲染一帧的完整链路（每一环都有对应的既有验收证据）：
//   Timeline::FindClipAt(pts)            → model_timeline
//   AssetRegistry::Find(asset_id)        → asset_registry
//   FrameProvider::AcquireFrame(src_t)   → frame_provider_apple（真实硬解）
//   INativeImageImporter::Import         → pala_native_image（零拷贝，IOSurface 一致）
//   IBlitPass::Encode + IGfxDevice::RenderFrame → gfx_device（读回像素断言）
//
// 硬约束：零平台类型（本 TU 只经 PAL/GFX 的 opaque 句柄工作）、禁用异常。

#include "cq/preview/preview_renderer.h"

#include <chrono>
#include <utility>  // std::move

namespace cq {
namespace {

using Clock = std::chrono::steady_clock;

int64_t ElapsedNs(Clock::time_point from) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - from).count();
}

// 总耗时的 RAII 记账：提前返回的路径太多，逐条写 total_ns 必然漏。
class TotalTimer {
public:
    explicit TotalTimer(PreviewRenderer::Timings& t) : t_(t) {}
    ~TotalTimer() { t_.total_ns = ElapsedNs(t0_); }

    TotalTimer(const TotalTimer&) = delete;
    TotalTimer& operator=(const TotalTimer&) = delete;

private:
    PreviewRenderer::Timings& t_;
    Clock::time_point t0_ = Clock::now();
};

// 源帧 → 画布的目标视口矩形（ADR-0015）：
//   kStretch / 源尺寸未知(0) / 同比例 → 整目标（与引入 FitMode 前逐字节一致）；
//   kContain → 内切矩形居中（letterbox，不裁内容）；
//   kCover   → 外接矩形居中（裁剪铺满，超出目标的部分被光栅化丢弃）。
// out = {x, y, w, h}（像素，原点 = target 左上）。
void ComputeFitViewport(FitMode mode, uint32_t sw, uint32_t sh,
                        uint32_t dw, uint32_t dh, float out[4]) {
    out[0] = 0.0f;
    out[1] = 0.0f;
    out[2] = static_cast<float>(dw);
    out[3] = static_cast<float>(dh);
    if (mode == FitMode::kStretch || sw == 0 || sh == 0 || dw == 0 || dh == 0 ||
        (sw == dw && sh == dh)) {
        return;
    }
    const double src_ar = static_cast<double>(sw) / static_cast<double>(sh);
    const double dst_ar = static_cast<double>(dw) / static_cast<double>(dh);
    // 宽度贴边：contain 且源更宽，或 cover 且源更矮/更窄（cover 取另一半分支）。
    const bool width_bound =
        (mode == FitMode::kContain) ? (src_ar > dst_ar) : (src_ar <= dst_ar);
    double w, h;
    if (width_bound) {
        w = static_cast<double>(dw);
        h = w / src_ar;
    } else {
        h = static_cast<double>(dh);
        w = h * src_ar;
    }
    if (w < 1.0) w = 1.0;
    if (h < 1.0) h = 1.0;
    out[0] = static_cast<float>((static_cast<double>(dw) - w) / 2.0);
    out[1] = static_cast<float>((static_cast<double>(dh) - h) / 2.0);
    out[2] = static_cast<float>(w);
    out[3] = static_cast<float>(h);
}

// 把「一张纹理全屏画进当前 pass」适配成 IGfxDevice::RenderFrame 需要的编码器客户端。
class BlitClient final : public IFrameEncoderClient {
public:
    // viewport 可选：has_viewport=false 时完全等价于引入 FitMode 前的行为
    // （不触碰视口状态，Metal 默认 viewport = 整目标）。
    BlitClient(IBlitPass* blit, TextureHandle tex, const float* viewport = nullptr)
        : blit_(blit), tex_(tex), viewport_(viewport) {}

    Status Encode(IGfxEncoder& encoder, const FrameContext&, const CancelToken&) override {
        if (blit_ == nullptr) return Status(StatusCode::kInvalidArgument);
        // IBlitPass 在 PAL 层，收的是 PAL 的 ICommandEncoder（PAL 不能反向依赖 GFX）。
        ICommandEncoder* pal_encoder = encoder.PalEncoder();
        if (pal_encoder == nullptr) return Status(StatusCode::kInternal);
        if (viewport_ != nullptr) {
            encoder.SetViewport(viewport_[0], viewport_[1], viewport_[2], viewport_[3]);
        }
        return blit_->Encode(*pal_encoder, tex_);
    }

private:
    IBlitPass* blit_;
    TextureHandle tex_;
    const float* viewport_;
};

// 只清屏、不画任何东西（空隙帧 / 兜底路径）。
class ClearClient final : public IFrameEncoderClient {
public:
    Status Encode(IGfxEncoder&, const FrameContext&, const CancelToken&) override {
        return Status::Ok();
    }
};

}  // namespace

PreviewRenderer::PreviewRenderer(IGfxDevice* gfx, IBlitPass* blit,
                                 IFrameProviderFactory* providers,
                                 IModelSnapshotProvider* snapshots, const Config& cfg)
    : gfx_(gfx),
      blit_(blit),
      providers_(providers),
      snapshots_(snapshots),
      cfg_(cfg),
      fit_mode_(static_cast<int>(cfg.fit_mode)) {}

PreviewRenderer::~PreviewRenderer() {
    // 上一帧导入的纹理必须显式释放：Import 返回裸句柄且不接管所有权。
    if (imported_ != nullptr && importer_) {
        importer_->ReleaseTexture(imported_);
        imported_ = nullptr;
    }
}

Status PreviewRenderer::EnsureTarget() {
    if (target_) return Status::Ok();
    if (gfx_ == nullptr) return Status(StatusCode::kInvalidArgument);
    RenderTargetDesc rd;
    rd.width = cfg_.width;
    rd.height = cfg_.height;
    rd.color_format = cfg_.format;
    return gfx_->CreateRenderTarget(rd, target_);
}

Status PreviewRenderer::EnsureImporter() {
    if (importer_) return Status::Ok();
    if (gfx_ == nullptr) return Status(StatusCode::kInvalidArgument);
    return gfx_->CreateNativeImageImporter(importer_);
}

Status PreviewRenderer::Resize(uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) return Status(StatusCode::kInvalidArgument);
    cfg_.width = width;
    cfg_.height = height;
    target_.reset();  // 丢弃旧 RT（其纹理句柄随之失效）
    return EnsureTarget();
}

Status PreviewRenderer::ClearTarget(const CancelToken& token) {
    if (gfx_ == nullptr || !target_) return Status(StatusCode::kInvalidArgument);
    FrameContext ctx;
    ctx.target = target_->Handle();
    ClearClient client;
    return gfx_->RenderFrame(ctx, target_.get(), client, token);
}

Status PreviewRenderer::GetProvider(uint64_t asset_id, const AssetRegistry& assets,
                                    FrameProvider*& out) {
    out = nullptr;
    if (providers_ == nullptr) return Status(StatusCode::kInvalidArgument);
    const MediaSource* src = assets.Find(asset_id);
    if (src == nullptr) return Status(StatusCode::kInvalidArgument);  // 素材未注册

    auto it = providers_by_asset_.find(asset_id);
    if (it != providers_by_asset_.end()) {
        if (it->second.opened_path == src->path) {
            out = it->second.provider.get();
            return Status::Ok();
        }
        // 同 id 重注册为新路径（素材替换）：关闭旧解码会话再重建。
        providers_by_asset_.erase(it);
    }
    std::unique_ptr<FrameProvider> provider;
    Status s = providers_->Create(*src, provider);
    if (!s.IsOk()) return s;
    out = provider.get();
    providers_by_asset_.emplace(asset_id,
                                ProviderEntry{std::move(provider), src->path});
    return Status::Ok();
}

Status PreviewRenderer::RenderFrame(const RationalTime& pts, TextureHandle& out_texture,
                                    const CancelToken& token) {
    out_texture = nullptr;
    last_hit_clip_ = false;
    timings_ = Timings{};
    TotalTimer total(timings_);
    if (gfx_ == nullptr || snapshots_ == nullptr) return Status(StatusCode::kInvalidArgument);

    // ---- 0. 加载模型快照（UIA-009 子步骤 2）----
    // 一次加载、本帧全程使用：渲染期间 session 线程再变更也不影响本帧
    // （不可变数据，无竞争）；下帧自然看到新快照（最终一致）。
    std::shared_ptr<const ModelSnapshot> snapshot = snapshots_->CurrentSnapshot();
    if (!snapshot || !snapshot->timeline || !snapshot->assets) {
        return Status(StatusCode::kInternal);
    }
    const Timeline& timeline = *snapshot->timeline;
    const AssetRegistry& assets = *snapshot->assets;

    Status s = EnsureTarget();
    if (!s.IsOk()) return s;
    // RT 背后的纹理句柄在 RT 重建前一直有效，故可先给出，便于失败时 UI 仍有可显示目标。
    out_texture = target_->GetColorTexture();

    // ---- 1. 定位片段：只取**第一条命中的视频轨**（本期不支持多轨合成）----
    const Clip* clip = nullptr;
    for (const Track& track : timeline.Tracks()) {
        if (track.kind != TrackKind::kVideo || !track.enabled) continue;
        const Clip* hit = timeline.FindClipAt(track.id, pts);
        if (hit != nullptr) {
            clip = hit;
            break;
        }
    }
    if (clip == nullptr) {
        // 空隙：清屏为黑，并如实返回「此处无内容」，不伪造成功。
        Status cs = ClearTarget(token);
        if (!cs.IsOk()) return cs;
        return Status(StatusCode::kIoNotFound);
    }
    last_hit_clip_ = true;

    // ---- 2. 素材内时间 = source_in + (pts - clip.start) ----
    // MODEL-001 无变速字段，故时间线时长与素材时长 1:1（retime 落地后此处需改）。
    RationalTime offset{0, 1};
    if (!SubRational(pts, clip->start, offset).IsOk()) return Status(StatusCode::kOverflow);
    RationalTime src_time{0, 1};
    if (!AddRational(clip->source.source_in, offset, src_time).IsOk()) {
        return Status(StatusCode::kOverflow);
    }
    last_source_time_ = src_time;

    // ---- 3. 取帧（AcquireFrame 内部按需 seek，未 seek 或目标变化时幂等对齐）----
    FrameProvider* provider = nullptr;
    s = GetProvider(clip->source.asset_id, assets, provider);
    if (!s.IsOk()) return s;

    FrameRequest req;
    req.at = src_time;
    req.policy = SeekPolicy::kExact;  // 预览也要精确：编辑正确性优先于速度
    MediaFrame frame;
    const Clock::time_point t_acquire = Clock::now();
    s = provider->AcquireFrame(req, frame, token);
    // ⚠️ 段耗时只记**成功**路径。失败路径的耗时是另一回事（含重试/恢复），
    //    混进均值会把"解码多快"这个量算歪。失败次数由调用方的状态码统计。
    if (s.IsOk()) timings_.acquire_ns = ElapsedNs(t_acquire);
    if (!s.IsOk()) return s;
    if (frame.type != MediaType::kVideo || frame.video.image == nullptr) {
        provider->ReleaseFrame(frame);
        return Status(StatusCode::kDecodeError);
    }
    // 记录实际帧 pts：素材内容静态时像素无法区分「取对了帧」与「复用旧帧」，
    // 这个量是可验证的差异点（单测据此断言渲染帧随时间推进）。
    last_frame_pts_ = frame.video.pts;
    // ⚠️ 源尺寸必须在 ReleaseFrame 前捕获：lease 归约会把整个 frame 重置为空
    //    （MediaFrame{}），此后读到的任何字段都是 0。
    const uint32_t src_w = frame.video.width;
    const uint32_t src_h = frame.video.height;

    // ---- 4. 零拷贝导入：CVPixelBuffer → 纹理 ----
    s = EnsureImporter();
    if (!s.IsOk()) {
        provider->ReleaseFrame(frame);
        return s;
    }
    TextureHandle tex = nullptr;
    bool cpu_fallback = false;
    const Clock::time_point t_import = Clock::now();
    s = importer_->Import(frame.video.image, TextureUsage::kSampled, tex, cpu_fallback);
    if (s.IsOk()) timings_.import_ns = ElapsedNs(t_import);
    // 导入完成即可归还帧：零拷贝路径的纹理持 CVMetalTextureRef（锁住源 IOSurface），
    // CPU 退化路径已把像素拷进纹理——两条路径都不再依赖源 buffer 存活。
    provider->ReleaseFrame(frame);
    if (!s.IsOk()) return s;
    if (tex == nullptr) return Status(StatusCode::kInternal);
    last_cpu_fallback_ = cpu_fallback;

    // 释放上一帧的导入纹理，否则每帧泄漏一张（含其 IOSurface 引用）。
    if (imported_ != nullptr) importer_->ReleaseTexture(imported_);
    imported_ = tex;

    // ---- 5. 绘制到离屏 RT ----
    // ⚠️ 这里的耗时不只是"编码"：gfx_device.cpp 的 RenderFrame 结尾是
    //    WaitUntilCompleted，故含 GPU 执行时间（这是有意的 —— 预览每帧都要
    //    等 GPU，否则解码与导入会无界地跑在 GPU 前面）。
    FrameContext ctx;
    ctx.pts = pts;
    ctx.target = target_->Handle();
    // 宽高比适配（UIA-011）：kStretch 时 viewport 为整目标 → 不设视口，
    // 与引入 FitMode 前的编码序列逐字节一致（既有像素断言不因此改变）。
    float viewport[4];
    const FitMode fit_mode = GetFitMode();
    ComputeFitViewport(fit_mode, src_w, src_h, cfg_.width, cfg_.height, viewport);
    const bool has_viewport = !(viewport[0] == 0.0f && viewport[1] == 0.0f &&
                                viewport[2] == static_cast<float>(cfg_.width) &&
                                viewport[3] == static_cast<float>(cfg_.height));
    BlitClient client(blit_, tex, has_viewport ? viewport : nullptr);
    const Clock::time_point t_draw = Clock::now();
    s = gfx_->RenderFrame(ctx, target_.get(), client, token);
    if (s.IsOk()) timings_.draw_ns = ElapsedNs(t_draw);
    return s;
}

}  // namespace cq
