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

#include <memory>
#include <new>
#include <string>
#include <utility>

#include "cq/base/concurrency.h"
#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/gfx/gfx_device.h"
#include "cq/media/pal_frame_provider.h"
#include "cq/model/model_snapshot.h"
#include "cq/pal/gfx.h"
#include "cq/preview/preview_renderer.h"
#include "../cq_session_impl.h"

namespace {

int32_t CodeOf(cq::Status st) { return static_cast<int32_t>(st.code); }

int32_t CodeOfEnum(cq::StatusCode code) { return static_cast<int32_t>(code); }

}  // namespace

// CQPreview 的真实定义。
// ⚠️ 必须在**全局**命名空间（放进匿名 namespace 会与头文件的 typedef 产生命名歧义，
//    与 CQSession 同一坑）。
// ⚠️ 成员顺序即初始化顺序：PreviewRenderer 持有的是**非拥有指针**，指向同结构体内
//    的其它成员，故它必须在最后构造（用 unique_ptr 控制），且本结构不可被移动。
//
// UIA-009 子步骤 2（2026-10-03）收口：本地 Timeline/AssetRegistry **退役**，
// 渲染输入改为 session 发布的不可变模型快照（每次 RenderFrame 入口加载，
// 与 session 线程的持续变更解耦）。时间线/素材的唯一真源是 CQSession。
// ⚠️ CQPreview **不拥有** CQSession —— 调用方保证 session 先活后死
//    （Swift 侧 Previewer 强持有 Session，顺序由对象图保证）。
struct CQPreview {
    cq::IGfxDevice* gfx = nullptr;              // 拥有（CreateGfxDevice 内部 new）
    cq::PalPtr<cq::IBlitPass> blit;             // 拥有
    cq::PalFrameProviderFactory provider_factory;
    cq::EditorSession* session = nullptr;       // 非拥有（见上）
    std::unique_ptr<cq::IModelSnapshotProvider> snapshot_provider;  // 拥有
    std::unique_ptr<cq::PreviewRenderer> renderer;
};

namespace {

// 把 EditorSession 的已发布快照适配成渲染器的输入。
class SessionSnapshotProvider final : public cq::IModelSnapshotProvider {
public:
    explicit SessionSnapshotProvider(cq::EditorSession* session) : session_(session) {}
    std::shared_ptr<const cq::ModelSnapshot> CurrentSnapshot() const override {
        return session_->CurrentModelSnapshot();
    }

private:
    cq::EditorSession* session_;
};

}  // namespace

CQPreview* cq_preview_create(CQSession* session, uint32_t width, uint32_t height) {
    if (session == nullptr || width == 0 || height == 0) return nullptr;

    CQPreview* p = new (std::nothrow) CQPreview();
    if (p == nullptr) return nullptr;
    p->session = &session->impl;

    // 注入自定义 ISessionState（无内建模型）时无可渲染输入 —— 如实返回 NULL。
    if (p->session->CurrentModelSnapshot() == nullptr) {
        cq_preview_destroy(p);
        return nullptr;
    }

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

    p->snapshot_provider.reset(new (std::nothrow) SessionSnapshotProvider(p->session));
    if (!p->snapshot_provider) {
        cq_preview_destroy(p);
        return nullptr;
    }

    cq::PreviewRenderer::Config cfg;
    cfg.width = width;
    cfg.height = height;
    cfg.format = cq::TextureFormat::kRGBA8;
    p->renderer.reset(new (std::nothrow) cq::PreviewRenderer(
        gfx, p->blit.get(), &p->provider_factory, p->snapshot_provider.get(), cfg));
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
