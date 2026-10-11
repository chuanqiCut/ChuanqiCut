// ChuanqiCut — Apple Metal 后端（PALA-001）
//
// 实现 core/include/cq/platform/gfx.h 中冻结的 Platform GFX HAL（ChqIGraphicsDevice 等 12 概念）。
// 平台类型（MTLDevice / id<MTLTexture> 等）**只出现在本文件与 gfx_metal_internal.h**，
// 内核头零平台类型红线不受影响。
//
// 设计要点：
//   * 每个 Platform 概念 1:1 映射 Metal 概念（见 .ai/modules/platform-apple.md 概念映射表）。
//   * 资源生命周期走 ChqPlatformPtr + Destroy()（与 ChqIPlatformResource 契约一致）；本 .mm 用 ARC 管理
//     Objective-C 对象，Destroy() 把成员置 nil 释放并 delete this。
//   * ShaderModule 支持 Platform-Native 源码（MSL，`is_platform_native=true`）；SPIR-V 路径
//     本期未实现（SHADER-001 的 MSL 生成尚未接入），返回 kInternal。
//   * ChqINativeImageImporter（PALA-002）已实现：CVMetalTextureCacheCreateTextureFromImage
//     零拷贝；失败时退化为 CPU 拷贝（out_cpu_fallback=true）。
//   * 错误一律 ChqStatus，无异常（内核禁用异常）。
//
// 编译：Objective-C++（.mm）+ ARC（-fobjc-arc）。警告集含 -Wconversion/-Wshadow/
// -Wold-style-cast，类型转换一律显式 static_cast。

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <TargetConditionals.h>
// ⚠️ IOSurface 是 **macOS 专有**框架，iOS SDK 不暴露其头文件（iOS 上属私有 API）。
//    2026-09-28 实测：iOS device 切片构建在此处 fatal error: 'IOSurface/IOSurface.h'
//    file not found —— 脚本如实失败，未放宽编译选项。
//    本文件只在「零拷贝验证辅助」里用到 IOSurface；产品代码的零拷贝走
//    CVMetalTextureCache，本身并不需要它。故按平台条件编译：
//    iOS 下该辅助函数退化为返回 0，调用方降级到耗时证据（BenchmarkNativeImageImport）。
#if !TARGET_OS_IPHONE
#import <IOSurface/IOSurface.h>
#endif

// CPU 可见（可 replaceRegion 上传）的 storage mode 因架构而异：
//   - macOS：Managed（CPU/GPU 可有独立副本，需显式同步）
//   - iOS  ：**统一内存**，Managed 不存在（API_UNAVAILABLE(ios)），CPU 可见即 Shared
//     2026-09-28 实测：iOS device 切片构建在 MTLStorageModeManaged 处报
//     "is unavailable: not available on iOS"（脚本如实失败，未放宽编译选项）
#if TARGET_OS_IPHONE
static const MTLStorageMode kCqCpuVisibleStorageMode = MTLStorageModeShared;
#else
static const MTLStorageMode kCqCpuVisibleStorageMode = MTLStorageModeManaged;
#endif

#include "cq/platform/chq_gfx.h"
#include "cq/base/chq_status.h"
#include "gfx_metal_internal.h"
#include "media_decode.h"  // 由 CMake 的 Apple Platform media include dir 提供

#include <cstdint>
#include <cstring>
#include <chrono>
#include <mutex>
#include <condition_variable>

namespace cq {

// ---- 格式映射辅助 ----
static uint32_t BytesPerPixel(ChqTextureFormat f) {
    switch (f) {
        case ChqTextureFormat::kR8:        return 1;
        case ChqTextureFormat::kRG8:       return 2;
        case ChqTextureFormat::kRGBA8:     return 4;
        case ChqTextureFormat::kRGBA16F:   return 8;
        case ChqTextureFormat::kR16F:      return 2;
        case ChqTextureFormat::kR32F:      return 4;
        case ChqTextureFormat::kRGBA32F:   return 16;
        default:                        return 4;
    }
}

static MTLPixelFormat ToMTLPixelFormat(ChqTextureFormat f) {
    switch (f) {
        case ChqTextureFormat::kR8:        return MTLPixelFormatR8Unorm;
        case ChqTextureFormat::kRG8:       return MTLPixelFormatRG8Unorm;
        case ChqTextureFormat::kRGBA8:     return MTLPixelFormatRGBA8Unorm;
        case ChqTextureFormat::kRGBA16F:   return MTLPixelFormatRGBA16Float;
        case ChqTextureFormat::kR16F:      return MTLPixelFormatR16Float;
        case ChqTextureFormat::kR32F:      return MTLPixelFormatR32Float;
        case ChqTextureFormat::kRGBA32F:   return MTLPixelFormatRGBA32Float;
        default:                        return MTLPixelFormatRGBA8Unorm;
    }
}

static MTLVertexFormat ToMTLVertexFormat(ChqVertexFormat f) {
    switch (f) {
        case ChqVertexFormat::kFloat32:     return MTLVertexFormatFloat;
        case ChqVertexFormat::kFloat32x2:   return MTLVertexFormatFloat2;
        case ChqVertexFormat::kFloat32x3:   return MTLVertexFormatFloat3;
        case ChqVertexFormat::kFloat32x4:   return MTLVertexFormatFloat4;
        case ChqVertexFormat::kUInt16:      return MTLVertexFormatUShortNormalized;
        case ChqVertexFormat::kUInt16x2:    return MTLVertexFormatUShort2Normalized;
        case ChqVertexFormat::kUInt16x4:    return MTLVertexFormatUShort4Normalized;
        default:                         return MTLVertexFormatFloat;
    }
}

// ===========================================================================
// 资源类（命名与 common.h 的 opaque 句柄 CqXxx 对齐，使 TextureHandle 等即本类指针）
// ===========================================================================

struct CqTexture : public ChqITexture {
public:
    id<MTLTexture> tex_ = nil;
    ChqTextureDesc desc_{};
    // 零拷贝导入时持有 CVMetalTextureRef（其底层 IOSurface 与源 CVPixelBuffer 共享），
    // 使纹理在存活期内 IOSurface 不被回收。普通纹理此项为 nil。
    CVMetalTextureRef cv_keepalive_ = nullptr;

    void Destroy() override {
        if (cv_keepalive_ != nullptr) {
            CFRelease(cv_keepalive_);
            cv_keepalive_ = nullptr;
        }
        tex_ = nil;
        desc_ = ChqTextureDesc{};
        delete this;
    }
    void GetDesc(ChqTextureDesc& out) const override { out = desc_; }
    int64_t GetMemoryBytes() const override {
        const int64_t bpp = static_cast<int64_t>(BytesPerPixel(desc_.format));
        return static_cast<int64_t>(desc_.width) * static_cast<int64_t>(desc_.height) *
               bpp * static_cast<int64_t>(desc_.depth_or_layers);
    }
};

struct CqBuffer : public ChqIBuffer {
public:
    id<MTLBuffer> buf_ = nil;
    ChqBufferDesc desc_{};

    void Destroy() override {
        buf_ = nil;
        desc_ = ChqBufferDesc{};
        delete this;
    }
    void GetDesc(ChqBufferDesc& out) const override { out = desc_; }
    int64_t GetMemoryBytes() const override {
        return static_cast<int64_t>(desc_.size_bytes);
    }
    ChqStatus Map(void*& out_ptr) override {
        if (buf_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        out_ptr = [buf_ contents];
        return ChqStatus::Ok();
    }
    void Unmap() override {}
};

struct CqRenderTarget : public ChqIRenderTarget {
public:
    id<MTLDevice> device_ = nil;
    id<MTLTexture> color_tex_ = nil;
    uint32_t w_ = 0;
    uint32_t h_ = 0;
    ChqTextureFormat fmt_ = ChqTextureFormat::kRGBA8;

    void Destroy() override {
        color_tex_ = nil;
        device_ = nil;
        delete this;
    }
    // 契约（platform/gfx.h）：返回**可显示原生纹理**（id<MTLTexture>）本身，
    // 不是 CqTexture* 包装 —— UI 侧按 cq_sdk.h 约定 reinterpret 为 MTLTexture。
    // 2026-10-03 修复：原实现返回惰性包装对象，Swift 侧 reinterpret 直接崩溃
    // （首次真实消费暴露，与 PALA-001 的 Handle() 修复同一模式）。
    TextureHandle GetColorTexture() override {
        return (__bridge TextureHandle)color_tex_;
    }
    uint32_t GetWidth() const override { return w_; }
    uint32_t GetHeight() const override { return h_; }
    // 本对象即 opaque 句柄 `CqRenderTarget*`（见 gfx.h 中 Handle() 的缺陷修复说明）。
    RenderTargetHandle Handle() override { return this; }
};

struct CqShaderModule : public ChqIShaderModule {
public:
    id<MTLLibrary> lib_ = nil;
    id<MTLFunction> func_ = nil;

    void Destroy() override {
        func_ = nil;
        lib_ = nil;
        delete this;
    }
};

struct CqPipeline : public ChqIPipeline {
public:
    id<MTLRenderPipelineState> state_ = nil;

    void Destroy() override {
        state_ = nil;
        delete this;
    }
};

struct CqSampler : public ChqISampler {
public:
    id<MTLSamplerState> state_ = nil;

    void Destroy() override {
        state_ = nil;
        delete this;
    }
};

struct CqFence : public ChqIFence {
public:
    std::mutex mtx_;
    std::condition_variable cv_;
    bool signaled_ = false;

    void Destroy() override { delete this; }

    ChqStatus Signal() override {
        {
            std::lock_guard<std::mutex> lk(mtx_);
            signaled_ = true;
        }
        cv_.notify_all();
        return ChqStatus::Ok();
    }

    ChqStatus Wait(uint64_t timeout_ms) override {
        std::unique_lock<std::mutex> lk(mtx_);
        if (signaled_) return ChqStatus::Ok();
        if (timeout_ms == 0) return ChqStatus(ChqStatusCode::kIoTimeout);
        const auto rel = std::chrono::milliseconds(static_cast<long>(timeout_ms));
        const bool ok = cv_.wait_for(lk, rel, [this]() { return signaled_; });
        return ok ? ChqStatus::Ok() : ChqStatus(ChqStatusCode::kIoTimeout);
    }
};

struct CqCommandEncoder : public ChqICommandEncoder {
public:
    id<MTLCommandBuffer> cb_ = nil;       // 由 CqCommandBuffer 持有，encoder 不释放
    id<MTLRenderCommandEncoder> enc_ = nil;

    void Destroy() override {
        enc_ = nil;
        // cb_ 由 CqCommandBuffer 拥有，这里不释放
        delete this;
    }

    ChqStatus BeginRenderPass(RenderTargetHandle target, const float clear_color[4]) override {
        auto* mrt = static_cast<CqRenderTarget*>(target);
        if (mrt == nullptr || mrt->color_tex_ == nil) return ChqStatus(ChqStatusCode::kInvalidArgument);

        MTLRenderPassDescriptor* dp = [MTLRenderPassDescriptor renderPassDescriptor];
        dp.colorAttachments[0].texture = mrt->color_tex_;
        dp.colorAttachments[0].loadAction = MTLLoadActionClear;
        const double r = static_cast<double>(clear_color[0]);
        const double g = static_cast<double>(clear_color[1]);
        const double b = static_cast<double>(clear_color[2]);
        const double a = static_cast<double>(clear_color[3]);
        dp.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);
        dp.colorAttachments[0].storeAction = MTLStoreActionStore;

        enc_ = [cb_ renderCommandEncoderWithDescriptor:dp];
        if (enc_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        return ChqStatus::Ok();
    }

    void SetPipeline(PipelineHandle pipeline) override {
        auto* mp = static_cast<CqPipeline*>(pipeline);
        if (enc_ != nil && mp != nullptr) [enc_ setRenderPipelineState:mp->state_];
    }

    void SetVertexBuffer(BufferHandle buffer, uint32_t slot) override {
        auto* mb = static_cast<CqBuffer*>(buffer);
        if (enc_ != nil && mb != nullptr) {
            [enc_ setVertexBuffer:mb->buf_ offset:0 atIndex:static_cast<NSUInteger>(slot)];
        }
    }

    void SetTexture(TextureHandle texture, uint32_t binding) override {
        auto* mt = static_cast<CqTexture*>(texture);
        if (enc_ != nil && mt != nullptr) {
            [enc_ setFragmentTexture:mt->tex_ atIndex:static_cast<NSUInteger>(binding)];
            [enc_ setVertexTexture:mt->tex_ atIndex:static_cast<NSUInteger>(binding)];
        }
    }

    void SetSampler(SamplerHandle sampler, uint32_t binding) override {
        auto* ms = static_cast<CqSampler*>(sampler);
        if (enc_ != nil && ms != nullptr) {
            [enc_ setFragmentSamplerState:ms->state_ atIndex:static_cast<NSUInteger>(binding)];
            [enc_ setVertexSamplerState:ms->state_ atIndex:static_cast<NSUInteger>(binding)];
        }
    }

    // 契约见 platform/gfx.h：像素、原点 = target 左上、可大于目标。Metal 的 MTLViewport
    // 正是左上原点 + 像素，1:1 直映；z 范围用全量 {0,1}（本层无深度语义）。
    void SetViewport(float x, float y, float width, float height) override {
        if (enc_ != nil) {
            [enc_ setViewport:MTLViewport{static_cast<double>(x), static_cast<double>(y),
                                          static_cast<double>(width),
                                          static_cast<double>(height), 0.0, 1.0}];
        }
    }

    void Draw(uint32_t vertex_count) override {
        if (enc_ != nil) {
            [enc_ drawPrimitives:MTLPrimitiveTypeTriangle
                     vertexStart:0
                     vertexCount:static_cast<NSUInteger>(vertex_count)];
        }
    }

    void DrawIndexed(uint32_t /*index_count*/) override {
        // Platform 接口未提供 SetIndexBuffer，本期索引绘制未实现；Draw 路径覆盖验证用例。
    }

    void End() override {
        if (enc_ != nil) {
            [enc_ endEncoding];
            enc_ = nil;
        }
    }
};

struct CqCommandBuffer : public ChqICommandBuffer {
public:
    id<MTLCommandQueue> queue_ = nil;
    id<MTLCommandBuffer> cb_ = nil;
    bool committed_ = false;

    void Destroy() override {
        cb_ = nil;
        queue_ = nil;
        delete this;
    }

    ChqStatus CreateEncoder(ChqPlatformPtr<ChqICommandEncoder>& out_encoder) override {
        if (cb_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        auto* e = new CqCommandEncoder();
        e->cb_ = cb_;
        out_encoder = ChqPlatformPtr<ChqICommandEncoder>(e);
        return ChqStatus::Ok();
    }

    ChqStatus Commit() override {
        if (committed_) return ChqStatus::Ok();
        if (cb_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        [cb_ commit];
        committed_ = true;
        return ChqStatus::Ok();
    }

    ChqStatus WaitUntilCompleted() override {
        if (cb_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        [cb_ waitUntilCompleted];
        if (cb_.status == MTLCommandBufferStatusError) return ChqStatus(ChqStatusCode::kInternal);
        return ChqStatus::Ok();
    }
};

struct CqCommandQueue : public ChqICommandQueue {
public:
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;

    void Destroy() override {
        queue_ = nil;
        device_ = nil;
        delete this;
    }

    ChqStatus CreateCommandBuffer(ChqPlatformPtr<ChqICommandBuffer>& out_buffer) override {
        if (queue_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        id<MTLCommandBuffer> b = [queue_ commandBuffer];
        if (b == nil) return ChqStatus(ChqStatusCode::kInternal);
        auto* mb = new CqCommandBuffer();
        mb->queue_ = queue_;
        mb->cb_ = b;
        out_buffer = ChqPlatformPtr<ChqICommandBuffer>(mb);
        return ChqStatus::Ok();
    }

    ChqStatus Submit(ChqICommandBuffer* buffer) override {
        if (buffer == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
        return static_cast<CqCommandBuffer*>(buffer)->Commit();
    }

    // 中性句柄（UIA-010 子步骤 5）：UI 侧的 blit 复用本队列，以 commit 顺序保证
    // 「泵线程写完 → UI 线程再读」的先后（跨队列 Metal 不做此保证）。
    // 所有权仍归本对象（queue_ 强引用），故这里用 __bridge，不额外 +1。
    void* NativeHandle() override {
        return queue_ == nil ? nullptr : (__bridge void*)queue_;
    }
};

// ---------------------------------------------------------------------------
// PALA-002：CVPixelBuffer → CVMetalTexture 零拷贝导入器（ExternalImage 概念）
//
// 零拷贝关键：`CVMetalTextureCacheCreateTextureFromImage` 把 CVPixelBuffer 的
// IOSurface **直接包装**成 id<MTLTexture>。全程**不调用 replaceRegion、不分配/拷贝
// 像素缓冲**——纹理与源 buffer 共享同一块物理内存（IOSurface）。
//
// 退化路径（契约要求「导入失败仍可用」）：当零拷贝不成立（如 CVPixelBuffer 未设
// kCVPixelBufferMetalCompatibilityKey、或格式非 32BGRA）时，锁定源基址、用
// replaceRegion 把 BGRA 该厂商拷进一张 BGRA8Unorm 纹理，out_cpu_fallback=true。
// 两条路径产出的纹理**物理格式均为 MTLPixelFormatBGRA8Unorm**（匹配 PALA-011 的 32BGRA
// 输出，使 CVMetalTexture 能直接复用其 IOSurface）。Metal 对 BGRA8Unorm 的采样已按「逻辑 RGBA」
// 返回（.r=红/.b=蓝，该厂商布局由格式内部吸收），故采样端着色器**无需**手动交换通道；
// 对外逻辑格式仍报 kRGBA8。
struct CqNativeImageImporter : public ChqINativeImageImporter {
public:
    id<MTLDevice> device_ = nil;
    CVMetalTextureCacheRef cache_ = nullptr;  // 按 device 持有并复用

    void Destroy() override {
        if (cache_ != nullptr) {
            CFRelease(cache_);
            cache_ = nullptr;
        }
        device_ = nil;
        delete this;
    }

    ChqStatus Import(NativeImageHandle image, ChqTextureUsage usage,
                  TextureHandle& out_texture, bool& out_cpu_fallback) override {
        out_texture = nullptr;
        out_cpu_fallback = false;
        if (device_ == nil || cache_ == nullptr) return ChqStatus(ChqStatusCode::kInternal);
        if (image == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

        auto* ni = static_cast<CqNativeImage*>(image);
        CVPixelBufferRef pb = ni->pixel_buffer;
        if (pb == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

        const size_t w = CVPixelBufferGetWidth(pb);
        const size_t h = CVPixelBufferGetHeight(pb);
        if (w == 0 || h == 0) return ChqStatus(ChqStatusCode::kInvalidArgument);

        // ---- 零拷贝路径：CVPixelBuffer -> CVMetalTexture（共享 IOSurface）----
        // ⚠️ 这里**没有任何像素缓冲拷贝**：CVMetalTextureCacheCreateTextureFromImage
        // 直接复用源 buffer 的 IOSurface 作为纹理存储。
        CVMetalTextureRef cvtex = nullptr;
        const CVReturn cvret = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache_, pb, nullptr,
            MTLPixelFormatBGRA8Unorm,
            w, h, 0, &cvtex);
        if (cvret == kCVReturnSuccess && cvtex != nullptr) {
            id<MTLTexture> tex = CVMetalTextureGetTexture(cvtex);
            if (tex != nil) {
                auto* t = new CqTexture();
                t->tex_ = tex;
                t->desc_.format = ChqTextureFormat::kRGBA8;  // 逻辑格式：管线按 RGBA 消费
                t->desc_.width = static_cast<uint32_t>(w);
                t->desc_.height = static_cast<uint32_t>(h);
                t->desc_.usage = usage;
                // 把 CreateTextureFromImage 的所有权转交给纹理包装（不再额外 retain）：
                // cv_keepalive_ 在纹理存活期保持 CVMetalTextureRef（及其 IOSurface）有效。
                t->cv_keepalive_ = cvtex;
                out_texture = t;
                out_cpu_fallback = false;
                return ChqStatus::Ok();
            }
            CFRelease(cvtex);  // tex 为 nil 的异常分支
        }

        // ---- 退化路径：零拷贝失败 -> CPU 拷贝（仍返回可用纹理）----
        // PALA-011 输出为 32BGRA，本路径仅支持该格式；其它格式如实返回 kUnsupported。
        return ImportCpu(pb, usage, out_texture, out_cpu_fallback);
    }

    // 释放 Import 产出的纹理（见 platform/gfx.h 中该方法的缺陷修复说明）。
    // CqTexture 在本 TU 为完整类型，可直接下行转换后 Destroy；core 侧做不到这件事。
    void ReleaseTexture(TextureHandle texture) override {
        auto* t = static_cast<CqTexture*>(texture);
        if (t != nullptr) t->Destroy();
    }

private:
    // 退化路径实现：锁定源基址 + replaceRegion 把 BGRA 该厂商拷进 BGRA8Unorm 纹理。
    // ⚠️ 这是**唯一发生像素拷贝**的地方。零拷贝成立时 Import 不会调用它。
    ChqStatus ImportCpu(CVPixelBufferRef pb, ChqTextureUsage usage,
                     TextureHandle& out_texture, bool& out_cpu_fallback) {
        out_texture = nullptr;
        out_cpu_fallback = true;
        if (CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) {
            return ChqStatus(ChqStatusCode::kFormatUnsupported);
        }
        if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
            return ChqStatus(ChqStatusCode::kInternal);
        }
        const size_t w = CVPixelBufferGetWidth(pb);
        const size_t h = CVPixelBufferGetHeight(pb);
        const size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        const uint8_t* src = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pb));

        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                              width:static_cast<NSUInteger>(w)
                                                             height:static_cast<NSUInteger>(h)
                                                          mipmapped:NO];
        td.storageMode = kCqCpuVisibleStorageMode;  // CPU 可 replaceRegion 上传（iOS 下为 Shared）
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> ctex = [device_ newTextureWithDescriptor:td];
        if (ctex == nil) {
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            return ChqStatus(ChqStatusCode::kInternal);
        }
        [ctex replaceRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(w),
                                            static_cast<NSUInteger>(h))
                mipmapLevel:0
                  withBytes:src
                bytesPerRow:static_cast<NSUInteger>(bpr)];
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

        auto* t = new CqTexture();
        t->tex_ = ctex;
        t->desc_.format = ChqTextureFormat::kRGBA8;
        t->desc_.width = static_cast<uint32_t>(w);
        t->desc_.height = static_cast<uint32_t>(h);
        t->desc_.usage = usage;
        out_texture = t;
        return ChqStatus::Ok();
    }
};

struct CqDevice : public ChqIGraphicsDevice {
public:
    id<MTLDevice> device_ = nil;

    void Destroy() override {
        device_ = nil;
        delete this;
    }

    ChqStatus CreateTexture(const ChqTextureDesc& desc, ChqPlatformPtr<ChqITexture>& out) override {
        if (device_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        const bool is_rt = (static_cast<uint32_t>(desc.usage & ChqTextureUsage::kRenderTarget) != 0u);
        const bool is_sampled = (static_cast<uint32_t>(desc.usage & ChqTextureUsage::kSampled) != 0u);

        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:ToMTLPixelFormat(desc.format)
                                                                width:static_cast<NSUInteger>(desc.width)
                                                               height:static_cast<NSUInteger>(desc.height)
                                                            mipmapped:NO];
        // 渲染目标用 Private（GPU 最优）；需要 CPU 上传（采样源）用 CPU 可见模式（macOS=Managed / iOS=Shared）。
        td.storageMode = is_rt ? MTLStorageModePrivate : kCqCpuVisibleStorageMode;
        MTLTextureUsage usage = 0;
        if (is_rt) usage |= MTLTextureUsageRenderTarget;
        if (is_sampled) usage |= MTLTextureUsageShaderRead;
        if (usage == 0) usage = MTLTextureUsageShaderRead;
        td.usage = usage;

        id<MTLTexture> tex = [device_ newTextureWithDescriptor:td];
        if (tex == nil) return ChqStatus(ChqStatusCode::kInternal);

        auto* t = new CqTexture();
        t->tex_ = tex;
        t->desc_ = desc;
        out = ChqPlatformPtr<ChqITexture>(t);
        return ChqStatus::Ok();
    }

    ChqStatus CreateBuffer(const ChqBufferDesc& desc, ChqPlatformPtr<ChqIBuffer>& out) override {
        if (device_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        if (desc.size_bytes == 0) return ChqStatus(ChqStatusCode::kInvalidArgument);
        id<MTLBuffer> buf =
            [device_ newBufferWithLength:static_cast<NSUInteger>(desc.size_bytes)
                                 options:MTLResourceStorageModeShared];
        if (buf == nil) return ChqStatus(ChqStatusCode::kInternal);
        auto* b = new CqBuffer();
        b->buf_ = buf;
        b->desc_ = desc;
        out = ChqPlatformPtr<ChqIBuffer>(b);
        return ChqStatus::Ok();
    }

    ChqStatus CreateRenderTarget(const ChqRenderTargetDesc& desc, ChqPlatformPtr<ChqIRenderTarget>& out) override {
        if (device_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:ToMTLPixelFormat(desc.color_format)
                                                                width:static_cast<NSUInteger>(desc.width)
                                                               height:static_cast<NSUInteger>(desc.height)
                                                            mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [device_ newTextureWithDescriptor:td];
        if (tex == nil) return ChqStatus(ChqStatusCode::kInternal);

        auto* rt = new CqRenderTarget();
        rt->device_ = device_;
        rt->color_tex_ = tex;
        rt->w_ = desc.width;
        rt->h_ = desc.height;
        rt->fmt_ = desc.color_format;
        out = ChqPlatformPtr<ChqIRenderTarget>(rt);
        return ChqStatus::Ok();
    }

    ChqStatus CreateShaderModule(const ChqShaderModuleDesc& desc, ChqPlatformPtr<ChqIShaderModule>& out) override {
        if (device_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        if (!desc.is_platform_native) {
            // SPIR-V -> MSL 转译尚未接入（SHADER-001），本期仅支持 Platform-Native MSL 源码。
            return ChqStatus(ChqStatusCode::kInternal);
        }
        const char* src_ptr = static_cast<const char*>(desc.code);
        if (src_ptr == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
        std::string src = (desc.code_size > 0u)
                              ? std::string(src_ptr, desc.code_size)
                              : std::string(src_ptr);

        NSError* err = nil;
        id<MTLLibrary> lib = [device_ newLibraryWithSource:
                                 [NSString stringWithUTF8String:src.c_str()]
                                                  options:nil
                                                    error:&err];
        if (lib == nil) return ChqStatus(ChqStatusCode::kInternal);

        const MTLFunctionType want =
            (desc.stage == ChqShaderStage::kFragment) ? MTLFunctionTypeFragment
            : (desc.stage == ChqShaderStage::kCompute) ? MTLFunctionTypeKernel
                                                   : MTLFunctionTypeVertex;
        id<MTLFunction> fn = nil;
        for (NSString* name in lib.functionNames) {
            id<MTLFunction> f = [lib newFunctionWithName:name];
            if (f != nil && f.functionType == want) {
                fn = f;
                break;
            }
        }
        if (fn == nil) return ChqStatus(ChqStatusCode::kInternal);

        auto* m = new CqShaderModule();
        m->lib_ = lib;
        m->func_ = fn;
        out = ChqPlatformPtr<ChqIShaderModule>(m);
        return ChqStatus::Ok();
    }

    ChqStatus CreatePipeline(const ChqPipelineDesc& desc, ChqPlatformPtr<ChqIPipeline>& out) override {
        if (device_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        auto* vm = static_cast<CqShaderModule*>(desc.vertex_shader);
        auto* fm = static_cast<CqShaderModule*>(desc.fragment_shader);
        if (vm == nullptr || fm == nullptr || vm->func_ == nil || fm->func_ == nil) {
            return ChqStatus(ChqStatusCode::kInvalidArgument);
        }

        // 顶点布局 -> MTLVertexDescriptor（所有属性来自 slot 0 的顶点缓冲）。
        MTLVertexDescriptor* vd = [MTLVertexDescriptor new];
        for (uint32_t i = 0; i < desc.vertex_layout.attr_count; ++i) {
            const ChqVertexAttribute& a = desc.vertex_layout.attrs[i];
            vd.attributes[a.location].format = ToMTLVertexFormat(a.format);
            vd.attributes[a.location].offset = static_cast<NSUInteger>(a.offset);
            vd.attributes[a.location].bufferIndex = 0;
        }
        vd.layouts[0].stride = static_cast<NSUInteger>(desc.vertex_layout.stride);
        vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        vd.layouts[0].stepRate = 1;

        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vm->func_;
        pd.fragmentFunction = fm->func_;
        pd.vertexDescriptor = vd;
        pd.colorAttachments[0].pixelFormat = ToMTLPixelFormat(desc.target_format);

        NSError* err = nil;
        id<MTLRenderPipelineState> st =
            [device_ newRenderPipelineStateWithDescriptor:pd error:&err];
        if (st == nil) return ChqStatus(ChqStatusCode::kInternal);

        auto* p = new CqPipeline();
        p->state_ = st;
        out = ChqPlatformPtr<ChqIPipeline>(p);
        return ChqStatus::Ok();
    }

    ChqStatus CreateSampler(const ChqSamplerDesc& desc, ChqPlatformPtr<ChqISampler>& out) override {
        if (device_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
        const MTLSamplerMinMagFilter f =
            desc.linear_filter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.minFilter = f;
        sd.magFilter = f;
        const MTLSamplerAddressMode am =
            desc.clamp_to_edge ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        sd.sAddressMode = am;
        sd.tAddressMode = am;
        sd.rAddressMode = am;
        id<MTLSamplerState> s = [device_ newSamplerStateWithDescriptor:sd];
        if (s == nil) return ChqStatus(ChqStatusCode::kInternal);
        auto* sm = new CqSampler();
        sm->state_ = s;
        out = ChqPlatformPtr<ChqISampler>(sm);
        return ChqStatus::Ok();
    }

    ChqStatus CreateFence(ChqPlatformPtr<ChqIFence>& out) override {
        out = ChqPlatformPtr<ChqIFence>(new CqFence());
        return ChqStatus::Ok();
    }

    ChqStatus CreateCommandQueue(ChqPlatformPtr<ChqICommandQueue>& out) override {
        if (device_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        id<MTLCommandQueue> q = [device_ newCommandQueue];
        if (q == nil) return ChqStatus(ChqStatusCode::kInternal);
        auto* cq = new CqCommandQueue();
        cq->device_ = device_;
        cq->queue_ = q;
        out = ChqPlatformPtr<ChqICommandQueue>(cq);
        return ChqStatus::Ok();
    }

    ChqStatus CreateNativeImageImporter(ChqPlatformPtr<ChqINativeImageImporter>& out) override {
        if (device_ == nil) return ChqStatus(ChqStatusCode::kInternal);
        CVMetalTextureCacheRef cache = nullptr;
        const CVReturn r = CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device_,
                                                     nullptr, &cache);
        if (r != kCVReturnSuccess || cache == nullptr) {
            return ChqStatus(ChqStatusCode::kInternal);
        }
        auto* imp = new CqNativeImageImporter();
        imp->device_ = device_;      // ARC 自动 retain
        imp->cache_ = cache;         // 所有权交给 imp，Destroy 时 CFRelease
        out = ChqPlatformPtr<ChqINativeImageImporter>(imp);
        return ChqStatus::Ok();
    }

    ChqStatus WaitFence(ChqIFence* fence, uint64_t timeout_ms) override {
        if (fence == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
        return static_cast<CqFence*>(fence)->Wait(timeout_ms);
    }
};

// ===========================================================================
// 工厂 + 内部辅助
// ===========================================================================

ChqStatus CreateGraphicsDevice(const ChqGraphicsDeviceDesc& /*desc*/, ChqPlatformPtr<ChqIGraphicsDevice>& out_device) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev == nil) return ChqStatus(ChqStatusCode::kInternal);
    auto* d = new CqDevice();
    d->device_ = dev;
    out_device = ChqPlatformPtr<ChqIGraphicsDevice>(d);
    return ChqStatus::Ok();
}

}  // namespace cq

namespace cq {
namespace apple {

ChqStatus ReadRenderTargetPixels(ChqIRenderTarget* rt,
                              uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                              void* out_rgba8, size_t out_size) {
    if (rt == nullptr || out_rgba8 == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    auto* mrt = static_cast<CqRenderTarget*>(rt);
    if (mrt->device_ == nil || mrt->color_tex_ == nil) return ChqStatus(ChqStatusCode::kInternal);

    const NSUInteger bpr = static_cast<NSUInteger>(w) * 4u;
    const NSUInteger img_bytes = bpr * static_cast<NSUInteger>(h);
    if (static_cast<NSUInteger>(out_size) < img_bytes) return ChqStatus(ChqStatusCode::kInvalidArgument);

    id<MTLBuffer> buf = [mrt->device_ newBufferWithLength:img_bytes
                                                 options:MTLResourceStorageModeShared];
    if (buf == nil) return ChqStatus(ChqStatusCode::kInternal);

    id<MTLCommandQueue> q = [mrt->device_ newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:mrt->color_tex_
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(static_cast<NSUInteger>(x), static_cast<NSUInteger>(y), 0)
            sourceSize:MTLSizeMake(static_cast<NSUInteger>(w), static_cast<NSUInteger>(h), 1)
              toBuffer:buf
     destinationOffset:0
destinationBytesPerRow:bpr
destinationBytesPerImage:img_bytes];
    [be endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    const void* src = [buf contents];
    if (src == nullptr) return ChqStatus(ChqStatusCode::kInternal);
    std::memcpy(out_rgba8, src, static_cast<size_t>(img_bytes));
    return ChqStatus::Ok();
}

ChqStatus UploadTextureData(ChqITexture* tex, const void* data, size_t bytes) {
    if (tex == nullptr || data == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    auto* mt = static_cast<CqTexture*>(tex);
    if (mt->tex_ == nil) return ChqStatus(ChqStatusCode::kInternal);
    const uint32_t w = mt->desc_.width;
    const uint32_t h = mt->desc_.height;
    const size_t need = static_cast<size_t>(w) * static_cast<size_t>(h) * 4u;
    if (bytes < need) return ChqStatus(ChqStatusCode::kInvalidArgument);
    const NSUInteger bpr = static_cast<NSUInteger>(w) * 4u;
    [mt->tex_ replaceRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(w), static_cast<NSUInteger>(h))
                 mipmapLevel:0
                   withBytes:data
                 bytesPerRow:bpr];
    return ChqStatus::Ok();
}

// ---- 句柄桥接（CqXxx 继承 Ixxx，安全下行转换）----
ShaderModuleHandle   ToShaderHandle(ChqIShaderModule* p)   { return static_cast<CqShaderModule*>(p); }
PipelineHandle      ToPipelineHandle(ChqIPipeline* p)       { return static_cast<CqPipeline*>(p); }
BufferHandle        ToBufferHandle(ChqIBuffer* p)           { return static_cast<CqBuffer*>(p); }
TextureHandle       ToTextureHandle(ChqITexture* p)         { return static_cast<CqTexture*>(p); }
SamplerHandle       ToSamplerHandle(ChqISampler* p)         { return static_cast<CqSampler*>(p); }
RenderTargetHandle  ToRenderTargetHandle(ChqIRenderTarget* p){ return static_cast<CqRenderTarget*>(p); }

// 零拷贝验证辅助：返回导入纹理背后 IOSurface 的 ID。取不到（非 IOSurface 纹理 / 平台不支持）
// 时返回 0，调用方据以降级到替代证据（如耗时实测）。用于证明「纹理与源 CVPixelBuffer 共享
// 同一 IOSurface」——即物理上零拷贝。
uint32_t GetImportedTextureIosurfaceId(TextureHandle tex) {
    auto* mt = static_cast<CqTexture*>(tex);
    if (mt == nullptr || mt->tex_ == nil) return 0;
#if TARGET_OS_IPHONE
    // iOS：IOSurface 非公开 API，无法取 ID。返回 0，调用方降级到耗时证据。
    // 零拷贝本身（CVMetalTextureCache）仍然成立，只是不能靠 IOSurface ID 证明。
    return 0;
#else
    IOSurfaceRef surf = mt->tex_.iosurface;  // MTLTexture.iosurface（macOS）：底层 IOSurface
    if (surf == nullptr) return 0;
    return static_cast<uint32_t>(IOSurfaceGetID(surf));
#endif
}

// 零拷贝耗时代差证明：对「Metal 兼容帧」走零拷贝（zero_handle）、对「非兼容帧」走 CPU 退化
// （cpu_handle）各 iters 次，返回各自总耗时（毫秒）。零拷贝仅建纹理视图（µs 级），CPU 退化含
// 整帧 BGRA memcpy；二者差距即为零拷贝收益的客观证据（取不到 IOSurface 时退化为该实测）。
ChqStatus BenchmarkNativeImageImport(ChqIGraphicsDevice* dev,
                                 NativeImageHandle zero_handle,
                                 NativeImageHandle cpu_handle,
                                 int iters,
                                 double& out_zero_ms, double& out_cpu_ms) {
    out_zero_ms = 0.0;
    out_cpu_ms = 0.0;
    if (dev == nullptr || zero_handle == nullptr || cpu_handle == nullptr || iters <= 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    auto* cdev = static_cast<CqDevice*>(dev);
    if (cdev == nullptr || cdev->device_ == nil) return ChqStatus(ChqStatusCode::kInternal);
    ChqPlatformPtr<ChqINativeImageImporter> imp;
    if (!cdev->CreateNativeImageImporter(imp).IsOk()) return ChqStatus(ChqStatusCode::kInternal);
    auto* cimp = static_cast<CqNativeImageImporter*>(imp.get());

    auto time_it = [&](NativeImageHandle h, double& out_ms) -> ChqStatus {
        const auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < iters; ++i) {
            TextureHandle th = nullptr;
            bool fb = false;
            if (!cimp->Import(h, ChqTextureUsage::kSampled, th, fb).IsOk()) {
                return ChqStatus(ChqStatusCode::kInternal);
            }
            static_cast<ChqITexture*>(th)->Destroy();
        }
        const auto t1 = std::chrono::steady_clock::now();
        out_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        return ChqStatus::Ok();
    };
    ChqStatus s = time_it(zero_handle, out_zero_ms);
    if (!s.IsOk()) return s;
    return time_it(cpu_handle, out_cpu_ms);
}

// 释放 importer 产出的纹理句柄（见 gfx_metal_internal.h 说明；CqTexture 在此 TU 为完整类型）。
void DestroyTexture(TextureHandle tex) {
    auto* t = static_cast<CqTexture*>(tex);
    if (t != nullptr) t->Destroy();
}

}  // namespace apple
}  // namespace cq
