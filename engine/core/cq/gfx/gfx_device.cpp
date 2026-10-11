// ChuanqiCut — GFX 设备实现（GFX-002 最小落地）
//
// 范围：**只**实现 IGfxDevice / IGfxEncoder，直连 Platform，**不引入 RenderGraph**。
//
// 为什么不做 RenderGraph（RENDER-001）：
//   预览只需要"渲染一帧"。RenderGraph 的节点图 / 依赖分析 / pass 调度是更重的机制，
//   等真有多 pass 合成需求（滤镜链、转场合成）时再补，避免现在背上复杂度。
//   届时本文件的 RenderFrame 应改为走 RenderGraph，IGfxDevice 接口不变。
//
// 硬约束（与 gfx_device.h 一致）：
//   * 零平台类型：只调 Platform 接口，不出现 Metal/Vulkan/GLES 类型。
//   * 内核禁用异常：错误一律 Status。
//
// 尚未实现（明确留白，不要假装已有）：
//   * ITexturePool 池化（GFX-002 的一部分） —— 未注入池时 AcquireTexture 直连 Platform，
//     不做任何预算记账。注入后才走池。

#include "cq/gfx/gfx_device.h"

#include <utility>  // std::move

namespace cq {
namespace {

// ===========================================================================
// IGfxEncoder 实现：1:1 转发到 Platform ICommandEncoder
// ===========================================================================
// 生命周期由 RenderFrame 内的 PlatformPtr<ICommandEncoder> 持有，本类**不拥有**它。
class GfxEncoderImpl final : public IGfxEncoder {
public:
    explicit GfxEncoderImpl(ICommandEncoder* enc) : enc_(enc) {}

    void SetPipeline(PipelineHandle pipeline) override { enc_->SetPipeline(pipeline); }
    void SetVertexBuffer(BufferHandle buffer, uint32_t slot) override {
        enc_->SetVertexBuffer(buffer, slot);
    }
    void SetTexture(TextureHandle texture, uint32_t binding) override {
        enc_->SetTexture(texture, binding);
    }
    void SetSampler(SamplerHandle sampler, uint32_t binding) override {
        enc_->SetSampler(sampler, binding);
    }
    void SetViewport(float x, float y, float width, float height) override {
        enc_->SetViewport(x, y, width, height);
    }
    void Draw(uint32_t vertex_count) override { enc_->Draw(vertex_count); }
    void DrawIndexed(uint32_t index_count) override { enc_->DrawIndexed(index_count); }

    // End 幂等：client 可能自己调 End，RenderFrame 收尾时也会调一次。
    // Platform 层的重复 End 语义未定义，故在这里兜底，避免出现"取决于调用方"的行为。
    void End() override {
        if (!ended_) {
            enc_->End();
            ended_ = true;
        }
    }

    ICommandEncoder* PlatformEncoder() override { return enc_; }

    void Destroy() override {}

private:
    ICommandEncoder* enc_;
    bool ended_ = false;
};

// ===========================================================================
// IGfxDevice 实现
// ===========================================================================
class GfxDeviceImpl final : public IGfxDevice {
public:
    explicit GfxDeviceImpl(PlatformPtr<IGraphicsDevice> platform) : platform_(std::move(platform)) {}

    IGraphicsDevice* PlatformDevice() override { return platform_.get(); }

    Status CreateRenderTarget(const RenderTargetDesc& desc,
                              PlatformPtr<IRenderTarget>& out) override {
        return platform_->CreateRenderTarget(desc, out);
    }

    // 命令队列**按设备复用**（UIA-010 子步骤 5 改）。
    //
    // 原实现每帧 `CreateCommandQueue` 一次。两处代价：
    //   (1) Metal 上等价于每帧 `-newCommandQueue`，纯属无谓开销；
    //   (2) 更要命的是它让「UI 侧 blit 复用同一条队列」无从谈起 —— 队列每帧都在换，
    //       跨队列的资源先后又得显式同步。复用之后，顺序由 commit 顺序天然保证。
    Status EnsureQueue() {
        if (queue_) return Status::Ok();
        return platform_->CreateCommandQueue(queue_);
    }

    void* SharedQueueHandle() override {
        if (!EnsureQueue().IsOk() || !queue_) return nullptr;
        return queue_->NativeHandle();
    }

    Status AcquireTexture(const TextureDesc& desc, PlatformPtr<ITexture>& out) override {
        // 未注入池 → 直连 Platform。**不做预算记账**（池化与预算属 GFX-002 余下部分）。
        if (pool_ != nullptr) return pool_->Acquire(desc, out);
        return platform_->CreateTexture(desc, out);
    }

    void ReleaseTexture(ITexture* tex) override {
        if (tex == nullptr) return;
        if (pool_ != nullptr) {
            pool_->Release(tex);
            return;
        }
        tex->Destroy();
    }

    Status CreateShaderModule(const ShaderModuleDesc& desc,
                              PlatformPtr<IShaderModule>& out) override {
        return platform_->CreateShaderModule(desc, out);
    }
    Status CreatePipeline(const PipelineDesc& desc, PlatformPtr<IPipeline>& out) override {
        return platform_->CreatePipeline(desc, out);
    }
    Status CreateSampler(const SamplerDesc& desc, PlatformPtr<ISampler>& out) override {
        return platform_->CreateSampler(desc, out);
    }
    Status CreateNativeImageImporter(PlatformPtr<INativeImageImporter>& out) override {
        return platform_->CreateNativeImageImporter(out);
    }

    Status RenderFrame(const FrameContext& ctx, IRenderTarget* target,
                       IFrameEncoderClient& client, const CancelToken& token) override {
        if (target == nullptr) return Status(StatusCode::kInvalidArgument);

        // queue 按设备复用（见 EnsureQueue 注释）；buffer/encoder 仍每帧新建 ——
        // 命令缓冲本就是"一帧一个"的对象，池化它带来的收益远小于复杂度。
        Status st = EnsureQueue();
        if (!st.IsOk()) return st;

        PlatformPtr<ICommandBuffer> cb;
        st = queue_->CreateCommandBuffer(cb);
        if (!st.IsOk()) return st;

        PlatformPtr<ICommandEncoder> enc;
        st = cb->CreateEncoder(enc);
        if (!st.IsOk()) return st;

        st = enc->BeginRenderPass(target->Handle(), clear_color_);
        if (!st.IsOk()) return st;

        GfxEncoderImpl gfx_encoder(enc.get());
        st = client.Encode(gfx_encoder, ctx, token);

        // 无论 client 是否自己调过 End，这里兜底收尾（End 幂等）。
        gfx_encoder.End();

        // client 报错时仍要把已编码的命令提交掉吗？
        // 不提交：GPU 侧不会有半截渲染结果，语义更干净；错误信息由返回值传达。
        if (st.IsError()) return st;

        st = cb->Commit();
        if (!st.IsOk()) return st;

        return cb->WaitUntilCompleted();
    }

    void SetTexturePool(ITexturePool* pool) override { pool_ = pool; }

private:
    PlatformPtr<IGraphicsDevice> platform_;
    PlatformPtr<ICommandQueue> queue_;  // 复用（UIA-010 子步骤 5）；同时供 UI 侧 blit 共享
    ITexturePool* pool_ = nullptr;

    // 清屏色。IGfxDevice 接口没有清屏色参数（GFX-001 定接口时未考虑），
    // 故由本实现持有默认值；RenderGraph 落地后应由 pass 描述携带。
    float clear_color_[4] = {0.0f, 0.0f, 0.0f, 1.0f};
};

}  // namespace

Status CreateGfxDevice(PlatformPtr<IGraphicsDevice>& platform_device, IGfxDevice*& out_device) {
    if (!platform_device) return Status(StatusCode::kInvalidArgument);

    // 接管 Platform 设备所有权：调用方传进来的 PlatformPtr 会被移空，
    // 避免"GFX 设备还活着但底层 Platform 设备已被销毁"的悬垂。
    // 内核 -fno-exceptions：分配必须 nothrow，失败按资源不足返回（CODESTYLE §2）。
    out_device = new (std::nothrow) GfxDeviceImpl(std::move(platform_device));
    if (!out_device) return Status(StatusCode::kResourceExhausted);
    return Status::Ok();
}

}  // namespace cq
