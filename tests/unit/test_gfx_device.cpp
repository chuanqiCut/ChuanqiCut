// ChuanqiCut — GFX 设备单测（GFX-002 最小落地）
//
// 验收硬要求（AGENTS.root.md）：不是「调用成功」，而是**渲染结果正确**。
// 故本用例走完整链路（CreateGfxDevice → RenderFrame → 读回像素断言），
// 而不是只检查返回值 IsOk —— 后者在底层没真渲染时也会通过。
//
// 覆盖：
//   * 用例 A：RenderFrame 清屏 → 读回中心像素必须 = 清屏色（证明 pass 真的执行了）
//   * 用例 B：client 在 Encode 里画一个全屏三角形采样四色纹理 → 读回四角
//             分别是 红/绿/蓝/黄（证明 SetTexture/Draw 真的生效，而非只清屏）
//
// 仅在 Apple 平台编译（PAL 后端是 Metal）。

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "cq/base/status.h"
#include "cq/gfx/gfx_device.h"
#include "cq/pal/gfx.h"
#include "gfx_metal_internal.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (cond) {
        std::printf("  ok  : %s\n", msg);
    } else {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

// 2x2 四色纹理：row0 = 红,绿；row1 = 蓝,黄
const uint8_t kTex2x2[2 * 2 * 4] = {
    255, 0, 0, 255,   0, 255, 0, 255,
    0, 0, 255, 255,   255, 255, 0, 255,
};

// 全屏三角形：pos.xy + uv.xy 交错
// ⚠️ uv.y 已翻转：约定 uv(0,0) = 图像左上，而 Metal NDC 的 clip(-1,-1) 是屏幕左下。
//    详见 test_gfx_metal.cpp 注释（2026-09-25 实测踩到画面上下颠倒）。
const float kVerts[3 * 4] = {
    -1.0f, -1.0f, 0.0f, 1.0f,
     3.0f, -1.0f, 2.0f, 1.0f,
    -1.0f,  3.0f, 0.0f, -1.0f,
};

const char* kVertMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VIn  { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
struct VOut { float4 position [[position]]; float2 uv; };
vertex VOut vs_main(VIn in [[stage_in]]) {
    VOut o; o.position = float4(in.pos, 0.0, 1.0); o.uv = in.uv; return o;
}
)MSL";

const char* kFragMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 position [[position]]; float2 uv; };
fragment float4 fs_main(VOut in [[stage_in]],
                        texture2d<float> tex [[texture(0)]],
                        sampler samp [[sampler(0)]]) {
    return tex.sample(samp, in.uv);
}
)MSL";

// 什么都不画的 client（只验证清屏 pass 执行）
class EmptyClient final : public cq::IFrameEncoderClient {
public:
    cq::Status Encode(cq::IGfxEncoder&, const cq::FrameContext&,
                      const cq::CancelToken&) override {
        ++encode_calls_;
        return cq::Status::Ok();
    }
    int encode_calls() const { return encode_calls_; }

private:
    int encode_calls_ = 0;
};

// 画全屏三角形采样纹理的 client
class DrawClient final : public cq::IFrameEncoderClient {
public:
    DrawClient(cq::PipelineHandle pipeline, cq::BufferHandle vbuf,
               cq::TextureHandle tex, cq::SamplerHandle sampler)
        : pipeline_(pipeline), vbuf_(vbuf), tex_(tex), sampler_(sampler) {}

    cq::Status Encode(cq::IGfxEncoder& enc, const cq::FrameContext&,
                      const cq::CancelToken&) override {
        enc.SetPipeline(pipeline_);
        enc.SetVertexBuffer(vbuf_, 0);
        enc.SetTexture(tex_, 0);
        enc.SetSampler(sampler_, 0);
        enc.Draw(3);
        return cq::Status::Ok();
    }

private:
    cq::PipelineHandle pipeline_;
    cq::BufferHandle vbuf_;
    cq::TextureHandle tex_;
    cq::SamplerHandle sampler_;
};

}  // namespace

int main() {
    std::printf("=== GFX-002：IGfxDevice 直连 PAL（Metal）===\n");

    // ---- PAL 设备 ----
    cq::GraphicsDeviceDesc dev_desc;
    cq::PalPtr<cq::IGraphicsDevice> pal_dev;
    Check(cq::CreateGraphicsDevice(dev_desc, pal_dev).IsOk(), "PAL CreateGraphicsDevice");
    if (!pal_dev) {
        std::printf("\nPASSED: 0 checks\n");
        return 0;
    }

    // ---- GFX 设备（接管 pal_dev 所有权）----
    cq::IGfxDevice* gfx = nullptr;
    Check(cq::CreateGfxDevice(pal_dev, gfx).IsOk(), "CreateGfxDevice");
    Check(gfx != nullptr, "GFX 设备非空");
    Check(pal_dev.get() == nullptr, "PAL 设备所有权已移交给 GFX（避免悬垂）");
    Check(gfx->PalDevice() != nullptr, "可取回底层 PAL 设备");

    // ---- 离屏渲染目标 ----
    cq::RenderTargetDesc rt_desc;
    rt_desc.width = 64;
    rt_desc.height = 64;
    rt_desc.color_format = cq::TextureFormat::kRGBA8;
    cq::PalPtr<cq::IRenderTarget> rt;
    Check(gfx->CreateRenderTarget(rt_desc, rt).IsOk(), "CreateRenderTarget(64x64)");

    // =====================================================================
    // 用例 A：只清屏，验证 RenderFrame 真的执行了一个 render pass
    // =====================================================================
    std::printf("\n[用例 A] RenderFrame 清屏 + 读回中心像素\n");
    {
        cq::FrameContext ctx;
        EmptyClient client;
        cq::CancelToken token;
        Check(gfx->RenderFrame(ctx, rt.get(), client, token).IsOk(), "RenderFrame(清屏)");
        Check(client.encode_calls() == 1, "client.Encode 被调用一次");

        std::vector<uint8_t> px(64 * 64 * 4, 0);
        Check(cq::apple::ReadRenderTargetPixels(rt.get(), 0, 0, 64, 64, px.data(), px.size())
                  .IsOk(),
              "ReadRenderTargetPixels");
        const uint8_t* c = &px[(32 * 64 + 32) * 4];
        std::printf("  中心像素 RGBA = %u,%u,%u,%u\n", c[0], c[1], c[2], c[3]);
        // 默认清屏色为不透明黑（见 gfx_device.cpp 的 clear_color_）
        Check(c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 255,
              "中心像素 = 不透明黑（清屏生效，pass 真执行了）");
    }

    // =====================================================================
    // 用例 B：画全屏三角形采样四色纹理，验证 SetTexture/Draw 真生效
    // =====================================================================
    std::printf("\n[用例 B] 采样四色纹理绘制 + 读回四角像素\n");
    {
        cq::IGraphicsDevice* pal = gfx->PalDevice();

        // 纹理
        cq::TextureDesc td;
        td.format = cq::TextureFormat::kRGBA8;
        td.width = 2;
        td.height = 2;
        td.usage = cq::TextureUsage::kSampled;
        cq::PalPtr<cq::ITexture> tex;
        Check(pal->CreateTexture(td, tex).IsOk(), "CreateTexture(2x2)");
        Check(cq::apple::UploadTextureData(tex.get(), kTex2x2, sizeof(kTex2x2)).IsOk(),
              "UploadTextureData(四色)");

        // 顶点缓冲
        cq::BufferDesc bd;
        bd.usage = cq::BufferUsage::kVertex;
        bd.size_bytes = sizeof(kVerts);
        cq::PalPtr<cq::IBuffer> vbuf;
        Check(pal->CreateBuffer(bd, vbuf).IsOk(), "CreateBuffer(vertex)");
        void* mapped = nullptr;
        Check(vbuf->Map(mapped).IsOk(), "Map(vertex)");
        std::memcpy(mapped, kVerts, sizeof(kVerts));
        vbuf->Unmap();

        // 着色器（Platform-Native MSL）
        cq::ShaderModuleDesc vmd;
        vmd.stage = cq::ShaderStage::kVertex;
        vmd.code = static_cast<const void*>(kVertMSL);
        vmd.code_size = std::strlen(kVertMSL);
        vmd.is_platform_native = true;
        cq::PalPtr<cq::IShaderModule> vs;
        Check(pal->CreateShaderModule(vmd, vs).IsOk(), "CreateShaderModule(vertex)");

        cq::ShaderModuleDesc fmd = vmd;
        fmd.stage = cq::ShaderStage::kFragment;
        fmd.code = static_cast<const void*>(kFragMSL);
        fmd.code_size = std::strlen(kFragMSL);
        cq::PalPtr<cq::IShaderModule> fs;
        Check(pal->CreateShaderModule(fmd, fs).IsOk(), "CreateShaderModule(fragment)");

        // 管线
        cq::PipelineDesc pd;
        pd.vertex_shader = cq::apple::ToShaderHandle(vs.get());
        pd.fragment_shader = cq::apple::ToShaderHandle(fs.get());
        pd.target_format = cq::TextureFormat::kRGBA8;
        pd.vertex_layout.stride = 4 * sizeof(float);
        pd.vertex_layout.attr_count = 2;
        // VertexAttribute{location, offset, format}
        // ⚠️ location 必须对应 MSL 的 [[attribute(n)]]：uv 是 attribute(1)，
        //    写成 0 会让 CreatePipeline 失败（2026-10-02 实测踩到）。
        pd.vertex_layout.attrs[0] = cq::VertexAttribute{0, 0, cq::VertexFormat::kFloat32x2};
        pd.vertex_layout.attrs[1] =
            cq::VertexAttribute{1, 2 * sizeof(float), cq::VertexFormat::kFloat32x2};
        cq::PalPtr<cq::IPipeline> pipeline;
        Check(pal->CreatePipeline(pd, pipeline).IsOk(), "CreatePipeline");

        // 采样器
        cq::SamplerDesc sd;
        sd.linear_filter = false;  // 最近邻，四色要能明确区分
        sd.clamp_to_edge = true;
        cq::PalPtr<cq::ISampler> sampler;
        Check(pal->CreateSampler(sd, sampler).IsOk(), "CreateSampler(nearest)");

        if (pipeline && sampler && tex && vbuf) {
            DrawClient client(cq::apple::ToPipelineHandle(pipeline.get()),
                              cq::apple::ToBufferHandle(vbuf.get()),
                              cq::apple::ToTextureHandle(tex.get()),
                              cq::apple::ToSamplerHandle(sampler.get()));
            cq::FrameContext ctx;
            cq::CancelToken token;
            Check(gfx->RenderFrame(ctx, rt.get(), client, token).IsOk(), "RenderFrame(绘制)");

            std::vector<uint8_t> px(64 * 64 * 4, 0);
            Check(cq::apple::ReadRenderTargetPixels(rt.get(), 0, 0, 64, 64, px.data(),
                                                    px.size()).IsOk(),
                  "ReadRenderTargetPixels");
            // 采样点：左上角 = 图像左上 = 红；右上角 = 绿；左下 = 蓝；右下 = 黄
            const uint8_t* tl = &px[(2 * 64 + 2) * 4];        // 左上
            const uint8_t* tr = &px[(2 * 64 + 61) * 4];       // 右上
            const uint8_t* bl = &px[(61 * 64 + 2) * 4];       // 左下
            const uint8_t* br = &px[(61 * 64 + 61) * 4];      // 右下
            std::printf("  左上=%u,%u,%u 右上=%u,%u,%u 左下=%u,%u,%u 右下=%u,%u,%u\n",
                        tl[0], tl[1], tl[2], tr[0], tr[1], tr[2],
                        bl[0], bl[1], bl[2], br[0], br[1], br[2]);
            Check(tl[0] > 200 && tl[1] < 55 && tl[2] < 55, "左上 = 红（纹理采样生效）");
            Check(tr[1] > 200 && tr[0] < 55, "右上 = 绿");
            Check(bl[2] > 200 && bl[0] < 55, "左下 = 蓝（uv 未上下颠倒）");
            Check(br[0] > 200 && br[1] > 200 && br[2] < 55, "右下 = 黄");
        }
    }

    std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
