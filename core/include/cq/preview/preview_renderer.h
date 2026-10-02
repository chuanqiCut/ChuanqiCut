// ChuanqiCut — 预览渲染器（BIND-003 子步骤 4）
//
// 职责：回答「时间线在 pts 这一刻，画面是什么」。
//   Timeline（哪个片段） + AssetRegistry（片段指向哪个文件） + FrameProvider（取帧）
//   + 零拷贝导入（CVPixelBuffer → 纹理） + IBlitPass（画到离屏 RT）
//   → 导出 RT 背后的纹理句柄给 UI 层显示。
//
// ⚠️ 导出的是**中性句柄** `TextureHandle`（opaque 指针），Swift 侧 reinterpret 为
//    MTLTexture。**绝不**走「读回像素 → Swift 再上传」：CPU 往返每帧一次会直接
//    毁掉预览帧率。gfx_metal_internal.h 的 ReadRenderTargetPixels 只该出现在测试里。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常（错误一律 Status）。
//
// 本期明确**不支持**（不要假装支持，见 TASK-BIND-003 §五）：
//   * 多轨合成 —— 只渲染**第一条命中的视频轨**，叠加/转场合成等 RenderGraph
//     （RENDER-001）落地后再补。
//   * 变速 / retime —— MODEL-001 无该字段，时间线时长与素材时长 1:1 映射。
//   * 宽高比适配 —— 当前是「拉伸铺满」，letterbox/fit 模式待 UI 需求明确后加。

#ifndef CQ_PREVIEW_PREVIEW_RENDERER_H_
#define CQ_PREVIEW_PREVIEW_RENDERER_H_

#include <cstdint>
#include <memory>
#include <unordered_map>

#include "cq/base/concurrency.h"                 // CancelToken
#include "cq/base/status.h"
#include "cq/base/time.h"                        // RationalTime
#include "cq/gfx/gfx_device.h"                   // IGfxDevice / IGfxEncoder
#include "cq/pal/gfx.h"                          // IBlitPass（PAL 层，平台原生 shader 实现）
#include "cq/media/asset_registry.h"             // AssetRegistry
#include "cq/media/frame_provider.h"             // FrameProvider
#include "cq/media/frame_provider_factory.h"     // IFrameProviderFactory
#include "cq/model/timeline.h"                   // Timeline
#include "cq/pal/common.h"                       // TextureHandle / TextureFormat / PalPtr
#include "cq/pal/gfx.h"                          // IRenderTarget / INativeImageImporter

namespace cq {

class PreviewRenderer {
public:
    struct Config {
        uint32_t width = 1920;
        uint32_t height = 1080;
        TextureFormat format = TextureFormat::kRGBA8;
    };

    // 依赖全部为**注入的非拥有指针**，生命周期由装配方持有（本类不 delete 它们）。
    PreviewRenderer(IGfxDevice* gfx, IBlitPass* blit, IFrameProviderFactory* providers,
                    const Timeline* timeline, const AssetRegistry* assets, const Config& cfg);

    ~PreviewRenderer();

    PreviewRenderer(const PreviewRenderer&) = delete;
    PreviewRenderer& operator=(const PreviewRenderer&) = delete;

    // 渲染 pts 处一帧到离屏 RT。
    //   out_texture = RT 背后的纹理句柄（中性句柄，UI 侧 reinterpret）。
    //   返回值：
    //     kOk                 —— 命中片段并完成渲染
    //     kIoNotFound         —— pts 处是空隙（无片段覆盖）；已清屏为黑，out_texture 仍有效
    //     kInvalidArgument    —— 命中了片段但 asset_id 未注册（素材表缺失）
    //     其它                 —— 解码/导入/渲染失败的原样透传
    //   ⚠️ 空隙返回 kIoNotFound 而非伪造 kOk：调用方需要能区分「黑帧」与「渲染失败」。
    Status RenderFrame(const RationalTime& pts, TextureHandle& out_texture,
                       const CancelToken& token);

    // 重建离屏渲染目标（预览分辨率变化时）。会丢弃当前 RT 与其纹理句柄。
    Status Resize(uint32_t width, uint32_t height);

    IRenderTarget* Target() { return target_.get(); }

    // ---- 上一帧的可观测量（供单测与运行时诊断，不是渲染结果本身）----
    bool LastHitClip() const { return last_hit_clip_; }
    // true = 上一次导入走了 CPU 拷贝退化。预览稳定态应为 false（PALA-011 输出带
    // MetalCompatibility）；持续为 true 说明零拷贝链路断了，属需要排查的降级。
    bool LastImportCpuFallback() const { return last_cpu_fallback_; }
    // 上一帧**请求的**素材内时间戳（对照实际值，可发现 seek 偏移问题）。
    RationalTime LastSourceTime() const { return last_source_time_; }
    // 上一帧**实际取到的**解码帧 pts。素材内容静态时（如彩条）画面看起来一样，
    // 只有这个量能证明「渲染的确实是 t 时刻那一帧」而不是反复复用同一帧。
    RationalTime LastFramePts() const { return last_frame_pts_; }

private:
    Status EnsureTarget();
    Status EnsureImporter();
    // 按 asset_id 取（必要时创建并 Open）一个 FrameProvider。
    Status GetProvider(uint64_t asset_id, FrameProvider*& out);
    // 只清屏（空隙帧 / 渲染失败兜底）。
    Status ClearTarget(const CancelToken& token);

    IGfxDevice* gfx_ = nullptr;
    IBlitPass* blit_ = nullptr;
    IFrameProviderFactory* providers_ = nullptr;
    const Timeline* timeline_ = nullptr;
    const AssetRegistry* assets_ = nullptr;
    Config cfg_{};

    PalPtr<INativeImageImporter> importer_;
    PalPtr<IRenderTarget> target_;

    // asset_id → 已打开的 FrameProvider。素材被 Unregister 后这里不会自动清理——
    // 本期素材表只增不删（BIND-003 子步骤 1 的 Clear() 由上层主动调用时才需同步）。
    std::unordered_map<uint64_t, std::unique_ptr<FrameProvider>> providers_by_asset_;

    // 上一帧导入的纹理。INativeImageImporter::Import 返回裸句柄且不接管，
    // 必须由本类显式释放，否则每帧泄漏一张（含其 IOSurface 引用）。
    TextureHandle imported_ = nullptr;

    bool last_hit_clip_ = false;
    bool last_cpu_fallback_ = false;
    RationalTime last_source_time_{0, 1};
    RationalTime last_frame_pts_{0, 1};
};

}  // namespace cq

#endif  // CQ_PREVIEW_PREVIEW_RENDERER_H_
