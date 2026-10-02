// ChuanqiCut — Apple 全屏拷贝 pass 实现（MSL / Platform-Native）
//
// 见 blit_pass.h 与 shaders/blit_fullscreen_msl.h 的分层说明：
// 这是「无 Portable shader 可用」时的能力缺失降级路径，不是平台特化优化。

#include "blit_pass.h"

#include <cstring>  // std::memcpy / std::strlen

#include "gfx_metal_internal.h"  // ToShaderHandle / ToPipelineHandle / ToBufferHandle / ToSamplerHandle
#include "shaders/blit_fullscreen_msl.h"

namespace cq {
namespace apple {
namespace {

class AppleBlitPass final : public IBlitPass {
public:
    AppleBlitPass(IGfxDevice* gfx, TextureFormat target_format)
        : gfx_(gfx), target_format_(target_format) {}

    Status Encode(IGfxEncoder& encoder, TextureHandle src) override {
        if (src == nullptr) return Status(StatusCode::kInvalidArgument);
        Status s = EnsureResources();
        if (!s.IsOk()) return s;
        encoder.SetPipeline(pipeline_handle_);
        encoder.SetVertexBuffer(vbuf_handle_, 0);
        encoder.SetTexture(src, 0);
        encoder.SetSampler(sampler_handle_, 0);
        encoder.Draw(kVertexCount);
        return Status::Ok();
    }

private:
    // 资源懒建：shader / 管线 / 顶点缓冲 / 采样器只需建一次，之后每帧复用。
    // 放在首次 Encode 而非构造时，是因为构造期失败只能靠返回值以外的方式表达，
    // 而懒建可以把「GPU 资源创建失败」如实作为 Status 传回调用方。
    Status EnsureResources() {
        if (ready_) return Status::Ok();
        if (gfx_ == nullptr) return Status(StatusCode::kInvalidArgument);

        ShaderModuleDesc vd;
        vd.stage = ShaderStage::kVertex;
        vd.code = static_cast<const void*>(shaders::kBlitVertMsl);
        vd.code_size = std::strlen(shaders::kBlitVertMsl);
        vd.is_platform_native = true;  // MSL 源，非 SPIR-V
        Status s = gfx_->CreateShaderModule(vd, vs_);
        if (!s.IsOk()) return s;
        if (!vs_) return Status(StatusCode::kInternal);

        ShaderModuleDesc fd = vd;
        fd.stage = ShaderStage::kFragment;
        fd.code = static_cast<const void*>(shaders::kBlitFragMsl);
        fd.code_size = std::strlen(shaders::kBlitFragMsl);
        s = gfx_->CreateShaderModule(fd, fs_);
        if (!s.IsOk()) return s;
        if (!fs_) return Status(StatusCode::kInternal);

        // 顶点缓冲经 PAL 设备创建（IGfxDevice 未暴露 CreateBuffer，按接口说明走 PalDevice）。
        IGraphicsDevice* pal = gfx_->PalDevice();
        if (pal == nullptr) return Status(StatusCode::kInternal);
        BufferDesc bd;
        bd.usage = BufferUsage::kVertex;
        bd.size_bytes = sizeof(shaders::kBlitVerts);
        s = pal->CreateBuffer(bd, vbuf_);
        if (!s.IsOk()) return s;
        if (!vbuf_) return Status(StatusCode::kInternal);
        void* mapped = nullptr;
        s = vbuf_->Map(mapped);
        if (!s.IsOk()) return s;
        if (mapped == nullptr) return Status(StatusCode::kInternal);
        std::memcpy(mapped, shaders::kBlitVerts, sizeof(shaders::kBlitVerts));
        vbuf_->Unmap();

        SamplerDesc sd;
        sd.linear_filter = true;
        sd.clamp_to_edge = true;
        s = gfx_->CreateSampler(sd, sampler_);
        if (!s.IsOk()) return s;
        if (!sampler_) return Status(StatusCode::kInternal);

        PipelineDesc pd;
        pd.vertex_shader = ToShaderHandle(vs_.get());
        pd.fragment_shader = ToShaderHandle(fs_.get());
        pd.target_format = target_format_;
        pd.vertex_layout.stride = 16;  // pos.xy + uv.xy
        pd.vertex_layout.attr_count = 2;
        // location 必须对应 MSL 的 [[attribute(n)]]：pos=0 / uv=1。
        // 写成 0/0 会让 CreatePipeline 失败（GFX-002 踩过这个坑）。
        pd.vertex_layout.attrs[0] = VertexAttribute{0, 0, VertexFormat::kFloat32x2};
        pd.vertex_layout.attrs[1] = VertexAttribute{1, 8, VertexFormat::kFloat32x2};
        s = gfx_->CreatePipeline(pd, pipeline_);
        if (!s.IsOk()) return s;
        if (!pipeline_) return Status(StatusCode::kInternal);

        pipeline_handle_ = ToPipelineHandle(pipeline_.get());
        vbuf_handle_ = ToBufferHandle(vbuf_.get());
        sampler_handle_ = ToSamplerHandle(sampler_.get());
        ready_ = true;
        return Status::Ok();
    }

    static constexpr uint32_t kVertexCount = 3;  // 全屏三角形

    IGfxDevice* gfx_;
    TextureFormat target_format_;
    PalPtr<IShaderModule> vs_;
    PalPtr<IShaderModule> fs_;
    PalPtr<IPipeline> pipeline_;
    PalPtr<IBuffer> vbuf_;
    PalPtr<ISampler> sampler_;
    PipelineHandle pipeline_handle_ = nullptr;
    BufferHandle vbuf_handle_ = nullptr;
    SamplerHandle sampler_handle_ = nullptr;
    bool ready_ = false;
};

}  // namespace

std::unique_ptr<IBlitPass> CreateBlitPass(IGfxDevice* gfx, TextureFormat target_format) {
    return std::unique_ptr<IBlitPass>(new AppleBlitPass(gfx, target_format));
}

}  // namespace apple
}  // namespace cq
