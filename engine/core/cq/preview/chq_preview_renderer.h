// ChuanqiCut — 预览渲染器（BIND-003 子步骤 4；B0 起渲染路径经 RenderGraph）
//
// 职责：回答「时间线在 pts 这一刻，画面是什么」。
//   B0 之后的链路：ChqGraphAssembler（时间线 + 画布 → 一张 RenderGraph）
//   → ChqRenderEvaluator::Prepare（取帧 + 零拷贝导入，CPU 侧）
//   → ChqIGfxDevice::RenderFrame（回调 evaluator 编码 blit pass，GPU 侧）
//   → 导出 RT 背后的纹理句柄给 UI 层显示。
//
// 为什么要换掉手写路径（红线 #9 / ADR-0034）：导出（B4）必须复用**同一张图**。
// 在此之前预览是一条手写路径，继续往上堆能力（多轨/滤镜/转场）必然逼出第二条
// 渲染路径 —— 本仓库已在「相机滤镜 vs 编辑器特效」上付过一次这个代价（ADR-0014）。
//
// ⚠️ 本类同时实现 ChqIFrameSource：取帧与导入的**跨帧状态**（provider 表、
// MEDIA-024 的展示区间复用）归本类所有，故通过接缝注入给执行器，而不是让执行器
// 复制一份 —— 同一条理由：两套逻辑必然漂移。
//
// ⚠️ 导出的是**中性句柄** `TextureHandle`（opaque 指针），Swift 侧 reinterpret 为
//    MTLTexture。**绝不**走「读回像素 → Swift 再上传」：CPU 往返每帧一次会直接
//    毁掉预览帧率。gfx_metal_internal.h 的 ReadRenderTargetPixels 只该出现在测试里。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常（错误一律 ChqStatus）。
//
// 本期明确**不支持**（不要假装支持，见 TASK-BIND-003 §五）：
//   * 多轨合成 —— 只渲染**第一条命中的视频轨**（B0 起装配器会发 Warn，不再只是
//     一句代码注释）；叠加/转场合成归 RENDER-011（B7）。
//   * 变速 / retime —— MODEL-001 无该字段，时间线时长与素材时长 1:1 映射。
//   （宽高比适配已支持 —— 见 ChqFitMode / ADR-0018；片段级缩放/位移仍归 MODEL-003。）

#ifndef CQ_CORE_PREVIEW_CHQ_PREVIEW_RENDERER_H_
#define CQ_CORE_PREVIEW_CHQ_PREVIEW_RENDERER_H_

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <unordered_map>

#include "cq/base/chq_concurrency.h"  // ChqCancelToken
#include "cq/base/chq_status.h"
#include "cq/base/chq_rational_time.h"            // ChqRationalTime
#include "cq/gfx/chq_gfx_device.h"                // ChqIGfxDevice / ChqIGfxEncoder
#include "cq/platform/chq_gfx.h"                  // ChqIBlitPass（Platform 层，平台原生 shader 实现）
#include "cq/media/chq_asset_registry.h"          // ChqAssetRegistry
#include "cq/media/chq_frame_provider.h"          // ChqFrameProvider
#include "cq/media/chq_frame_provider_factory.h"  // ChqIFrameProviderFactory
#include "cq/model/chq_model_snapshot.h"          // ChqModelSnapshot / ChqIModelSnapshotProvider
#include "cq/model/chq_timeline.h"                // ChqTimeline
#include "cq/platform/chq_common.h"               // TextureHandle / ChqTextureFormat / ChqPlatformPtr
#include "cq/platform/chq_gfx.h"                  // ChqIRenderTarget / ChqINativeImageImporter
#include "cq/preview/chq_preview_frame_source.h"  // ChqIPreviewFrameSource（预览泵的接缝）
#include "cq/render/chq_fit_mode.h"               // ChqFitMode（已下沉到 render 层，供 RenderGraph 共用）
#include "cq/render/chq_frame_source.h"           // ChqIFrameSource（取帧接缝，注入给执行器）
#include "cq/render/chq_graph_assembler.h"        // ChqGraphAssembler
#include "cq/render/chq_render_evaluator.h"       // ChqRenderEvaluator
#include "cq/render/chq_render_graph.h"           // ChqRenderGraph

namespace cq {

// 源帧 → 画布的宽高比适配模式（UIA-014 / ADR-0018）。
// 实现接缝 = 编码器视口：三种模式都是「把全屏 blit 变换到一个矩形」，
// bar 区即清屏色黑（清屏不受视口影响，视口外无写入）。
// ⚠️ 定义已移至 render/chq_fit_mode.h（B0：RenderGraph 与预览共用，避免 render 反向依赖 preview）。

class ChqPreviewRenderer : public ChqIPreviewFrameSource, public ChqIFrameSource {
public:
    struct Config {
        uint32_t width = 1920;
        uint32_t height = 1080;
        ChqTextureFormat format = ChqTextureFormat::kRGBA8;
        ChqFitMode fit_mode = ChqFitMode::kStretch;
    };

    // ---- 单帧各阶段耗时（ns，steady_clock）----
    // 传哲要求「日志与埋点必须先行做扎实」：预览帧率的所有讨论都要有实测数字，
    // 否则就只能靠猜。故在这里把耗时做成渲染器的一等产物，而不是临时插桩。
    //
    // ⚠️ 阶段划分是**诚实**的（不要把猜测当事实）：
    //   acquire_ns —— `ChqFrameProvider::AcquireFrame` 整段：内部含按需 seek + 解码，
    //                 core 侧没有更细的接缝，故**不**拆成 seek/decode（拆了也是编的）。
    //   import_ns  —— `ChqINativeImageImporter::Import`（CVPixelBuffer → 纹理）。
    //   draw_ns    —— `ChqIGfxDevice::RenderFrame`：编码 + 提交 + **等待 GPU 完成**
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
    // 入口加载最近发布的不可变 ChqModelSnapshot（ChqTimeline + ChqAssetRegistry 配对），
    // 与 session 线程的持续变更解耦 —— 渲染期间模型再变，本帧仍用加载到的快照
    // 完整渲染，下帧自然切到新快照（最终一致）。
    ChqPreviewRenderer(ChqIGfxDevice* gfx, ChqIBlitPass* blit, ChqIFrameProviderFactory* providers,
                       ChqIModelSnapshotProvider* snapshot_provider, const Config& cfg);

    ~ChqPreviewRenderer();

    ChqPreviewRenderer(const ChqPreviewRenderer&) = delete;
    ChqPreviewRenderer& operator=(const ChqPreviewRenderer&) = delete;

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
    //      CVMetalTextureCache，两者都不可并发访问。挂上 `ChqPreviewPump` 之后，本方法
    //      **只允许**在泵线程被调用 —— 主线程再调一次就是数据竞争（不是"可能出错"，
    //      是必然出错）。未挂泵时沿用旧约定：单一线程使用。
    ChqStatus RenderFrame(const ChqRationalTime& pts, TextureHandle& out_texture,
                          const ChqCancelToken& token, int32_t seek_policy = 0) override;

    // ---- ChqIFrameSource（取帧接缝，供 RenderGraph 执行器消费）----
    // 内部持有 provider 表与 MEDIA-024 的展示区间复用状态；**不是**每帧新建的纯函数。
    // 线程约定与 RenderFrame 相同（挂泵后只由泵线程调用）。
    ChqStatus Acquire(uint64_t asset_id, const ChqRationalTime& src_time,
                      const ChqAssetRegistry& assets, TextureHandle& out_tex, uint32_t& out_w,
                      uint32_t& out_h, bool* out_reused, uint32_t* out_rotation,
                      const ChqCancelToken& token) override;

    // 重建离屏渲染目标（预览分辨率变化时）。会丢弃当前 RT 与其纹理句柄。
    // 线程约定同上（挂泵后只由泵线程调用，走 `ChqPreviewPump::RequestResize`）。
    ChqStatus Resize(uint32_t width, uint32_t height) override;

    // 宽高比适配模式（UIA-014）。setter 与渲染读（挂泵后在泵线程）分属不同线程，
    // 故内部为 atomic —— 主线程设置、泵线程读取，无竞争。
    void SetFitMode(ChqFitMode mode) {
        fit_mode_.store(static_cast<int>(mode), std::memory_order_relaxed);
    }
    ChqFitMode GetFitMode() const {
        return static_cast<ChqFitMode>(fit_mode_.load(std::memory_order_relaxed));
    }

    ChqIRenderTarget* Target() override { return target_.get(); }

    // ---- P142：当前帧的 seek 策略（RenderFrame 入口写入，Acquire 读取）----
    //
    // 为什么存成员而不是沿 RenderGraph 逐层传参：一次 RenderFrame 内 policy 恒定，
    // 且 RenderFrame 与 Acquire **同在泵线程**（见上方线程约定），不存在并发写。
    // 存成员让 ChqIFrameSource 接口签名不变（少动一处跨模块契约）。
    // 0=kExact（默认）/ 1=kKeyframeBefore / 2=kNearest，取值为 ChqSeekPolicy 底层值。
    int32_t seek_policy_ = 0;

    // MEDIA-023 排障仪器：把内部分段计时暴露给泵（经缓存避免跨线程读 LiveTimings
    // —— timings_ 本身只有泵线程写，此处消费也在泵线程，无竞争）。
    //
    // CORE-010 变更：这两个接口**不再是 Debug-only**。它们是被看门狗消费的
    // 「当前卡在哪一段」，属于可观测性基础设施，Release 没有就等于现场没有。
    const ChqIPreviewFrameSource::StageTimings* DebugLastTimings() const override {
        stage_cache_.acquire_ns = timings_.acquire_ns;
        stage_cache_.import_ns = timings_.import_ns;
        stage_cache_.draw_ns = timings_.draw_ns;
        stage_cache_.total_ns = timings_.total_ns;
        return &stage_cache_;
    }
    const char* DebugStage() const override {
        return debug_stage_.load(std::memory_order_relaxed);
    }
    int64_t DebugStageSinceNanos() const override {
        return debug_stage_since_.load(std::memory_order_relaxed);
    }

    // 上一帧的各阶段耗时（见 Timings 注释）。首帧之前全 0。
    const Timings& LastTimings() const { return timings_; }

    // ---- B0：RenderGraph 装配与执行（预览与导出共用同一装配器）----
    ChqGraphAssembler assembler_;
    ChqRenderGraph graph_;
    ChqRenderEvaluator evaluator_;

    // ---- 上一帧的可观测量（供单测与运行时诊断，不是渲染结果本身）----
    bool LastHitClip() const { return last_hit_clip_; }
    // true = 上一次导入走了 CPU 拷贝退化。预览稳定态应为 false（PALA-011 输出带
    // MetalCompatibility）；持续为 true 说明零拷贝链路断了，属需要排查的降级。
    bool LastImportCpuFallback() const { return last_cpu_fallback_; }
    // 上一帧**请求的**素材内时间戳（对照实际值，可发现 seek 偏移问题）。
    ChqRationalTime LastSourceTime() const { return last_source_time_; }
    // 上一帧**实际取到的**解码帧 pts。素材内容静态时（如彩条）画面看起来一样，
    // 只有这个量能证明「渲染的确实是 t 时刻那一帧」而不是反复复用同一帧。
    ChqRationalTime LastFramePts() const { return last_frame_pts_; }

private:
    ChqStatus EnsureTarget();
    ChqStatus EnsureImporter();
    // 按 asset_id 取（必要时创建并 Open）一个 ChqFrameProvider。
    // 注册同 id 新路径（素材替换）时关闭旧实例重建 —— 旧解码会话不得滞留。
    ChqStatus GetProvider(uint64_t asset_id, const ChqAssetRegistry& assets, ChqFrameProvider*& out);
    // 只清屏（空隙帧 / 渲染失败兜底）。
    ChqStatus ClearTarget(const ChqCancelToken& token);

    ChqIGfxDevice* gfx_ = nullptr;
    ChqIBlitPass* blit_ = nullptr;
    ChqIFrameProviderFactory* providers_ = nullptr;
    ChqIModelSnapshotProvider* snapshots_ = nullptr;
    Config cfg_{};

    ChqPlatformPtr<ChqINativeImageImporter> importer_;
    ChqPlatformPtr<ChqIRenderTarget> target_;

    // asset_id → 已打开的 ChqFrameProvider + 打开时的素材路径。
    // 路径与快照素材表不一致 = 素材被重注册替换 → 重建 provider（关闭旧解码会话）。
    struct ProviderEntry {
        std::unique_ptr<ChqFrameProvider> provider;
        std::string opened_path;
    };
    std::unordered_map<uint64_t, ProviderEntry> providers_by_asset_;

    // 上一帧导入的纹理。ChqINativeImageImporter::Import 返回裸句柄且不接管，
    // 必须由本类显式释放，否则每帧泄漏一张（含其 IOSurface 引用）。
    TextureHandle imported_ = nullptr;

    // MEDIA-024：上一导入帧的展示区间复用判据。src_time 落在
    // [last_import_pts_, +duration) 且素材相同 → 直接重画 imported_（跳过
    // acquire+import），消除「区间内重复请求走慢路径重解 GOP」的尖刺。
    // 纹理独立于 provider 生命周期（IOSurface 锁在纹理上），provider 重建无需失效。
    // ⚠️ 这些状态归本类（不是执行器）：B0 之后取帧由 RenderGraph 执行器经
    //    ChqIFrameSource 接缝回调本类的 Acquire，复用判据仍只有一份。
    bool last_import_valid_ = false;
    uint64_t last_import_asset_ = 0;
    // B0：Acquire 内部的两段耗时（取帧/导入），由 RenderFrame 读回写进 Timings。
    // 为什么不直接用返回值带回：执行器只按节点执行，不该知道预览的计时分段；
    // 而分段本身是预览的可观测性要求（「慢在取帧还是 GPU」决定不同优化动作）。
    int64_t staged_acquire_ns_ = 0;
    int64_t staged_import_ns_ = 0;
    // CORE-010：这两个限流计数器提到 Release —— 它们被 Trace 级的诊断使用，
    // 而 Release 下 CQ_LOG_TRACE_WF 展开为空，if 体会被优化掉；留着成员开销为零。
    int debug_import_logs_ = 0;
    int debug_reuse_logs_ = 0;
    ChqRationalTime last_import_pts_{0, 1};
    ChqRationalTime last_import_dur_{0, 1};
    uint32_t last_import_w_ = 0;
    uint32_t last_import_h_ = 0;
    uint16_t last_import_rotation_ = 0;  // #21：复用判据一并携带旋转角，避免复用帧丢失朝向

    bool last_hit_clip_ = false;
    bool last_cpu_fallback_ = false;
    ChqRationalTime last_source_time_{0, 1};
    ChqRationalTime last_frame_pts_{0, 1};
    Timings timings_{};
    mutable ChqIPreviewFrameSource::StageTimings stage_cache_{};
    // MEDIA-026 看门狗：当前渲染阶段与进入时刻（泵的看门狗线程轮询，超 1s 报告）。
    //
    // CORE-010 变更：提到 Release。开销是每段一次 relaxed atomic store +
    // 一次 steady_clock 读取，相对各段本身的毫秒级耗时可忽略；换来的是 Release
    // 包也能回答「卡在哪一段」——这是本仓库连续两次冻结踩坑的唯一指认手段。
    std::atomic<const char*> debug_stage_{""};
    std::atomic<int64_t> debug_stage_since_{0};
    struct DebugStageGuard {
        std::atomic<const char*>& stage;
        std::atomic<int64_t>& since;
        explicit DebugStageGuard(std::atomic<const char*>& st,
                                 std::atomic<int64_t>& since, const char* name)
            : stage(st), since(since) {
            stage.store(name, std::memory_order_relaxed);
            since.store(static_cast<int64_t>(
                            std::chrono::steady_clock::now().time_since_epoch().count()),
                        std::memory_order_relaxed);
        }
        ~DebugStageGuard() { stage.store("", std::memory_order_relaxed); }
    };
    std::atomic<int> fit_mode_{static_cast<int>(ChqFitMode::kStretch)};  // 见 SetFitMode
};

}  // namespace cq

#endif  // CQ_CORE_PREVIEW_CHQ_PREVIEW_RENDERER_H_
