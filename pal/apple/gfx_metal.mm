// ChuanqiCut — Apple Metal 后端（PALA-001）
//
// 实现 core/include/cq/pal/gfx.h 中冻结的 PAL GFX HAL（IGraphicsDevice 等 12 概念）。
// 平台类型（MTLDevice / id<MTLTexture> 等）**只出现在本文件与 gfx_metal_internal.h**，
// 内核头零平台类型红线不受影响。
//
// 设计要点：
//   * 每个 PAL 概念 1:1 映射 Metal 概念（见 .ai/modules/pal-apple.md 概念映射表）。
//   * 资源生命周期走 PalPtr + Destroy()（与 IPalResource 契约一致）；本 .mm 用 ARC 管理
//     Objective-C 对象，Destroy() 把成员置 nil 释放并 delete this。
//   * ShaderModule 支持 Platform-Native 源码（MSL，`is_platform_native=true`）；SPIR-V 路径
//     本期未实现（SHADER-001 的 MSL 生成尚未接入），返回 kInternal。
//   * INativeImageImporter（PALA-002）本期不实现，CreateNativeImageImporter 返回 kInternal。
//   * 错误一律 Status，无异常（内核禁用异常）。
//
// 编译：Objective-C++（.mm）+ ARC（-fobjc-arc）。警告集含 -Wconversion/-Wshadow/
// -Wold-style-cast，类型转换一律显式 static_cast。

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "cq/pal/gfx.h"
#include "cq/base/status.h"
#include "gfx_metal_internal.h"

#include <cstdint>
#include <cstring>
#include <mutex>
#include <condition_variable>

namespace cq {

// ---- 格式映射辅助 ----
static uint32_t BytesPerPixel(TextureFormat f) {
    switch (f) {
        case TextureFormat::kR8:        return 1;
        case TextureFormat::kRG8:       return 2;
        case TextureFormat::kRGBA8:     return 4;
        case TextureFormat::kRGBA16F:   return 8;
        case TextureFormat::kR16F:      return 2;
        case TextureFormat::kR32F:      return 4;
        case TextureFormat::kRGBA32F:   return 16;
        default:                        return 4;
    }
}

static MTLPixelFormat ToMTLPixelFormat(TextureFormat f) {
    switch (f) {
        case TextureFormat::kR8:        return MTLPixelFormatR8Unorm;
        case TextureFormat::kRG8:       return MTLPixelFormatRG8Unorm;
        case TextureFormat::kRGBA8:     return MTLPixelFormatRGBA8Unorm;
        case TextureFormat::kRGBA16F:   return MTLPixelFormatRGBA16Float;
        case TextureFormat::kR16F:      return MTLPixelFormatR16Float;
        case TextureFormat::kR32F:      return MTLPixelFormatR32Float;
        case TextureFormat::kRGBA32F:   return MTLPixelFormatRGBA32Float;
        default:                        return MTLPixelFormatRGBA8Unorm;
    }
}

static MTLVertexFormat ToMTLVertexFormat(VertexFormat f) {
    switch (f) {
        case VertexFormat::kFloat32:     return MTLVertexFormatFloat;
        case VertexFormat::kFloat32x2:   return MTLVertexFormatFloat2;
        case VertexFormat::kFloat32x3:   return MTLVertexFormatFloat3;
        case VertexFormat::kFloat32x4:   return MTLVertexFormatFloat4;
        case VertexFormat::kUInt16:      return MTLVertexFormatUShortNormalized;
        case VertexFormat::kUInt16x2:    return MTLVertexFormatUShort2Normalized;
        case VertexFormat::kUInt16x4:    return MTLVertexFormatUShort4Normalized;
        default:                         return MTLVertexFormatFloat;
    }
}

// ===========================================================================
// 资源类（命名与 common.h 的 opaque 句柄 CqXxx 对齐，使 TextureHandle 等即本类指针）
// ===========================================================================

struct CqTexture : public ITexture {
public:
    id<MTLTexture> tex_ = nil;
    TextureDesc desc_{};

    void Destroy() override {
        tex_ = nil;
        desc_ = TextureDesc{};
        delete this;
    }
    void GetDesc(TextureDesc& out) const override { out = desc_; }
    int64_t GetMemoryBytes() const override {
        const int64_t bpp = static_cast<int64_t>(BytesPerPixel(desc_.format));
        return static_cast<int64_t>(desc_.width) * static_cast<int64_t>(desc_.height) *
               bpp * static_cast<int64_t>(desc_.depth_or_layers);
    }
};

struct CqBuffer : public IBuffer {
public:
    id<MTLBuffer> buf_ = nil;
    BufferDesc desc_{};

    void Destroy() override {
        buf_ = nil;
        desc_ = BufferDesc{};
        delete this;
    }
    void GetDesc(BufferDesc& out) const override { out = desc_; }
    int64_t GetMemoryBytes() const override {
        return static_cast<int64_t>(desc_.size_bytes);
    }
    Status Map(void*& out_ptr) override {
        if (buf_ == nil) return Status(StatusCode::kInternal);
        out_ptr = [buf_ contents];
        return Status::Ok();
    }
    void Unmap() override {}
};

struct CqRenderTarget : public IRenderTarget {
public:
    id<MTLDevice> device_ = nil;
    id<MTLTexture> color_tex_ = nil;
    CqTexture* color_wrapper_ = nullptr;  // 由 GetColorTexture 惰性创建；Destroy 时一并释放
    uint32_t w_ = 0;
    uint32_t h_ = 0;
    TextureFormat fmt_ = TextureFormat::kRGBA8;

    void Destroy() override {
        if (color_wrapper_ != nullptr) {
            color_wrapper_->Destroy();
            color_wrapper_ = nullptr;
        }
        color_tex_ = nil;
        device_ = nil;
        delete this;
    }
    TextureHandle GetColorTexture() override {
        if (color_wrapper_ == nullptr) {
            color_wrapper_ = new CqTexture();
            color_wrapper_->tex_ = color_tex_;  // 与 RT 共享同一 MTLTexture（ARC 各自保留引用）
            color_wrapper_->desc_.format = fmt_;
            color_wrapper_->desc_.width = w_;
            color_wrapper_->desc_.height = h_;
            color_wrapper_->desc_.usage = TextureUsage::kRenderTarget;
        }
        return color_wrapper_;
    }
    uint32_t GetWidth() const override { return w_; }
    uint32_t GetHeight() const override { return h_; }
    // 本对象即 opaque 句柄 `CqRenderTarget*`（见 gfx.h 中 Handle() 的缺陷修复说明）。
    RenderTargetHandle Handle() override { return this; }
};

struct CqShaderModule : public IShaderModule {
public:
    id<MTLLibrary> lib_ = nil;
    id<MTLFunction> func_ = nil;

    void Destroy() override {
        func_ = nil;
        lib_ = nil;
        delete this;
    }
};

struct CqPipeline : public IPipeline {
public:
    id<MTLRenderPipelineState> state_ = nil;

    void Destroy() override {
        state_ = nil;
        delete this;
    }
};

struct CqSampler : public ISampler {
public:
    id<MTLSamplerState> state_ = nil;

    void Destroy() override {
        state_ = nil;
        delete this;
    }
};

struct CqFence : public IFence {
public:
    std::mutex mtx_;
    std::condition_variable cv_;
    bool signaled_ = false;

    void Destroy() override { delete this; }

    Status Signal() override {
        {
            std::lock_guard<std::mutex> lk(mtx_);
            signaled_ = true;
        }
        cv_.notify_all();
        return Status::Ok();
    }

    Status Wait(uint64_t timeout_ms) override {
        std::unique_lock<std::mutex> lk(mtx_);
        if (signaled_) return Status::Ok();
        if (timeout_ms == 0) return Status(StatusCode::kIoTimeout);
        const auto rel = std::chrono::milliseconds(static_cast<long>(timeout_ms));
        const bool ok = cv_.wait_for(lk, rel, [this]() { return signaled_; });
        return ok ? Status::Ok() : Status(StatusCode::kIoTimeout);
    }
};

struct CqCommandEncoder : public ICommandEncoder {
public:
    id<MTLCommandBuffer> cb_ = nil;       // 由 CqCommandBuffer 持有，encoder 不释放
    id<MTLRenderCommandEncoder> enc_ = nil;

    void Destroy() override {
        enc_ = nil;
        // cb_ 由 CqCommandBuffer 拥有，这里不释放
        delete this;
    }

    Status BeginRenderPass(RenderTargetHandle target, const float clear_color[4]) override {
        auto* mrt = static_cast<CqRenderTarget*>(target);
        if (mrt == nullptr || mrt->color_tex_ == nil) return Status(StatusCode::kInvalidArgument);

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
        if (enc_ == nil) return Status(StatusCode::kInternal);
        return Status::Ok();
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

    void Draw(uint32_t vertex_count) override {
        if (enc_ != nil) {
            [enc_ drawPrimitives:MTLPrimitiveTypeTriangle
                     vertexStart:0
                     vertexCount:static_cast<NSUInteger>(vertex_count)];
        }
    }

    void DrawIndexed(uint32_t /*index_count*/) override {
        // PAL 接口未提供 SetIndexBuffer，本期索引绘制未实现；Draw 路径覆盖验证用例。
    }

    void End() override {
        if (enc_ != nil) {
            [enc_ endEncoding];
            enc_ = nil;
        }
    }
};

struct CqCommandBuffer : public ICommandBuffer {
public:
    id<MTLCommandQueue> queue_ = nil;
    id<MTLCommandBuffer> cb_ = nil;
    bool committed_ = false;

    void Destroy() override {
        cb_ = nil;
        queue_ = nil;
        delete this;
    }

    Status CreateEncoder(PalPtr<ICommandEncoder>& out_encoder) override {
        if (cb_ == nil) return Status(StatusCode::kInternal);
        auto* e = new CqCommandEncoder();
        e->cb_ = cb_;
        out_encoder = PalPtr<ICommandEncoder>(e);
        return Status::Ok();
    }

    Status Commit() override {
        if (committed_) return Status::Ok();
        if (cb_ == nil) return Status(StatusCode::kInternal);
        [cb_ commit];
        committed_ = true;
        return Status::Ok();
    }

    Status WaitUntilCompleted() override {
        if (cb_ == nil) return Status(StatusCode::kInternal);
        [cb_ waitUntilCompleted];
        if (cb_.status == MTLCommandBufferStatusError) return Status(StatusCode::kInternal);
        return Status::Ok();
    }
};

struct CqCommandQueue : public ICommandQueue {
public:
    id<MTLDevice> device_ = nil;
    id<MTLCommandQueue> queue_ = nil;

    void Destroy() override {
        queue_ = nil;
        device_ = nil;
        delete this;
    }

    Status CreateCommandBuffer(PalPtr<ICommandBuffer>& out_buffer) override {
        if (queue_ == nil) return Status(StatusCode::kInternal);
        id<MTLCommandBuffer> b = [queue_ commandBuffer];
        if (b == nil) return Status(StatusCode::kInternal);
        auto* mb = new CqCommandBuffer();
        mb->queue_ = queue_;
        mb->cb_ = b;
        out_buffer = PalPtr<ICommandBuffer>(mb);
        return Status::Ok();
    }

    Status Submit(ICommandBuffer* buffer) override {
        if (buffer == nullptr) return Status(StatusCode::kInvalidArgument);
        return static_cast<CqCommandBuffer*>(buffer)->Commit();
    }
};

struct CqDevice : public IGraphicsDevice {
public:
    id<MTLDevice> device_ = nil;

    void Destroy() override {
        device_ = nil;
        delete this;
    }

    Status CreateTexture(const TextureDesc& desc, PalPtr<ITexture>& out) override {
        if (device_ == nil) return Status(StatusCode::kInternal);
        const bool is_rt = (static_cast<uint32_t>(desc.usage & TextureUsage::kRenderTarget) != 0u);
        const bool is_sampled = (static_cast<uint32_t>(desc.usage & TextureUsage::kSampled) != 0u);

        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:ToMTLPixelFormat(desc.format)
                                                                width:static_cast<NSUInteger>(desc.width)
                                                               height:static_cast<NSUInteger>(desc.height)
                                                            mipmapped:NO];
        // 渲染目标用 Private（GPU 最优）；需要 CPU 上传（采样源）用 Managed。
        td.storageMode = is_rt ? MTLStorageModePrivate : MTLStorageModeManaged;
        MTLTextureUsage usage = 0;
        if (is_rt) usage |= MTLTextureUsageRenderTarget;
        if (is_sampled) usage |= MTLTextureUsageShaderRead;
        if (usage == 0) usage = MTLTextureUsageShaderRead;
        td.usage = usage;

        id<MTLTexture> tex = [device_ newTextureWithDescriptor:td];
        if (tex == nil) return Status(StatusCode::kInternal);

        auto* t = new CqTexture();
        t->tex_ = tex;
        t->desc_ = desc;
        out = PalPtr<ITexture>(t);
        return Status::Ok();
    }

    Status CreateBuffer(const BufferDesc& desc, PalPtr<IBuffer>& out) override {
        if (device_ == nil) return Status(StatusCode::kInternal);
        if (desc.size_bytes == 0) return Status(StatusCode::kInvalidArgument);
        id<MTLBuffer> buf =
            [device_ newBufferWithLength:static_cast<NSUInteger>(desc.size_bytes)
                                 options:MTLResourceStorageModeShared];
        if (buf == nil) return Status(StatusCode::kInternal);
        auto* b = new CqBuffer();
        b->buf_ = buf;
        b->desc_ = desc;
        out = PalPtr<IBuffer>(b);
        return Status::Ok();
    }

    Status CreateRenderTarget(const RenderTargetDesc& desc, PalPtr<IRenderTarget>& out) override {
        if (device_ == nil) return Status(StatusCode::kInternal);
        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:ToMTLPixelFormat(desc.color_format)
                                                                width:static_cast<NSUInteger>(desc.width)
                                                               height:static_cast<NSUInteger>(desc.height)
                                                            mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [device_ newTextureWithDescriptor:td];
        if (tex == nil) return Status(StatusCode::kInternal);

        auto* rt = new CqRenderTarget();
        rt->device_ = device_;
        rt->color_tex_ = tex;
        rt->w_ = desc.width;
        rt->h_ = desc.height;
        rt->fmt_ = desc.color_format;
        out = PalPtr<IRenderTarget>(rt);
        return Status::Ok();
    }

    Status CreateShaderModule(const ShaderModuleDesc& desc, PalPtr<IShaderModule>& out) override {
        if (device_ == nil) return Status(StatusCode::kInternal);
        if (!desc.is_platform_native) {
            // SPIR-V -> MSL 转译尚未接入（SHADER-001），本期仅支持 Platform-Native MSL 源码。
            return Status(StatusCode::kInternal);
        }
        const char* src_ptr = static_cast<const char*>(desc.code);
        if (src_ptr == nullptr) return Status(StatusCode::kInvalidArgument);
        std::string src = (desc.code_size > 0u)
                              ? std::string(src_ptr, desc.code_size)
                              : std::string(src_ptr);

        NSError* err = nil;
        id<MTLLibrary> lib = [device_ newLibraryWithSource:
                                 [NSString stringWithUTF8String:src.c_str()]
                                                  options:nil
                                                    error:&err];
        if (lib == nil) return Status(StatusCode::kInternal);

        const MTLFunctionType want =
            (desc.stage == ShaderStage::kFragment) ? MTLFunctionTypeFragment
            : (desc.stage == ShaderStage::kCompute) ? MTLFunctionTypeKernel
                                                   : MTLFunctionTypeVertex;
        id<MTLFunction> fn = nil;
        for (NSString* name in lib.functionNames) {
            id<MTLFunction> f = [lib newFunctionWithName:name];
            if (f != nil && f.functionType == want) {
                fn = f;
                break;
            }
        }
        if (fn == nil) return Status(StatusCode::kInternal);

        auto* m = new CqShaderModule();
        m->lib_ = lib;
        m->func_ = fn;
        out = PalPtr<IShaderModule>(m);
        return Status::Ok();
    }

    Status CreatePipeline(const PipelineDesc& desc, PalPtr<IPipeline>& out) override {
        if (device_ == nil) return Status(StatusCode::kInternal);
        auto* vm = static_cast<CqShaderModule*>(desc.vertex_shader);
        auto* fm = static_cast<CqShaderModule*>(desc.fragment_shader);
        if (vm == nullptr || fm == nullptr || vm->func_ == nil || fm->func_ == nil) {
            return Status(StatusCode::kInvalidArgument);
        }

        // 顶点布局 -> MTLVertexDescriptor（所有属性来自 slot 0 的顶点缓冲）。
        MTLVertexDescriptor* vd = [MTLVertexDescriptor new];
        for (uint32_t i = 0; i < desc.vertex_layout.attr_count; ++i) {
            const VertexAttribute& a = desc.vertex_layout.attrs[i];
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
        if (st == nil) return Status(StatusCode::kInternal);

        auto* p = new CqPipeline();
        p->state_ = st;
        out = PalPtr<IPipeline>(p);
        return Status::Ok();
    }

    Status CreateSampler(const SamplerDesc& desc, PalPtr<ISampler>& out) override {
        if (device_ == nil) return Status(StatusCode::kInternal);
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
        if (s == nil) return Status(StatusCode::kInternal);
        auto* sm = new CqSampler();
        sm->state_ = s;
        out = PalPtr<ISampler>(sm);
        return Status::Ok();
    }

    Status CreateFence(PalPtr<IFence>& out) override {
        out = PalPtr<IFence>(new CqFence());
        return Status::Ok();
    }

    Status CreateCommandQueue(PalPtr<ICommandQueue>& out) override {
        if (device_ == nil) return Status(StatusCode::kInternal);
        id<MTLCommandQueue> q = [device_ newCommandQueue];
        if (q == nil) return Status(StatusCode::kInternal);
        auto* cq = new CqCommandQueue();
        cq->device_ = device_;
        cq->queue_ = q;
        out = PalPtr<ICommandQueue>(cq);
        return Status::Ok();
    }

    Status CreateNativeImageImporter(PalPtr<INativeImageImporter>& /*out*/) override {
        // PALA-002 任务：CVPixelBuffer -> CVMetalTexture 零拷贝。本期不实现。
        return Status(StatusCode::kInternal);
    }

    Status WaitFence(IFence* fence, uint64_t timeout_ms) override {
        if (fence == nullptr) return Status(StatusCode::kInvalidArgument);
        return static_cast<CqFence*>(fence)->Wait(timeout_ms);
    }
};

// ===========================================================================
// 工厂 + 内部辅助
// ===========================================================================

Status CreateGraphicsDevice(const GraphicsDeviceDesc& /*desc*/, PalPtr<IGraphicsDevice>& out_device) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev == nil) return Status(StatusCode::kInternal);
    auto* d = new CqDevice();
    d->device_ = dev;
    out_device = PalPtr<IGraphicsDevice>(d);
    return Status::Ok();
}

}  // namespace cq

namespace cq {
namespace apple {

Status ReadRenderTargetPixels(IRenderTarget* rt,
                              uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                              void* out_rgba8, size_t out_size) {
    if (rt == nullptr || out_rgba8 == nullptr) return Status(StatusCode::kInvalidArgument);
    auto* mrt = static_cast<CqRenderTarget*>(rt);
    if (mrt->device_ == nil || mrt->color_tex_ == nil) return Status(StatusCode::kInternal);

    const NSUInteger bpr = static_cast<NSUInteger>(w) * 4u;
    const NSUInteger img_bytes = bpr * static_cast<NSUInteger>(h);
    if (static_cast<NSUInteger>(out_size) < img_bytes) return Status(StatusCode::kInvalidArgument);

    id<MTLBuffer> buf = [mrt->device_ newBufferWithLength:img_bytes
                                                 options:MTLResourceStorageModeShared];
    if (buf == nil) return Status(StatusCode::kInternal);

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
    if (src == nullptr) return Status(StatusCode::kInternal);
    std::memcpy(out_rgba8, src, static_cast<size_t>(img_bytes));
    return Status::Ok();
}

Status UploadTextureData(ITexture* tex, const void* data, size_t bytes) {
    if (tex == nullptr || data == nullptr) return Status(StatusCode::kInvalidArgument);
    auto* mt = static_cast<CqTexture*>(tex);
    if (mt->tex_ == nil) return Status(StatusCode::kInternal);
    const uint32_t w = mt->desc_.width;
    const uint32_t h = mt->desc_.height;
    const size_t need = static_cast<size_t>(w) * static_cast<size_t>(h) * 4u;
    if (bytes < need) return Status(StatusCode::kInvalidArgument);
    const NSUInteger bpr = static_cast<NSUInteger>(w) * 4u;
    [mt->tex_ replaceRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(w), static_cast<NSUInteger>(h))
                 mipmapLevel:0
                   withBytes:data
                 bytesPerRow:bpr];
    return Status::Ok();
}

// ---- 句柄桥接（CqXxx 继承 Ixxx，安全下行转换）----
ShaderModuleHandle   ToShaderHandle(IShaderModule* p)   { return static_cast<CqShaderModule*>(p); }
PipelineHandle      ToPipelineHandle(IPipeline* p)       { return static_cast<CqPipeline*>(p); }
BufferHandle        ToBufferHandle(IBuffer* p)           { return static_cast<CqBuffer*>(p); }
TextureHandle       ToTextureHandle(ITexture* p)         { return static_cast<CqTexture*>(p); }
SamplerHandle       ToSamplerHandle(ISampler* p)         { return static_cast<CqSampler*>(p); }
RenderTargetHandle  ToRenderTargetHandle(IRenderTarget* p){ return static_cast<CqRenderTarget*>(p); }

}  // namespace apple
}  // namespace cq
