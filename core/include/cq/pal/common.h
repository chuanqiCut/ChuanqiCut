// ChuanqiCut — PAL 共享类型（CORE-006）
//
// 本文件是 PAL 全部领域头文件的公共基础，定义：
//   1. 跨层 opaque 句柄（不完整结构体指针）—— 满足「头文件零平台类型」红线。
//      平台实现在其 .cpp 中把 incomplete struct 定义为真正的平台资源包装
//      （如 `struct CqTexture { MTLTexture* tex; }`），core 层永远看不到平台类型。
//   2. 平台无关枚举（纹理/缓冲格式、用途、像素/采样格式、色彩空间）—— 不出现任何
//      Metal/Vulkan/GLES/AVFoundation 专有枚举。
//   3. `IPalResource` 资源基类 + `PalPtr<T>` RAII 包装 —— 统一生命周期契约
//      （跨模块不可直接 delete，一律经 Destroy()）。
//
// 红线（AGENTS.root.md / ADR-0010）：
//   * 零平台类型：本文件只使用 C/C++ 基础类型、incomplete struct 指针，绝不出现
//     id/NSString/CGFloat/CVPixelBufferRef/jobject/JNIEnv/MTLDevice/ID3D11Device，
//     也绝不 include 任何平台头。
//   * 零 FFmpeg 类型：不出现 AV* 类型、不 include 任何 ffmpeg 头。

#ifndef CQ_PAL_COMMON_H_
#define CQ_PAL_COMMON_H_

#include <cstddef>
#include <cstdint>

namespace cq {

// ===========================================================================
// 1. Opaque 句柄（不完整结构体指针）
// ===========================================================================
// 设计取舍：选 opaque 指针而非整数句柄——类型安全（传错资源编译期暴露）、
// 天然不暴露底层平台类型、无需 include 平台头。跨 C ABI 时再转 uintptr_t
// （那是 cq_sdk.h / BIND 层的事，不在本契约）。
#define CQ_DEFINE_OPAQUE_HANDLE(Name) \
    struct Cq##Name;                  \
    using Name##Handle = Cq##Name*;

CQ_DEFINE_OPAQUE_HANDLE(Device)            // GFX Device
CQ_DEFINE_OPAQUE_HANDLE(CommandQueue)      // GFX CommandQueue
CQ_DEFINE_OPAQUE_HANDLE(CommandBuffer)     // GFX CommandBuffer
CQ_DEFINE_OPAQUE_HANDLE(CommandEncoder)    // GFX Encoder
CQ_DEFINE_OPAQUE_HANDLE(Texture)           // GFX Texture
CQ_DEFINE_OPAQUE_HANDLE(Buffer)            // GFX Buffer
CQ_DEFINE_OPAQUE_HANDLE(RenderTarget)      // GFX RenderTarget
CQ_DEFINE_OPAQUE_HANDLE(Pipeline)          // GFX Pipeline
CQ_DEFINE_OPAQUE_HANDLE(ShaderModule)      // GFX ShaderModule
CQ_DEFINE_OPAQUE_HANDLE(Sampler)           // GFX Sampler
CQ_DEFINE_OPAQUE_HANDLE(Fence)             // GFX Fence

// 平台原生图像资源（CVPixelBuffer / AHardwareBuffer / OHNativeWindow 等的包装）。
// 视频解码帧、外部图片（含 HEIC）统一用此句柄，由 GFX 的 INativeImageImporter
// 转成 TextureHandle。跨领域共用，故放 common.h。
CQ_DEFINE_OPAQUE_HANDLE(NativeImage)

#undef CQ_DEFINE_OPAQUE_HANDLE

// ===========================================================================
// 2. 平台无关枚举
// ===========================================================================

// 像素格式（承接 ARCH-002/003 零拷贝与色彩管理）。不绑定任何平台 fourcc。
enum class PixelFormat : int32_t {
    kUnknown = 0,
    kRGBA8,
    kBGRA8,
    kRGBA16F,
    kYUV420Planar,     // I420 / IYUV
    kYUV420SemiPlanar, // NV12
    kYUV422Planar,
    kYUV422SemiPlanar, // NV16
    kGray8,
};

// 纹理格式（GFX）。
enum class TextureFormat : int32_t {
    kUnknown = 0,
    kR8,
    kRG8,
    kRGBA8,
    kRGBA16F,
    kR16F,
    kR32F,
    kRGBA32F,
};

// 纹理用途（bitmask）。
enum class TextureUsage : uint32_t {
    kNone = 0,
    kSampled = 1u << 0,        // 可被着色器采样
    kRenderTarget = 1u << 1,   // 可作为渲染目标
    kStorage = 1u << 2,        // 可读写存储（compute / blend）
};

constexpr TextureUsage operator|(TextureUsage a, TextureUsage b) {
    return static_cast<TextureUsage>(static_cast<uint32_t>(a) | static_cast<uint32_t>(b));
}
constexpr TextureUsage operator&(TextureUsage a, TextureUsage b) {
    return static_cast<TextureUsage>(static_cast<uint32_t>(a) & static_cast<uint32_t>(b));
}
constexpr bool HasUsage(TextureUsage flags, TextureUsage bit) {
    return (static_cast<uint32_t>(flags) & static_cast<uint32_t>(bit)) != 0u;
}

// 缓冲区用途（bitmask）。
enum class BufferUsage : uint32_t {
    kNone = 0,
    kVertex = 1u << 0,
    kIndex = 1u << 1,
    kUniform = 1u << 2,
    kStorage = 1u << 3,
};

constexpr BufferUsage operator|(BufferUsage a, BufferUsage b) {
    return static_cast<BufferUsage>(static_cast<uint32_t>(a) | static_cast<uint32_t>(b));
}

// 色彩空间 / 转换（承接 ARCH-003 §8 色彩管理，working space 待 ADR 定）。
enum class ColorSpace : int32_t {
    kUnknown = 0,
    kSRGB,        // 显示参照
    kRec709,      // HDTV
    kRec2020,     // UHD
    kLinear,      // 线性 working space 候选
    kPQ,          // HDR10 PQ
    kHLG,         // HDR HLG
};

// PCM 采样格式（Audio）。
enum class SampleFormat : int32_t {
    kUnknown = 0,
    kInt16,
    kInt32,
    kFloat32,
    kFloat64,
};

// 容器格式（Media）。与 FFmpeg 的 AVCodecID/AVInputFormat 解耦——FFmpeg 后端
// 在 PAL 实现内做映射，不污染 core。
enum class ContainerFormat : int32_t {
    kUnknown = 0,
    kMp4,       // 含 mov / m4a / 3gp 别名
    kMatroska,  // 含 webm
    kMpegTs,
    kMpegPs,
    kAvi,
    kFlv,
    kMov,       // 与 kMp4 同族，单独列出便于精确识别
    kQuickTimeImage, // image2 / 图片序列（HEIC 等走原生，不在此）
    kOther,
};

// 编解码器 ID（Media）。与 AVCodecID 解耦。
enum class CodecId : int32_t {
    kUnknown = 0,
    // 视频
    kH264,
    kHevc,
    kAv1,
    kProres,
    kMpeg4,
    kMjpeg,
    // 音频
    kAac,
    kMp3,
    kPcmS16Le,
    kFlac,
    kOpus,
};

// 媒体轨道类型。
enum class MediaType : int32_t {
    kUnknown = 0,
    kVideo,
    kAudio,
};

// 推理数据类型（Inference）。
enum class InferenceDataType : int32_t {
    kUnknown = 0,
    kFloat32,
    kFloat16,
    kInt32,
    kInt8,
    kUInt8,
};

// ===========================================================================
// 3. 资源基类 + RAII 包装
// ===========================================================================

// 所有 PAL 资源接口都继承此类。平台实现在 Destroy() 中释放自身（含底层平台资源）。
// 不可跨模块 delete（实现类可能与调用方不在同一编译单元、不同分配器）。
class IPalResource {
public:
    virtual ~IPalResource() = default;

    // 释放本资源（含底层平台资源）。调用后对象不可再用。
    virtual void Destroy() = 0;
};

// move-only RAII 包装：析构自动调 Destroy()，避免跨模块 delete 与资源泄漏。
// 工厂函数直接返回 PalPtr<T>，调用方无需手动管理生命周期。
template <typename T>
class PalPtr {
public:
    PalPtr() = default;
    explicit PalPtr(T* p) : p_(p) {}

    ~PalPtr() { reset(); }

    PalPtr(PalPtr&& o) noexcept : p_(o.p_) { o.p_ = nullptr; }
    PalPtr& operator=(PalPtr&& o) noexcept {
        if (this != &o) {
            reset();
            p_ = o.p_;
            o.p_ = nullptr;
        }
        return *this;
    }

    PalPtr(const PalPtr&) = delete;
    PalPtr& operator=(const PalPtr&) = delete;

    T* get() const { return p_; }
    T* operator->() const { return p_; }
    T& operator*() const { return *p_; }
    explicit operator bool() const { return p_ != nullptr; }

    void reset() {
        if (p_ != nullptr) {
            p_->Destroy();
            p_ = nullptr;
        }
    }

    // 释放所有权（调用方需自行 Destroy）。用于把裸指针交给需要裸指针的 API。
    T* release() {
        T* out = p_;
        p_ = nullptr;
        return out;
    }

private:
    T* p_ = nullptr;
};

}  // namespace cq

#endif  // CQ_PAL_COMMON_H_
