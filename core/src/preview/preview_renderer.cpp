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

#include <utility>  // std::move

namespace cq {
namespace {

// 把「一张纹理全屏画进当前 pass」适配成 IGfxDevice::RenderFrame 需要的编码器客户端。
class BlitClient final : public IFrameEncoderClient {
public:
    BlitClient(IBlitPass* blit, TextureHandle tex) : blit_(blit), tex_(tex) {}

    Status Encode(IGfxEncoder& encoder, const FrameContext&, const CancelToken&) override {
        if (blit_ == nullptr) return Status(StatusCode::kInvalidArgument);
        return blit_->Encode(encoder, tex_);
    }

private:
    IBlitPass* blit_;
    TextureHandle tex_;
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
                                 IFrameProviderFactory* providers, const Timeline* timeline,
                                 const AssetRegistry* assets, const Config& cfg)
    : gfx_(gfx), blit_(blit), providers_(providers), timeline_(timeline), assets_(assets),
      cfg_(cfg) {}

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

Status PreviewRenderer::GetProvider(uint64_t asset_id, FrameProvider*& out) {
    out = nullptr;
    auto it = providers_by_asset_.find(asset_id);
    if (it != providers_by_asset_.end()) {
        out = it->second.get();
        return Status::Ok();
    }
    if (assets_ == nullptr || providers_ == nullptr) return Status(StatusCode::kInvalidArgument);
    const MediaSource* src = assets_->Find(asset_id);
    if (src == nullptr) return Status(StatusCode::kInvalidArgument);  // 素材未注册
    std::unique_ptr<FrameProvider> provider;
    Status s = providers_->Create(*src, provider);
    if (!s.IsOk()) return s;
    out = provider.get();
    providers_by_asset_.emplace(asset_id, std::move(provider));
    return Status::Ok();
}

Status PreviewRenderer::RenderFrame(const RationalTime& pts, TextureHandle& out_texture,
                                    const CancelToken& token) {
    out_texture = nullptr;
    last_hit_clip_ = false;
    if (gfx_ == nullptr || timeline_ == nullptr) return Status(StatusCode::kInvalidArgument);

    Status s = EnsureTarget();
    if (!s.IsOk()) return s;
    // RT 背后的纹理句柄在 RT 重建前一直有效，故可先给出，便于失败时 UI 仍有可显示目标。
    out_texture = target_->GetColorTexture();

    // ---- 1. 定位片段：只取**第一条命中的视频轨**（本期不支持多轨合成）----
    const Clip* clip = nullptr;
    for (const Track& track : timeline_->Tracks()) {
        if (track.kind != TrackKind::kVideo || !track.enabled) continue;
        const Clip* hit = timeline_->FindClipAt(track.id, pts);
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
    s = GetProvider(clip->source.asset_id, provider);
    if (!s.IsOk()) return s;

    FrameRequest req;
    req.at = src_time;
    req.policy = SeekPolicy::kExact;  // 预览也要精确：编辑正确性优先于速度
    MediaFrame frame;
    s = provider->AcquireFrame(req, frame, token);
    if (!s.IsOk()) return s;
    if (frame.type != MediaType::kVideo || frame.video.image == nullptr) {
        provider->ReleaseFrame(frame);
        return Status(StatusCode::kDecodeError);
    }
    // 记录实际帧 pts：素材内容静态时像素无法区分「取对了帧」与「复用旧帧」，
    // 这个量是可验证的差异点（单测据此断言渲染帧随时间推进）。
    last_frame_pts_ = frame.video.pts;

    // ---- 4. 零拷贝导入：CVPixelBuffer → 纹理 ----
    s = EnsureImporter();
    if (!s.IsOk()) {
        provider->ReleaseFrame(frame);
        return s;
    }
    TextureHandle tex = nullptr;
    bool cpu_fallback = false;
    s = importer_->Import(frame.video.image, TextureUsage::kSampled, tex, cpu_fallback);
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
    FrameContext ctx;
    ctx.pts = pts;
    ctx.target = target_->Handle();
    BlitClient client(blit_, tex);
    return gfx_->RenderFrame(ctx, target_.get(), client, token);
}

}  // namespace cq
