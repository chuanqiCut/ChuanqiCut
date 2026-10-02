// ChuanqiCut — 预览的 C ABI 实现（BIND-003 子步骤 5）
//
// ⚠️ 为什么单独一个 TU（而不是并进 core/src/cq_sdk.cpp）：
//   本文件是 core 中**第一个调用 PAL 工厂**的翻译单元（CreateGraphicsDevice /
//   CreateBlitPass / CreateFrameProvider）。静态库按 archive member 粒度拉符号，
//   只有真正引用了本 TU 符号的目标才会把它链进来 —— 因此「不使用预览能力的目标」
//   （例如尚无 PAL 后端的 Android 构建）不会因为 core 引用了 PAL 符号而链接失败。
//   若把这段代码并入 cq_sdk.cpp，则任何用到 session ABI 的目标都会连带拉入
//   PAL 依赖，把「不用预览就不该有依赖」这条隔离彻底破坏。
//
// 内核禁用异常（ARCH-001）：分配一律 `new (std::nothrow)`，失败返回 NULL。

#include "cq/cq_sdk.h"

#include <new>
#include <string>

#include "cq/base/concurrency.h"
#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/gfx/gfx_device.h"
#include "cq/media/asset_registry.h"
#include "cq/media/pal_frame_provider.h"
#include "cq/model/timeline.h"
#include "cq/pal/gfx.h"
#include "cq/preview/preview_renderer.h"

namespace {

int32_t CodeOf(cq::Status st) { return static_cast<int32_t>(st.code); }

int32_t CodeOfEnum(cq::StatusCode code) { return static_cast<int32_t>(code); }

}  // namespace

// CQPreview 的真实定义。
// ⚠️ 必须在**全局**命名空间（放进匿名 namespace 会与头文件的 typedef 产生命名歧义，
//    与 CQSession 同一坑）。
// ⚠️ 成员顺序即初始化顺序：PreviewRenderer 持有的是**非拥有指针**，指向同结构体内
//    的其它成员，故它必须在最后构造（用 unique_ptr 控制），且本结构不可被移动。
struct CQPreview {
    cq::IGfxDevice* gfx = nullptr;              // 拥有（CreateGfxDevice 内部 new）
    cq::PalPtr<cq::IBlitPass> blit;             // 拥有
    cq::PalFrameProviderFactory provider_factory;
    cq::Timeline timeline;
    cq::AssetRegistry assets;
    std::unique_ptr<cq::PreviewRenderer> renderer;
};

CQPreview* cq_preview_create(uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) return nullptr;

    CQPreview* p = new (std::nothrow) CQPreview();
    if (p == nullptr) return nullptr;

    // PAL：图形设备 → GFX 门面（GFX 接管 PAL 设备所有权）
    cq::GraphicsDeviceDesc dd;
    dd.prefer_low_power = false;
    cq::PalPtr<cq::IGraphicsDevice> pal;
    if (!cq::CreateGraphicsDevice(dd, pal).IsOk() || !pal) {
        cq_preview_destroy(p);
        return nullptr;
    }
    cq::IGfxDevice* gfx = nullptr;
    if (!cq::CreateGfxDevice(pal, gfx).IsOk() || gfx == nullptr) {
        // pal 已被 CreateGfxDevice 接管（成功时）；失败路径下它仍持有所有权，
        // 随本函数栈上 PalPtr 析构自动释放。
        cq_preview_destroy(p);
        return nullptr;
    }
    p->gfx = gfx;

    // PAL：全屏拷贝 pass（平台原生 shader）。缺失即预览不可用 —— 如实返回 NULL。
    if (!cq::CreateBlitPass(gfx->PalDevice(), cq::TextureFormat::kRGBA8, p->blit).IsOk() ||
        !p->blit) {
        cq_preview_destroy(p);
        return nullptr;
    }

    cq::PreviewRenderer::Config cfg;
    cfg.width = width;
    cfg.height = height;
    cfg.format = cq::TextureFormat::kRGBA8;
    p->renderer.reset(new (std::nothrow) cq::PreviewRenderer(
        gfx, p->blit.get(), &p->provider_factory, &p->timeline, &p->assets, cfg));
    if (!p->renderer) {
        cq_preview_destroy(p);
        return nullptr;
    }
    return p;
}

void cq_preview_destroy(CQPreview* preview) {
    if (preview == nullptr) return;
    // 顺序要紧：renderer 持有指向本结构体其它成员的非拥有指针，必须先销毁。
    preview->renderer.reset();
    preview->blit.reset();
    if (preview->gfx != nullptr) {
        delete preview->gfx;
        preview->gfx = nullptr;
    }
    delete preview;
}

int32_t cq_preview_register_asset(CQPreview* preview, uint64_t asset_id, const char* path) {
    if (preview == nullptr || path == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    return CodeOf(preview->assets.Register(asset_id, std::string(path)));
}

int32_t cq_preview_add_clip(CQPreview* preview, uint64_t track_id, uint64_t asset_id,
                            int64_t start_value, int32_t start_timescale,
                            int64_t duration_value, int32_t duration_timescale,
                            int64_t source_in_value, int32_t source_in_timescale) {
    if (preview == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    if (start_timescale <= 0 || duration_timescale <= 0 || source_in_timescale <= 0) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }

    // 轨道不存在则自动创建（id 由内核分配，**不保证**等于传入的 track_id ——
    // Timeline 的 id 是单调递增的自增序列，不支持指定）。
    if (preview->timeline.FindTrack(track_id) == nullptr) {
        uint64_t new_id = 0;
        cq::Status s = preview->timeline.AddTrack(cq::TrackKind::kVideo, new_id);
        if (!s.IsOk()) return CodeOf(s);
        track_id = new_id;
    }

    cq::Clip clip;
    clip.kind = cq::ClipKind::kVideo;
    clip.source.asset_id = asset_id;
    clip.source.source_in = cq::RationalTime{source_in_value, source_in_timescale};
    clip.source.source_duration = cq::RationalTime{duration_value, duration_timescale};
    clip.start = cq::RationalTime{start_value, start_timescale};
    clip.duration = cq::RationalTime{duration_value, duration_timescale};

    uint64_t clip_id = 0;
    return CodeOf(preview->timeline.InsertClip(track_id, clip, clip_id));
}

int32_t cq_preview_render_frame(CQPreview* preview, int64_t pts_value, int32_t pts_timescale,
                                void** out_texture) {
    if (preview == nullptr || preview->renderer == nullptr || out_texture == nullptr) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    *out_texture = nullptr;
    if (pts_timescale <= 0) return CodeOfEnum(cq::StatusCode::kInvalidArgument);

    cq::TextureHandle tex = nullptr;
    cq::CancelToken token;
    cq::Status s = preview->renderer->RenderFrame(
        cq::RationalTime{pts_value, pts_timescale}, tex, token);
    if (tex != nullptr) *out_texture = static_cast<void*>(tex);
    return CodeOf(s);
}

int32_t cq_preview_resize(CQPreview* preview, uint32_t width, uint32_t height) {
    if (preview == nullptr || preview->renderer == nullptr) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    return CodeOf(preview->renderer->Resize(width, height));
}

int32_t cq_preview_last_hit_clip(const CQPreview* preview) {
    if (preview == nullptr || preview->renderer == nullptr) return 0;
    return preview->renderer->LastHitClip() ? 1 : 0;
}

int32_t cq_preview_last_cpu_fallback(const CQPreview* preview) {
    if (preview == nullptr || preview->renderer == nullptr) return 0;
    return preview->renderer->LastImportCpuFallback() ? 1 : 0;
}

int32_t cq_preview_last_frame_pts(const CQPreview* preview, int64_t* out_value,
                                  int32_t* out_timescale) {
    if (preview == nullptr || preview->renderer == nullptr) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    const cq::RationalTime t = preview->renderer->LastFramePts();
    if (out_value != nullptr) *out_value = t.value;
    if (out_timescale != nullptr) *out_timescale = t.timescale;
    return CodeOfEnum(cq::StatusCode::kOk);
}
