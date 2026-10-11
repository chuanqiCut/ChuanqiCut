// ChuanqiCut — Apple 全屏拷贝 pass（Platform-Native shader 路径）
//
// 实现 Platform 契约 `cq::CreateBlitPass`（core/include/cq/platform/gfx.h）。
// MSL 源码在 platform/apple/shaders/blit_fullscreen_msl.h，不进 core。
//
// 为什么本文件在 platform/apple 而不是 core：平台原生 shader 按红线 #6 只允许出现在
// platform/<platform>/；且 Platform 不能反向依赖 GFX 层，故 ChqIBlitPass 定义也落在 Platform。

#include <cstring>  // std::memcpy / std::strlen

#include "cq/platform/chq_gfx.h"
#include "gfx_metal_internal.h"  // ToShaderHandle / ToPipelineHandle / ToBufferHandle / ToSamplerHandle
#include "shaders/blit_fullscreen_msl.h"

namespace cq {
namespace {

class AppleBlitPass final : public ChqIBlitPass {
public:
    AppleBlitPass(ChqIGraphicsDevice* device, ChqTextureFormat target_format)
        : device_(device), target_format_(target_format) {}

    ChqStatus Encode(ChqICommandEncoder& encoder, TextureHandle src) override {
        if (src == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
        ChqStatus s = EnsureResources();
        if (!s.IsOk()) return s;
        encoder.SetPipeline(pipeline_handle_);
        encoder.SetVertexBuffer(vbuf_handle_, 0);
        encoder.SetTexture(src, 0);
        encoder.SetSampler(sampler_handle_, 0);
        encoder.Draw(kVertexCount);
        return ChqStatus::Ok();
    }

    void Destroy() override { delete this; }

private:
    // 资源懒建：shader / 管线 / 顶点缓冲 / 采样器只需建一次，之后每帧复用。
    // 放首次 Encode 而非构造期，是为了把「GPU 资源创建失败」作为 ChqStatus 如实传回
    // （构造期失败没有合适的表达途径）。
    ChqStatus EnsureResources() {
        if (ready_) return ChqStatus::Ok();
        if (device_ == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

        ChqShaderModuleDesc vd;
        vd.stage = ChqShaderStage::kVertex;
        vd.code = static_cast<const void*>(apple::shaders::kBlitVertMsl);
        vd.code_size = std::strlen(apple::shaders::kBlitVertMsl);
        vd.is_platform_native = true;  // MSL 源，非 SPIR-V
        ChqStatus s = device_->CreateShaderModule(vd, vs_);
        if (!s.IsOk()) return s;
        if (!vs_) return ChqStatus(ChqStatusCode::kInternal);

        ChqShaderModuleDesc fd = vd;
        fd.stage = ChqShaderStage::kFragment;
        fd.code = static_cast<const void*>(apple::shaders::kBlitFragMsl);
        fd.code_size = std::strlen(apple::shaders::kBlitFragMsl);
        s = device_->CreateShaderModule(fd, fs_);
        if (!s.IsOk()) return s;
        if (!fs_) return ChqStatus(ChqStatusCode::kInternal);

        ChqBufferDesc bd;
        bd.usage = ChqBufferUsage::kVertex;
        bd.size_bytes = sizeof(apple::shaders::kBlitVerts);
        s = device_->CreateBuffer(bd, vbuf_);
        if (!s.IsOk()) return s;
        if (!vbuf_) return ChqStatus(ChqStatusCode::kInternal);
        void* mapped = nullptr;
        s = vbuf_->Map(mapped);
        if (!s.IsOk()) return s;
        if (mapped == nullptr) return ChqStatus(ChqStatusCode::kInternal);
        std::memcpy(mapped, apple::shaders::kBlitVerts, sizeof(apple::shaders::kBlitVerts));
        vbuf_->Unmap();

        ChqSamplerDesc sd;
        sd.linear_filter = true;
        sd.clamp_to_edge = true;
        s = device_->CreateSampler(sd, sampler_);
        if (!s.IsOk()) return s;
        if (!sampler_) return ChqStatus(ChqStatusCode::kInternal);

        ChqPipelineDesc pd;
        pd.vertex_shader = apple::ToShaderHandle(vs_.get());
        pd.fragment_shader = apple::ToShaderHandle(fs_.get());
        pd.target_format = target_format_;
        pd.vertex_layout.stride = 16;  // pos.xy + uv.xy
        pd.vertex_layout.attr_count = 2;
        // location 必须对应 MSL 的 [[attribute(n)]]：pos=0 / uv=1。
        // 写成 0/0 会让 CreatePipeline 失败（GFX-002 踩过这个坑）。
        pd.vertex_layout.attrs[0] = ChqVertexAttribute{0, 0, ChqVertexFormat::kFloat32x2};
        pd.vertex_layout.attrs[1] = ChqVertexAttribute{1, 8, ChqVertexFormat::kFloat32x2};
        s = device_->CreatePipeline(pd, pipeline_);
        if (!s.IsOk()) return s;
        if (!pipeline_) return ChqStatus(ChqStatusCode::kInternal);

        pipeline_handle_ = apple::ToPipelineHandle(pipeline_.get());
        vbuf_handle_ = apple::ToBufferHandle(vbuf_.get());
        sampler_handle_ = apple::ToSamplerHandle(sampler_.get());
        ready_ = true;
        return ChqStatus::Ok();
    }

    static constexpr uint32_t kVertexCount = 3;  // 全屏三角形

    ChqIGraphicsDevice* device_ = nullptr;
    ChqTextureFormat target_format_ = ChqTextureFormat::kRGBA8;
    ChqPlatformPtr<ChqIShaderModule> vs_;
    ChqPlatformPtr<ChqIShaderModule> fs_;
    ChqPlatformPtr<ChqIPipeline> pipeline_;
    ChqPlatformPtr<ChqIBuffer> vbuf_;
    ChqPlatformPtr<ChqISampler> sampler_;
    PipelineHandle pipeline_handle_ = nullptr;
    BufferHandle vbuf_handle_ = nullptr;
    SamplerHandle sampler_handle_ = nullptr;
    bool ready_ = false;
};

}  // namespace

ChqStatus CreateBlitPass(ChqIGraphicsDevice* device, ChqTextureFormat target_format,
                      ChqPlatformPtr<ChqIBlitPass>& out_pass) {
    if (device == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    out_pass = ChqPlatformPtr<ChqIBlitPass>(new AppleBlitPass(device, target_format));
    return ChqStatus::Ok();
}

}  // namespace cq
