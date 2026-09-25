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

}  // namespace cq

#endif  // CQ_PAL_GFX_H_
