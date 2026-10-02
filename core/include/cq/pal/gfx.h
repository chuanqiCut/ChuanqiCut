// ChuanqiCut — PAL GFX 抽象接口（CORE-006 / GFX-001 / GFX-003）
//
// 薄 GFX HAL，对齐 ARCH-003 §2.2 概念映射表（12 概念）：
//   Device / CommandQueue / CommandBuffer / Encoder / Texture / Buffer /
//   RenderTarget / Pipeline / ShaderModule / Sampler / Fence / ExternalImage。
//
// 设计硬约束（ARCH-003 §2.3 / ADR-0002）：
//   1. 不抽象同步语义的细粒度差异：只提供 wait/signal(fence)。
//   2. 不隐藏显存分配：TexturePool 在 core 层做统一池化与预算（CORE-004 的
//      TextureBudget），后端只负责真实分配；ITexture::GetMemoryBytes() 暴露字节数供记账。
//   3. 平台特化只存在于 Platform-Native shader 层（pal/<platform>/shaders/），
//      不泄漏到 core。ShaderModule 既可来自 Portable 层 SPIR-V，也可来自平台原生源。
//
// 红线：零平台类型（句柄均为 common.h 的 opaque 指针）、零 FFmpeg 类型。

#ifndef CQ_PAL_GFX_H_
#define CQ_PAL_GFX_H_

#include <cstddef>
#include <cstdint>

#include "cq/base/status.h"
#include "cq/pal/common.h"

namespace cq {

// ---- 枚举 ----
enum class ShaderStage : int32_t {
    kVertex = 0,
    kFragment,
    kCompute,
};

// 顶点属性格式（最小集）。
enum class VertexFormat : int32_t {
    kFloat32 = 0,
    kFloat32x2,
    kFloat32x3,
    kFloat32x4,
    kUInt16,          // 归一化
    kUInt16x2,        // 归一化
    kUInt16x4,        // 归一化
};

// ---- 描述结构（POD，无平台类型）----
struct TextureDesc {
    TextureFormat format = TextureFormat::kRGBA8;
    uint32_t width = 1;
    uint32_t height = 1;
    uint32_t depth_or_layers = 1;
    TextureUsage usage = TextureUsage::kSampled;
};

struct BufferDesc {
    BufferUsage usage = BufferUsage::kVertex;
    uint64_t size_bytes = 0;
};

struct VertexAttribute {
    uint32_t location = 0;  // shader 绑定 location
    uint32_t offset = 0;    // 相对顶点起点的字节偏移
    VertexFormat format = VertexFormat::kFloat32x3;
};

struct VertexLayout {
    uint32_t stride = 0;                       // 单顶点字节跨度
    uint32_t attr_count = 0;                   // 实际使用的属性数
    VertexAttribute attrs[8] = {};             // 固定上限，避免动态分配
};

struct RenderTargetDesc {
    uint32_t width = 1;
    uint32_t height = 1;
    TextureFormat color_format = TextureFormat::kRGBA8;
};

struct ShaderModuleDesc {
    ShaderStage stage = ShaderStage::kVertex;
    const void* code = nullptr;   // SPIR-V 字节（Portable）或平台原生源/字节（Platform-Native）
    size_t code_size = 0;
    bool is_platform_native = false;  // true=平台原生（MSL/GLSL ES 扩展），false=SPIR-V 中间表示
};

struct PipelineDesc {
    ShaderModuleHandle vertex_shader = nullptr;
    ShaderModuleHandle fragment_shader = nullptr;
    VertexLayout vertex_layout;
    bool blend_enabled = false;
    TextureFormat target_format = TextureFormat::kRGBA8;
};

struct SamplerDesc {
    // 简化：仅线性/最近 + 寻址；各后端映射到自身 sampler 描述。
    bool linear_filter = true;
    bool clamp_to_edge = true;
};

// 设备创建描述。surface 用中性 NativeImageHandle 表达（平台在 PAL 内 reinterpret），
// 不引入任何平台 window/view 类型。
struct GraphicsDeviceDesc {
    NativeImageHandle surface = nullptr;  // 可选：渲染目标 surface（如 CAMetalLayer 内容）
    bool prefer_low_power = false;        // 移动端倾向低功耗 GPU
};

// ===========================================================================
// 资源接口（均继承 IPalResource，生命周期由 PalPtr 管理）
// ===========================================================================

class ITexture : public IPalResource {
public:
    virtual void GetDesc(TextureDesc& out) const = 0;
    // 显存占用字节数（用于 TextureBudget 记账，CORE-004）。
    virtual int64_t GetMemoryBytes() const = 0;
};

class IBuffer : public IPalResource {
public:
    virtual void GetDesc(BufferDesc& out) const = 0;
    virtual int64_t GetMemoryBytes() const = 0;
    // 映射 CPU 可见内存（可选；不支持返回 kUnsupported）。用于上传顶点/Uniform。
    virtual Status Map(void*& out_ptr) = 0;
    virtual void Unmap() = 0;
};

class IRenderTarget : public IPalResource {
public:
    virtual TextureHandle GetColorTexture() = 0;
    virtual uint32_t GetWidth() const = 0;
    virtual uint32_t GetHeight() const = 0;

    // 返回本资源对应的 opaque 句柄，供 `ICommandEncoder::BeginRenderPass` 使用。
    // ⚠️ 此方法是 2026-09-25 的**接口缺陷修复**（PALA-001 首次真实使用时暴露）：
    //    `CreateRenderTarget` 产出的是 `PalPtr<IRenderTarget>`（接口指针），
    //    而 `BeginRenderPass` 收的是 `RenderTargetHandle`（opaque 指针），
    //    原接口没有任何途径把前者转成后者 —— 创建出的 RenderTarget 无法被编码器使用。
    //    即「头文件能编译」不等于「接口能真正串联跑通」；
    //    编译验证 TU 只能证明前者，是本次缺陷未被早期发现的原因。
    virtual RenderTargetHandle Handle() = 0;
};

class IPipeline : public IPalResource {};

class IShaderModule : public IPalResource {};

class ISampler : public IPalResource {};

class IFence : public IPalResource {
public:
    virtual Status Signal() = 0;
    virtual Status Wait(uint64_t timeout_ms) = 0;  // 超时返回 kIoTimeout（非错误语义外的失败）
};

class ICommandEncoder : public IPalResource {
public:
    // clear_color 为 4 个 float（RGBA，0..1），非时间量，允许浮点。
    virtual Status BeginRenderPass(RenderTargetHandle target, const float clear_color[4]) = 0;
    virtual void SetPipeline(PipelineHandle pipeline) = 0;
    virtual void SetVertexBuffer(BufferHandle buffer, uint32_t slot) = 0;
    virtual void SetTexture(TextureHandle texture, uint32_t binding) = 0;
    virtual void SetSampler(SamplerHandle sampler, uint32_t binding) = 0;
    virtual void Draw(uint32_t vertex_count) = 0;
    virtual void DrawIndexed(uint32_t index_count) = 0;
    virtual void End() = 0;
};

class ICommandBuffer : public IPalResource {
public:
    virtual Status CreateEncoder(PalPtr<ICommandEncoder>& out_encoder) = 0;
    virtual Status Commit() = 0;
    virtual Status WaitUntilCompleted() = 0;
};

class ICommandQueue : public IPalResource {
public:
    virtual Status CreateCommandBuffer(PalPtr<ICommandBuffer>& out_buffer) = 0;
    virtual Status Submit(ICommandBuffer* buffer) = 0;
};

// ExternalImage 概念（ARCH-003 §3 / GFX-003）：把平台原生图像导入为可采样纹理。
// 支持零拷贝路径；失败时退化为 CPU 拷贝（out_cpu_fallback=true），绝不崩溃。
class INativeImageImporter : public IPalResource {
public:
    // 导入 NativeImageHandle 为 TextureHandle。
    //   out_cpu_fallback=true 表示未能零拷贝，已退化为 CPU 拷贝路径（仍可用，性能降级）。
    virtual Status Import(NativeImageHandle image, TextureUsage usage,
                          TextureHandle& out_texture, bool& out_cpu_fallback) = 0;

    // 释放 Import 产出的纹理句柄。
    // ⚠️ 这是 2026-10-02 补的**接口缺陷修复**（预览渲染器首次真实使用时暴露）：
    //    Import 返回裸 `TextureHandle`（`CqTexture*`），而该类型在 core 是不完整类型，
    //    core 侧**没有任何途径**释放它——每帧导入一张就泄漏一张（还额外锁住解码帧的
    //    IOSurface）。原先只有 Apple 内部辅助 `cq::apple::DestroyTexture` 能释放，
    //    但 core 调它就会引入平台依赖。故由「谁产出谁回收」：释放能力并入本接口。
    virtual void ReleaseTexture(TextureHandle texture) = 0;
};

// ===========================================================================
// 全屏纹理拷贝 pass（ExternalImage 的下游消费者）
// ===========================================================================
// 为什么定义在 **PAL** 而不是 GFX 层（core/include/cq/gfx/）：
//   它必然由**平台原生 shader** 实现（MSL / GLSL ES），而平台原生 shader 按红线 #6
//   只允许出现在 pal/<platform>/。GFX 层在 PAL 之上，若在此定义抽象、再由 PAL 实现，
//   就会出现 PAL 反向 include GFX 头，破坏分层。故放在 PAL 层，GFX/预览层持有即可。
//
// ⚠️ SPIR-V 链（Portable 层 shaders/src/*.glsl）尚未落地，MSL 是**唯一可用路径**。
//    这属「能力缺失降级」（无 Portable 可用 → 走平台原生），不是「平台特化优化」
//    ——后者必须先有 Portable 实现且收益 ≥ 20% 才允许合入。
//
// uv 约定（不得上下颠倒）：uv(0,0) = 图像左上，uv(1,1) = 图像右下。
// 该约定由 test_preview_renderer.cpp 的「RT 顶红 / 底蓝」两项断言锁定。
class IBlitPass : public IPalResource {
public:
    // 在给定编码器上编码一次全屏绘制。调用前调用方须已 BeginRenderPass。
    // src 可以是零拷贝导入的解码帧纹理，也可以是普通纹理。
    //
    // 收 **PAL 的** ICommandEncoder（不是 GFX 的 IGfxEncoder）：本类在 PAL 层，
    // 不能反向依赖 GFX。GFX 侧经 `IGfxEncoder::PalEncoder()` 取到底层编码器再传入
    // （与既有的 `IGfxDevice::PalDevice()` 同一套路）。
    virtual Status Encode(ICommandEncoder& encoder, TextureHandle src) = 0;
};

class IGraphicsDevice : public IPalResource {
public:
    virtual Status CreateTexture(const TextureDesc& desc, PalPtr<ITexture>& out) = 0;
    virtual Status CreateBuffer(const BufferDesc& desc, PalPtr<IBuffer>& out) = 0;
    virtual Status CreateRenderTarget(const RenderTargetDesc& desc, PalPtr<IRenderTarget>& out) = 0;
    virtual Status CreateShaderModule(const ShaderModuleDesc& desc, PalPtr<IShaderModule>& out) = 0;
    virtual Status CreatePipeline(const PipelineDesc& desc, PalPtr<IPipeline>& out) = 0;
    virtual Status CreateSampler(const SamplerDesc& desc, PalPtr<ISampler>& out) = 0;
    virtual Status CreateFence(PalPtr<IFence>& out) = 0;
    virtual Status CreateCommandQueue(PalPtr<ICommandQueue>& out) = 0;

    // 创建绑定到本设备的原生图像导入器（ExternalImage 概念，见 INativeImageImporter）。
    // 导入出的 TextureHandle 必须属于本设备上下文（Metal/Vulkan 要求），故由设备创建。
    virtual Status CreateNativeImageImporter(PalPtr<INativeImageImporter>& out) = 0;

    // 等待 fence（跨端统一同步语义）。
    virtual Status WaitFence(IFence* fence, uint64_t timeout_ms) = 0;
};

// 工厂（由 pal/apple / pal/android / pal/ohos 实现）。返回 PalPtr，RAII 安全。
Status CreateGraphicsDevice(const GraphicsDeviceDesc& desc, PalPtr<IGraphicsDevice>& out_device);

// 创建全屏拷贝 pass（见 IBlitPass）。target_format 必须与渲染目标格式一致——
// Metal 的管线在创建时即绑定目标像素格式，故它是**创建期**参数，不是每次编码的参数。
// ⚠️ 由各平台用**平台原生 shader** 实现；未实现的平台会在此符号上链接失败
//    （诚实暴露「该端暂无预览能力」，不伪造空实现）。
Status CreateBlitPass(IGraphicsDevice* device, TextureFormat target_format,
                      PalPtr<IBlitPass>& out_pass);

}  // namespace cq

#endif  // CQ_PAL_GFX_H_
