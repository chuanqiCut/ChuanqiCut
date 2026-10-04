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
//   （宽高比适配已支持 —— 见 FitMode / ADR-0015；片段级缩放/位移仍归 MODEL-003。）

#ifndef CQ_PREVIEW_PREVIEW_RENDERER_H_
#define CQ_PREVIEW_PREVIEW_RENDERER_H_

#include <atomic>
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
#include "cq/model/model_snapshot.h"             // ModelSnapshot / IModelSnapshotProvider
#include "cq/model/timeline.h"                   // Timeline
#include "cq/pal/common.h"                       // TextureHandle / TextureFormat / PalPtr
#include "cq/pal/gfx.h"                          // IRenderTarget / INativeImageImporter
#include "cq/preview/preview_frame_source.h"      // IPreviewFrameSource（预览泵的接缝）

namespace cq {

// 源帧 → 画布的宽高比适配模式（UIA-011 / ADR-0015）。
// 实现接缝 = 编码器视口：三种模式都是「把全屏 blit 变换到一个矩形」，
// bar 区即清屏色黑（清屏不受视口影响，视口外无写入）。
enum class FitMode : int32_t {
    kStretch = 0,  // 拉伸铺满（引入 FitMode 前的既有行为，默认值）
    kContain = 1,  // 内切居中：letterbox / pillarbox，不裁内容
    kCover = 2,    // 外接居中：裁剪铺满，不留 bar
};

class PreviewRenderer : public IPreviewFrameSource {
public:
    struct Config {
        uint32_t width = 1920;
        uint32_t height = 1080;
        TextureFormat format = TextureFormat::kRGBA8;
        FitMode fit_mode = FitMode::kStretch;
    };

    // ---- 单帧各阶段耗时（ns，steady_clock）----
    // 传哲要求「日志与埋点必须先行做扎实」：预览帧率的所有讨论都要有实测数字，
    // 否则就只能靠猜。故在这里把耗时做成渲染器的一等产物，而不是临时插桩。
    //
    // ⚠️ 阶段划分是**诚实**的（不要把猜测当事实）：
    //   acquire_ns —— `FrameProvider::AcquireFrame` 整段：内部含按需 seek + 解码，
    //                 core 侧没有更细的接缝，故**不**拆成 seek/decode（拆了也是编的）。
    //   import_ns  —— `INativeImageImporter::Import`（CVPixelBuffer → 纹理）。
    //   draw_ns    —— `IGfxDevice::RenderFrame`：编码 + 提交 + **等待 GPU 完成**
    //                 （gfx_device.cpp 结尾是 WaitUntilCompleted，故含 GPU 执行时间）。
    //   total_ns   —— 入口到返回的全部（与上面三段之差 = 快照加载等杂项）。
    struct Timings {
        int64_t acquire_ns = 0;
        int64_t import_ns = 0;
        int64_t draw_ns = 0;
        int64_t total_ns = 0;
    };

    // 依赖全部为**注入的非拥有指针**，生命周期由装配方持有（本类不 delete 它们）。
    //
    // snapshot_provider（UIA-009 子步骤 2）：渲染输入的唯一来源。每次 RenderFrame
    // 入口加载最近发布的不可变 ModelSnapshot（Timeline + AssetRegistry 配对），
    // 与 session 线程的持续变更解耦 —— 渲染期间模型再变，本帧仍用加载到的快照
    // 完整渲染，下帧自然切到新快照（最终一致）。
    PreviewRenderer(IGfxDevice* gfx, IBlitPass* blit, IFrameProviderFactory* providers,
                    IModelSnapshotProvider* snapshot_provider, const Config& cfg);

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
    //
    //   ⚠️ 线程归属（UIA-010 子步骤 5 起的**硬约束**）：本方法会触碰解码会话与
    //      CVMetalTextureCache，两者都不可并发访问。挂上 `PreviewPump` 之后，本方法
    //      **只允许**在泵线程被调用 —— 主线程再调一次就是数据竞争（不是"可能出错"，
    //      是必然出错）。未挂泵时沿用旧约定：单一线程使用。
    Status RenderFrame(const RationalTime& pts, TextureHandle& out_texture,
                       const CancelToken& token) override;

    // 重建离屏渲染目标（预览分辨率变化时）。会丢弃当前 RT 与其纹理句柄。
    // 线程约定同上（挂泵后只由泵线程调用，走 `PreviewPump::RequestResize`）。
    Status Resize(uint32_t width, uint32_t height) override;

    // 宽高比适配模式（UIA-011）。setter 与渲染读（挂泵后在泵线程）分属不同线程，
    // 故内部为 atomic —— 主线程设置、泵线程读取，无竞争。
    void SetFitMode(FitMode mode) {
        fit_mode_.store(static_cast<int>(mode), std::memory_order_relaxed);
    }
    FitMode GetFitMode() const {
        return static_cast<FitMode>(fit_mode_.load(std::memory_order_relaxed));
    }

    IRenderTarget* Target() override { return target_.get(); }

    // 上一帧的各阶段耗时（见 Timings 注释）。首帧之前全 0。
    const Timings& LastTimings() const { return timings_; }

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
    // 注册同 id 新路径（素材替换）时关闭旧实例重建 —— 旧解码会话不得滞留。
    Status GetProvider(uint64_t asset_id, const AssetRegistry& assets, FrameProvider*& out);
    // 只清屏（空隙帧 / 渲染失败兜底）。
    Status ClearTarget(const CancelToken& token);

    IGfxDevice* gfx_ = nullptr;
    IBlitPass* blit_ = nullptr;
    IFrameProviderFactory* providers_ = nullptr;
    IModelSnapshotProvider* snapshots_ = nullptr;
    Config cfg_{};

    PalPtr<INativeImageImporter> importer_;
    PalPtr<IRenderTarget> target_;

    // asset_id → 已打开的 FrameProvider + 打开时的素材路径。
    // 路径与快照素材表不一致 = 素材被重注册替换 → 重建 provider（关闭旧解码会话）。
    struct ProviderEntry {
        std::unique_ptr<FrameProvider> provider;
        std::string opened_path;
    };
    std::unordered_map<uint64_t, ProviderEntry> providers_by_asset_;

    // 上一帧导入的纹理。INativeImageImporter::Import 返回裸句柄且不接管，
    // 必须由本类显式释放，否则每帧泄漏一张（含其 IOSurface 引用）。
    TextureHandle imported_ = nullptr;

    bool last_hit_clip_ = false;
    bool last_cpu_fallback_ = false;
    RationalTime last_source_time_{0, 1};
    RationalTime last_frame_pts_{0, 1};
    Timings timings_{};
    std::atomic<int> fit_mode_{static_cast<int>(FitMode::kStretch)};  // 见 SetFitMode
};

}  // namespace cq

#endif  // CQ_PREVIEW_PREVIEW_RENDERER_H_
