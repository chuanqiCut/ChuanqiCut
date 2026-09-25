// ChuanqiCut — GFX 抽象层（GFX-001，位于 PAL 之上）
//
// ┌────────────────────────────────────────────────────────────────────────┐
// │ 本文件与 pal/gfx.h 的关系（架构边界，务必先读）                          │
// ├────────────────────────────────────────────────────────────────────────┤
// │ PAL 的 `IGraphicsDevice` 及其 11 个兄弟接口（pal/gfx.h，CORE-006 冻结）  │
// │ 是**平台能力 HAL**：逐概念 1:1 映射到 Metal / Vulkan / GLES，由各平台后端 │
// │ （PALA-001 Metal / PALD-001 GLES / PALD-002 Vulkan）直接实现。这是平台   │
// │ 原生 API 进入代码库的**唯一入口**，越薄越好（ARCH-003 §2.1/§2.3）。      │
// │                                                                        │
// │ 本文件（gfx/，GFX-001）是**RenderGraph 之上的编排层**：不重新定义那 12   │
// │ 个 PAL 概念，而是持有一个 PAL 设备并向 RenderGraph 暴露“渲染编排”API。   │
// │ 把“池化 / 预算 / 帧执行 / 导入编排”这类**跨平台**逻辑放在此处，避免每个   │
// │ 平台后端各自重复实现（ARCH-003 §2.3 硬约束 2：显存分配不隐藏，TexturePool │
// │ 在 core 层统一池化，后端只负责真实分配）。                               │
// │                                                                        │
// │ RenderGraph（RENDER-001）只依赖本层的 `IGfxDevice` / `IGfxEncoder` /     │
// │ `FrameContext`，**不直接依赖 PAL 类型**（除句柄外）——这是分层的关键。    │
// └────────────────────────────────────────────────────────────────────────┘
//
// 12 概念映射（对齐 ARCH-003 §2.2 概念映射表，GFX 层如何呈现每个 PAL 概念）：
//   PAL 概念 (pal/gfx.h)            │ GFX 层呈现 (本文件)
//   ────────────────────────────────┼──────────────────────────────────────────
//   Device        IGraphicsDevice   │ IGfxDevice::PalDevice() 持有并复用 PAL 设备
//   CommandQueue  ICommandQueue     │ 由 IGfxDevice 在 RenderFrame 内隐式管理
//   CommandBuffer ICommandBuffer    │ 同上（帧执行 seam 不向 RenderGraph 暴露）
//   Encoder       ICommandEncoder   │ IGfxEncoder（RenderNode 只绑定到此，不碰 PAL）
//   Texture       ITexture          │ IGfxDevice::AcquireTexture（经 ITexturePool 池化）
//   Buffer        IBuffer           │ 经 PAL 创建后由 RenderNode 直接绑定
//   RenderTarget  IRenderTarget     │ IGfxDevice::CreateRenderTarget（1:1 复用）
//   Pipeline      IPipeline         │ IGfxDevice::CreatePipeline（委托 PAL）
//   ShaderModule  IShaderModule     │ IGfxDevice::CreateShaderModule（委托 PAL）
//   Sampler       ISampler          │ IGfxDevice::CreateSampler（委托 PAL）
//   Fence         IFence            │ 帧执行 seam 内 WaitFence，不向 RenderGraph 暴露
//   ExternalImage INativeImageImporter │ IGfxDevice::CreateNativeImageImporter（GFX-003 接入点）
//
// 硬约束（与 CORE-006 一致）：
//   * 零平台类型：本文件只使用 base 层 + PAL 的 opaque 指针句柄，绝不出现任何
//     Metal/Vulkan/GLES/AVFoundation 专有类型，也不 include 任何平台头。
//   * 零 FFmpeg 类型：不出现 AV* 类型、不 include 任何 ffmpeg 头。
//   * 统一 base 类型：时间用 RationalTime、错误用 Status、长任务接受 CancelToken。
//   * 内核禁用异常：无 throw；错误一律 Status 传播。
//
// 本任务只定义接口，不实现（实现由 RENDER-001 / GFX-002 阶段在 core/src/gfx 落地）。

#ifndef CQ_GFX_DEVICE_H_
#define CQ_GFX_DEVICE_H_

#include <cstddef>
#include <cstdint>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/status.h"       // Status / StatusCode
#include "cq/base/time.h"         // RationalTime
#include "cq/pal/common.h"        // opaque 句柄、IPalResource、PalPtr、平台无关枚举
#include "cq/pal/gfx.h"           // PAL IGraphicsDevice 及其 12 概念（本层之下）

namespace cq {

// ===========================================================================
// 1. 帧上下文（每帧交给 RenderNode::evaluate 的入参，ARCH-003 §6）
// ===========================================================================
// RenderGraph 的节点在 evaluate 时拿到本结构，据此推导视图变换、采样窗口等，
// 不在此耦合具体 RenderGraph 类型（避免 GFX 反向依赖 RENDER 层）。
struct FrameContext {
    RationalTime pts;  // 该帧在项目时间轴上的位置（RationalTime 网格，timescale=120000）
    RenderTargetHandle target = nullptr;  // 当前 pass 输出目标（PAL 资源句柄）
};

// ===========================================================================
// 2. IGfxEncoder — 渲染编码器抽象（RenderNode 只绑定到此）
// ===========================================================================
// 与 PAL ICommandEncoder 方法一一对应，但位于 GFX 层。GFX 后端（未来 core 实现）
// 把对 IGfxEncoder 的调用翻译到 PAL ICommandEncoder。这样 RenderNode（RENDER-001）
// 不碰 PAL 编码器类型，保持 RenderGraph 平台无关。
class IGfxEncoder : public IPalResource {
public:
    virtual void SetPipeline(PipelineHandle pipeline) = 0;
    virtual void SetVertexBuffer(BufferHandle buffer, uint32_t slot) = 0;
    virtual void SetTexture(TextureHandle texture, uint32_t binding) = 0;
    virtual void SetSampler(SamplerHandle sampler, uint32_t binding) = 0;
    virtual void Draw(uint32_t vertex_count) = 0;
    virtual void DrawIndexed(uint32_t index_count) = 0;
    virtual void End() = 0;
};

// ===========================================================================
// 3. IFrameEncoderClient — 帧编码回调 seam（RenderGraph 实现，GFX 驱动）
// ===========================================================================
// 为避免 GFX 反向依赖 RENDER 层（RenderGraph 类型尚未定义），帧执行采用回调 seam：
// RenderGraph 实现本接口，GFX 后端在「开编码器 → 调用 Encode → 提交」之间回调 Encode，
// 由 RenderGraph 填充命令。RenderGraph 全程只见 IGfxEncoder（GFX 类型）。
class IFrameEncoderClient {
public:
    virtual ~IFrameEncoderClient() = default;

    // 在给定 ctx 下把本帧命令编码进 encoder。长任务（编码期间可能触发的 GPU 等待）
    // 接受 token；取消应返回 kCancelled（非错误）。
    virtual Status Encode(IGfxEncoder& encoder, const FrameContext& ctx,
                          const CancelToken& token) = 0;
};

// ===========================================================================
// 4. ITexturePool — 纹理池抽象（GFX-002 实现；GFX-001 仅定义接口位置）
// ===========================================================================
// 池化 + 预算控制是跨平台 core 逻辑（ARCH-003 §2.3 硬约束 2）。GFX-001 声明本接口，
// IGfxDevice 取纹理时经此池；具体 LRU / 预算记账（接 CORE-004 TextureBudget）由 GFX-002
// 在 core/src/gfx/pool.* 实现。池满且超预算时 Acquire 返回 kResourceExhausted(5000)，
// 调用方据此降级（如降预览分辨率）。
class ITexturePool {
public:
    virtual ~ITexturePool() = default;

    // 从池取一张符合 desc 的纹理；池命中则复用，未命中则经 PAL 真实分配并登记预算。
    // 任一预算维度（字节/张数）超限返回 kResourceExhausted 且不分配。
    virtual Status Acquire(const TextureDesc& desc, PalPtr<ITexture>& out) = 0;

    // 归还（池可复用，不立即释放底层平台资源）。
    virtual void Release(ITexture* tex) = 0;

    // 当前预算占用（对接 TextureBudget::UsedBytes / UsedCount，供监控与降级决策）。
    virtual int64_t UsedBytes() const = 0;
    virtual int32_t UsedCount() const = 0;
};

// ===========================================================================
// 5. IGfxDevice — 渲染后端门面（GFX-001 核心，位于 PAL 之上）
// ===========================================================================
// RenderGraph 消费的唯一 GFX 类型。持有一个 PAL 设备，向上提供：
//   * 受池管理的纹理取还（GFX-002 接入点）
//   * 管线 / 着色器 / 采样器创建（委托 PAL 设备）
//   * 原生图像导入（GFX-003 接入点，委托 PAL CreateNativeImageImporter）
//   * 帧执行（把 RenderGraph 编码进 PAL 命令缓冲并提交，封装 CommandQueue/Buffer 生命周期）
// 默认实现为跨平台 core 代码（RENDER-001 / GFX-002 阶段落地），本任务只定义接口。
class IGfxDevice {
public:
    virtual ~IGfxDevice() = default;

    // 底层 PAL 设备（高级用法 / 平台特化 shader 直接走 PAL；日常 RenderGraph 不需要）。
    virtual IGraphicsDevice* PalDevice() = 0;

    // 渲染目标（复用 PAL 概念，1:1 映射表 RenderTarget）。
    virtual Status CreateRenderTarget(const RenderTargetDesc& desc,
                                      PalPtr<IRenderTarget>& out) = 0;

    // 受池管理的纹理（GFX-002 接入点）。未注入 ITexturePool 时直接走 PAL CreateTexture。
    virtual Status AcquireTexture(const TextureDesc& desc, PalPtr<ITexture>& out) = 0;
    virtual void ReleaseTexture(ITexture* tex) = 0;

    // 着色器 / 管线 / 采样器（委托 PAL）。GPU 内存字节数由 PAL ITexture::GetMemoryBytes
    // 暴露，供 ITexturePool 预算记账（不隐藏显存分配）。
    virtual Status CreateShaderModule(const ShaderModuleDesc& desc,
                                      PalPtr<IShaderModule>& out) = 0;
    virtual Status CreatePipeline(const PipelineDesc& desc, PalPtr<IPipeline>& out) = 0;
    virtual Status CreateSampler(const SamplerDesc& desc, PalPtr<ISampler>& out) = 0;

    // 原生图像导入（GFX-003 接入点）。委托 PAL 设备 CreateNativeImageImporter，
    // 导入出的纹理属于本设备上下文（Metal/Vulkan 要求，见 PAL 契约 §5.3）。
    // 失败退化为 CPU 拷贝的语义在 PAL INativeImageImporter::Import 内表达（out_cpu_fallback）。
    virtual Status CreateNativeImageImporter(PalPtr<INativeImageImporter>& out) = 0;

    // 执行一帧（flush 模式，预览主线程用）：内部 CreateCommandBuffer/Encoder、调用
    // client.Encode 填充命令、提交并等待完成。长任务接受 CancelToken；取消返回 kCancelled。
    // 此 seam 封装了 PAL CommandQueue/CommandBuffer/Fence 生命周期，RenderGraph 不感知。
    virtual Status RenderFrame(const FrameContext& ctx, IRenderTarget* target,
                               IFrameEncoderClient& client, const CancelToken& token) = 0;

    // 注入纹理池（GFX-002）。不注入时 AcquireTexture 退化为 PAL 直分配。
    virtual void SetTexturePool(ITexturePool* pool) = 0;
};

// 工厂签名（实现由 RENDER-001 / GFX-002 阶段的 core/src/gfx 提供，本任务不实现）：
// 用已构造的 PAL 设备构造 GFX 门面。out 为跨平台对象，由调用方以 unique_ptr 等持有。
Status CreateGfxDevice(PalPtr<IGraphicsDevice>& pal_device, IGfxDevice*& out_device);

}  // namespace cq

#endif  // CQ_GFX_DEVICE_H_
