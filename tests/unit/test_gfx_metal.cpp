// ChuanqiCut — PALA-001 Apple Metal 离屏渲染 + 读回像素验证
//
// 验收硬要求（AGENTS.root.md）：不是「调用成功」，而是「渲染结果正确」。
// 本用例在 macOS 上用 Metal 做离屏渲染（无窗口），再把 RenderTarget 像素读回，
// 逐点断言：
//   * 用例 A：清屏为红，读回中心点必须 = (255,0,0,255)
//   * 用例 B：清屏为黑后，用全屏三角形采样一张 2x2 四色纹理绘制，
//             读回四角必须分别是 红/绿/蓝/黄（证明纹理采样管线真的通了，而非清屏色）
//
// 仅在 Apple 平台编译（tests/CMakeLists.txt 用 if(APPLE) 包裹）。

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "cq/base/status.h"
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

// 四色纹理：row0 = 红,绿；row1 = 蓝,黄（RGBA8，行主序）。
const uint8_t kTex2x2[2 * 2 * 4] = {
    255, 0, 0, 255,   0, 255, 0, 255,   // row0: (0,0)红 (1,0)绿
    0, 0, 255, 255,   255, 255, 0, 255, // row1: (0,1)蓝 (1,1)黄
};

// 全屏三角形：pos.xy(clip) + uv.xy，交错 float32x2。
//
// ⚠️ UV 纵向必须翻转：uv.y = 1 - (clip.y + 1) / 2
//    原因（2026-09-25 实测踩到）：约定 **uv(0,0) = 图像左上**；
//    而 Metal NDC 的 clip(-1,-1) 是**屏幕左下**。若按 uv=(clip+1)/2 直给，
//    图像左上角会被画到屏幕左下 —— 画面整体上下颠倒。
//    翻转后：屏幕左上(clip -1,+1) → uv(0,0) → 图像左上，画面正立。
//    该约定须由 PAL 契约定死并由各后端保证（GLES/Vulkan 纹理原点在左下，
//    需自行翻转以对齐同一约定），否则同一 RenderGraph 跨端渲染会上下颠倒。
const float kVerts[3 * 4] = {
    -1.0f, -1.0f, 0.0f, 1.0f,
     3.0f, -1.0f, 2.0f, 1.0f,
    -1.0f,  3.0f, 0.0f, -1.0f,
};

const char* kVertMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VIn {
    float2 pos [[attribute(0)]];
    float2 uv  [[attribute(1)]];
};
struct VOut {
    float4 position [[position]];
    float2 uv;
};
vertex VOut vs_main(VIn in [[stage_in]]) {
    VOut o;
    o.position = float4(in.pos, 0.0, 1.0);
    o.uv = in.uv;
    return o;
}
)MSL";

// ⚠️ 片元着色器是**独立编译单元**，必须自带 `VOut` 定义（不能依赖顶点着色器里的同名结构）。
//    且其 `[[position]]` 成员须与顶点输出完全一致，否则 stage_in 链接失败。
//    2026-09-25 修复：原片元源码直接用了未定义的 `VOut`，导致 CreateShaderModule 失败、
//    pipeline 为空、后续调用崩溃（SIGSEGV）。
const char* kFragMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VOut {
    float4 position [[position]];
    float2 uv;
};
fragment float4 fs_main(VOut in [[stage_in]],
                        texture2d<float> tex [[texture(0)]],
                        sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}
)MSL";

void RunCaseA(cq::IGraphicsDevice* dev, cq::IRenderTarget* rt) {
    std::printf("\n[用例 A] 清屏红 + 读回中心像素\n");
    cq::PalPtr<cq::ICommandQueue> q;
    Check(dev->CreateCommandQueue(q).IsOk(), "CreateCommandQueue");
    cq::PalPtr<cq::ICommandBuffer> cb;
    Check(q->CreateCommandBuffer(cb).IsOk(), "CreateCommandBuffer");
    cq::PalPtr<cq::ICommandEncoder> enc;
    Check(cb->CreateEncoder(enc).IsOk(), "CreateEncoder");

    const float clear[4] = {1.0f, 0.0f, 0.0f, 1.0f};
    Check(enc->BeginRenderPass(rt->Handle(), clear).IsOk(), "BeginRenderPass(clear red)");
    enc->End();
    Check(cb->Commit().IsOk(), "Commit");
    Check(cb->WaitUntilCompleted().IsOk(), "WaitUntilCompleted");

    std::vector<uint8_t> px(64 * 64 * 4, 0);
    Check(cq::apple::ReadRenderTargetPixels(rt, 0, 0, 64, 64, px.data(), px.size()).IsOk(),
          "ReadRenderTargetPixels");
    const uint8_t* c = &px[(32 * 64 + 32) * 4];
    std::printf("  中心像素 RGBA = %u,%u,%u,%u\n", c[0], c[1], c[2], c[3]);
    Check(c[0] == 255 && c[1] == 0 && c[2] == 0 && c[3] == 255, "中心像素 = 不透明红 (清屏生效)");
}

void RunCaseB(cq::IGraphicsDevice* dev, cq::IRenderTarget* rt) {
    std::printf("\n[用例 B] 清屏黑 + 全屏采样四色纹理 + 读回四角像素\n");

    // 2x2 四色纹理（采样源）
    cq::TextureDesc td;
    td.format = cq::TextureFormat::kRGBA8;
    td.width = 2;
    td.height = 2;
    td.usage = cq::TextureUsage::kSampled;
    cq::PalPtr<cq::ITexture> tex;
    Check(dev->CreateTexture(td, tex).IsOk(), "CreateTexture(2x2)");
    Check(cq::apple::UploadTextureData(tex.get(), kTex2x2, sizeof(kTex2x2)).IsOk(),
          "UploadTextureData(四色)");

    // 顶点缓冲
    cq::BufferDesc bd;
    bd.usage = cq::BufferUsage::kVertex;
    bd.size_bytes = sizeof(kVerts);
    cq::PalPtr<cq::IBuffer> vbuf;
    Check(dev->CreateBuffer(bd, vbuf).IsOk(), "CreateBuffer(vertex)");
    void* mapped = nullptr;
    Check(vbuf->Map(mapped).IsOk(), "Map(vertex)");
    std::memcpy(mapped, kVerts, sizeof(kVerts));
    vbuf->Unmap();

    // Shader modules (Platform-Native MSL)
    cq::ShaderModuleDesc vmd;
    vmd.stage = cq::ShaderStage::kVertex;
    vmd.code = static_cast<const void*>(kVertMSL);
    vmd.code_size = std::strlen(kVertMSL);
    vmd.is_platform_native = true;
    cq::PalPtr<cq::IShaderModule> vs;
    Check(dev->CreateShaderModule(vmd, vs).IsOk(), "CreateShaderModule(vertex MSL)");

    cq::ShaderModuleDesc fmd = vmd;
    fmd.stage = cq::ShaderStage::kFragment;
    fmd.code = static_cast<const void*>(kFragMSL);
    fmd.code_size = std::strlen(kFragMSL);
    cq::PalPtr<cq::IShaderModule> fs;
    Check(dev->CreateShaderModule(fmd, fs).IsOk(), "CreateShaderModule(fragment MSL)");

    // 失败防御：着色器或管线没建成就不要往下走。
    // 否则会拿着空句柄调 BeginRenderPass/Draw —— 那不是"渲染失败"，是崩溃（SIGSEGV），
    // 既掩盖了真实原因，也让 CI 以信号终止而非测试失败（挂死/崩溃比失败更难排查）。
    if (!vs || !fs) {
        std::printf("  !! 着色器创建失败，用例 B 提前终止（不再继续渲染）\n");
        return;
    }

    // Pipeline
    cq::PipelineDesc pd;
    pd.vertex_shader = cq::apple::ToShaderHandle(vs.get());
    pd.fragment_shader = cq::apple::ToShaderHandle(fs.get());
    pd.target_format = cq::TextureFormat::kRGBA8;
    pd.vertex_layout.stride = 16;
    pd.vertex_layout.attr_count = 2;
    pd.vertex_layout.attrs[0] = cq::VertexAttribute{0, 0, cq::VertexFormat::kFloat32x2};
    pd.vertex_layout.attrs[1] = cq::VertexAttribute{1, 8, cq::VertexFormat::kFloat32x2};
    cq::PalPtr<cq::IPipeline> pipe;
    Check(dev->CreatePipeline(pd, pipe).IsOk(), "CreatePipeline");

    // Sampler：最近邻 + 边缘钳制（四角精确落在四个 texel）
    cq::SamplerDesc sd;
    sd.linear_filter = false;
    sd.clamp_to_edge = true;
    cq::PalPtr<cq::ISampler> samp;
    Check(dev->CreateSampler(sd, samp).IsOk(), "CreateSampler");

    // 录制：清屏黑 -> 画全屏三角形采样纹理
    cq::PalPtr<cq::ICommandQueue> q;
    Check(dev->CreateCommandQueue(q).IsOk(), "CreateCommandQueue");
    cq::PalPtr<cq::ICommandBuffer> cb;
    Check(q->CreateCommandBuffer(cb).IsOk(), "CreateCommandBuffer");
    cq::PalPtr<cq::ICommandEncoder> enc;
    Check(cb->CreateEncoder(enc).IsOk(), "CreateEncoder");

    const float clear[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    Check(enc->BeginRenderPass(cq::apple::ToRenderTargetHandle(rt), clear).IsOk(),
          "BeginRenderPass(clear black)");
    enc->SetPipeline(cq::apple::ToPipelineHandle(pipe.get()));
    enc->SetVertexBuffer(cq::apple::ToBufferHandle(vbuf.get()), 0);
    enc->SetTexture(cq::apple::ToTextureHandle(tex.get()), 0);
    enc->SetSampler(cq::apple::ToSamplerHandle(samp.get()), 0);
    enc->Draw(3);
    enc->End();
    Check(cb->Commit().IsOk(), "Commit");
    Check(cb->WaitUntilCompleted().IsOk(), "WaitUntilCompleted");

    std::vector<uint8_t> px(64 * 64 * 4, 0);
    Check(cq::apple::ReadRenderTargetPixels(rt, 0, 0, 64, 64, px.data(), px.size()).IsOk(),
          "ReadRenderTargetPixels");
    auto at = [&](uint32_t x, uint32_t y) -> const uint8_t* {
        return &px[(static_cast<size_t>(y) * 64 + x) * 4];
    };
    const uint8_t* tl = at(1, 1);    // 期望 红
    const uint8_t* tr = at(62, 1);   // 期望 绿
    const uint8_t* bl = at(1, 62);   // 期望 蓝
    const uint8_t* br = at(62, 62);  // 期望 黄
    std::printf("  四角像素 RGBA =\n");
    std::printf("    TL(1,1)    = %u,%u,%u,%u\n", tl[0], tl[1], tl[2], tl[3]);
    std::printf("    TR(62,1)   = %u,%u,%u,%u\n", tr[0], tr[1], tr[2], tr[3]);
    std::printf("    BL(1,62)   = %u,%u,%u,%u\n", bl[0], bl[1], bl[2], bl[3]);
    std::printf("    BR(62,62)  = %u,%u,%u,%u\n", br[0], br[1], br[2], br[3]);
    const uint8_t* ctr = at(32, 32);  // 中心 ~ texel(1,1) 黄
    std::printf("    中心(32,32)= %u,%u,%u,%u\n", ctr[0], ctr[1], ctr[2], ctr[3]);

    auto isColor = [](const uint8_t* p, uint8_t r, uint8_t g, uint8_t b) {
        return p[0] == r && p[1] == g && p[2] == b && p[3] == 255;
    };
    Check(isColor(tl, 255, 0, 0), "TL = 红");
    Check(isColor(tr, 0, 255, 0), "TR = 绿");
    Check(isColor(bl, 0, 0, 255), "BL = 蓝");
    Check(isColor(br, 255, 255, 0), "BR = 黄");
    Check(!isColor(tl, 0, 0, 0) && !isColor(tr, 0, 0, 0) && !isColor(bl, 0, 0, 0) &&
              !isColor(br, 0, 0, 0),
          "四角均非清屏黑（绘制覆盖生效）");
    Check(isColor(ctr, 255, 255, 0), "中心 = 黄（uv 采样到 texel(1,1)）");
}

}  // namespace

int main() {
    // 无缓冲输出：崩溃/挂起时仍能看到已完成到哪一步。
    // （CORE-005 排查并发挂起时踩过这个坑：stdout 全缓冲时进程异常终止会丢掉全部进度）
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut PALA-001 Metal 离屏渲染读回验证 ==\n");

    cq::GraphicsDeviceDesc dd;
    dd.prefer_low_power = false;
    cq::PalPtr<cq::IGraphicsDevice> dev;
    cq::Status s = cq::CreateGraphicsDevice(dd, dev);
    Check(s.IsOk(), "CreateGraphicsDevice(Metal)");
    if (!dev) {
        std::printf("\n无法创建 Metal 设备，用例终止。\n");
        return 1;
    }

    cq::RenderTargetDesc rd;
    rd.width = 64;
    rd.height = 64;
    rd.color_format = cq::TextureFormat::kRGBA8;
    cq::PalPtr<cq::IRenderTarget> rt;
    Check(dev->CreateRenderTarget(rd, rt).IsOk(), "CreateRenderTarget(64x64)");
    if (!rt) {
        std::printf("\n无法创建 RenderTarget，用例终止。\n");
        return 1;
    }

    RunCaseA(dev.get(), rt.get());
    RunCaseB(dev.get(), rt.get());

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
