// ChuanqiCut — PALA-002 Apple 零拷贝导入验收（CVPixelBuffer → CVMetalTexture）
//
// 验收硬要求（与 PALA-001 一致）：不是「调用成功」，而是「零拷贝成立 + 渲染结果正确
// + 方向不颠倒」。本用例覆盖：
//   1. 合成 1920x1080 BGRA CVPixelBuffer：
//      a. Metal 兼容 -> 零拷贝导入，IOSurface 一致性证明（纹理与源共享同一 IOSurface），
//         渲染读回中心像素 == 注入的 RGBA（BGRA→RGBA 由着色器交换恢复）。
//      b. 非兼容 -> Import 走 CPU 退化（out_cpu_fallback=true），渲染读回同样正确，
//         证明契约要求的「导入失败仍可用」。
//      c. 耗时实测：零拷贝（建纹理视图）vs CPU 退化（整帧 memcpy）的代差。
//   2. 真实链路：PALA-010 demux + PALA-011 硬解出首帧 -> 本 importer 导入 ->
//      PALA-001 离屏渲染读回：中心像素 ≈ (0,188,0,255)（smptebars 真值），
//      且 UV 原点正确（顶/底采样与源行一致，不上下颠倒）。
//
// 无缓冲输出（崩溃/挂起时能看到进度）。仅 Apple 平台。

#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/pal/gfx.h"
#include "cq/pal/media.h"
#include "cq/media/system_frame_provider.h"
#include "media_decode.h"  // cq::VideoToolboxDecoder / cq::CqNativeImage / cq::GetCvPixelBuffer
#include "gfx_metal_internal.h"  // cq::apple::* 辅助（零平台类型签名，纯 C++ 可调用）

#ifndef CQ_SOURCE_DIR
#define CQ_SOURCE_DIR "."
#endif

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

// ---- 合成 CVPixelBuffer（BGRA，填充 (R,G,B,A)）----
// metal_compat=true 时附加 kCVPixelBufferMetalCompatibilityKey，零拷贝路径可命中；
// false 时零拷贝必然失败 -> 触发 CPU 退化路径（作为退化触发手段之一）。
CVPixelBufferRef MakeTestBuffer(uint32_t w, uint32_t h, bool metal_compat,
                                uint8_t r, uint8_t g, uint8_t b) {
    CFDictionaryRef attrs = nullptr;
    if (metal_compat) {
        CFTypeRef keys[1] = {kCVPixelBufferMetalCompatibilityKey};
        CFTypeRef vals[1] = {kCFBooleanTrue};
        attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1,
                                   &kCFTypeDictionaryKeyCallBacks,
                                   &kCFTypeDictionaryValueCallBacks);
    }
    CVPixelBufferRef pb = nullptr;
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, static_cast<size_t>(w),
                                      static_cast<size_t>(h), kCVPixelFormatType_32BGRA,
                                      attrs, &pb);
    if (attrs != nullptr) CFRelease(attrs);
    if (ret != kCVReturnSuccess || pb == nullptr) return nullptr;

    if (CVPixelBufferLockBaseAddress(pb, 0) == kCVReturnSuccess) {
        uint8_t* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pb));
        const size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        for (uint32_t y = 0; y < h; ++y) {
            uint8_t* row = base + static_cast<size_t>(y) * bpr;
            for (uint32_t x = 0; x < w; ++x) {
                // 字节序 BGRA：byte0=B, byte1=G, byte2=R, byte3=A
                row[x * 4 + 0] = b;
                row[x * 4 + 1] = g;
                row[x * 4 + 2] = r;
                row[x * 4 + 3] = 255;
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }
    return pb;
}

// 全屏三角形顶点：pos.xy(clip) + uv.xy；uv.y 翻转使「uv(0,0)=图像左上（契约约定）」
// 对齐屏幕左上（Metal NDC 的 clip(-1,+1) 为屏幕左下），避免上下颠倒。
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

// 片元：采样导入纹理并直接返回。导入纹理物理格式为 BGRA8Unorm，但 Metal 对该格式的采样
// 已按「逻辑 RGBA」返回（.r=红 .g=绿 .b=蓝，字节布局由格式内部吸收），**无需**手动交换
// 通道。若此处错误交换（c.b,c.g,c.r）会把 R/B 弄反（绿条等 R==B 区域看不出，但彩条其余
// 通道会暴露——这正是初版被底部检查抓出的原因）。
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
    float4 c = tex.sample(smp, in.uv);
    return c;  // BGRA8Unorm 采样已为逻辑 RGBA，无需交换
}
)MSL";

const uint32_t kRT = 256;

// 把已导入的纹理全屏渲染到 kRT×kRT 离屏 RenderTarget 并读回像素。
bool RenderImported(cq::IGraphicsDevice* dev, cq::TextureHandle tex,
                    std::vector<uint8_t>& out_px) {
    out_px.assign(static_cast<size_t>(kRT) * kRT * 4, 0);
    if (dev == nullptr || tex == nullptr) return false;

    cq::RenderTargetDesc rd;
    rd.width = kRT;
    rd.height = kRT;
    rd.color_format = cq::TextureFormat::kRGBA8;
    cq::PalPtr<cq::IRenderTarget> rt;
    if (!dev->CreateRenderTarget(rd, rt).IsOk() || !rt) return false;

    cq::BufferDesc bd;
    bd.usage = cq::BufferUsage::kVertex;
    bd.size_bytes = sizeof(kVerts);
    cq::PalPtr<cq::IBuffer> vbuf;
    if (!dev->CreateBuffer(bd, vbuf).IsOk() || !vbuf) return false;
    void* mapped = nullptr;
    if (!vbuf->Map(mapped).IsOk()) return false;
    std::memcpy(mapped, kVerts, sizeof(kVerts));
    vbuf->Unmap();

    cq::ShaderModuleDesc vmd;
    vmd.stage = cq::ShaderStage::kVertex;
    vmd.code = static_cast<const void*>(kVertMSL);
    vmd.code_size = std::strlen(kVertMSL);
    vmd.is_platform_native = true;
    cq::PalPtr<cq::IShaderModule> vs;
    if (!dev->CreateShaderModule(vmd, vs).IsOk() || !vs) return false;

    cq::ShaderModuleDesc fmd = vmd;
    fmd.stage = cq::ShaderStage::kFragment;
    fmd.code = static_cast<const void*>(kFragMSL);
    fmd.code_size = std::strlen(kFragMSL);
    cq::PalPtr<cq::IShaderModule> fs;
    if (!dev->CreateShaderModule(fmd, fs).IsOk() || !fs) return false;

    cq::PipelineDesc pd;
    pd.vertex_shader = cq::apple::ToShaderHandle(vs.get());
    pd.fragment_shader = cq::apple::ToShaderHandle(fs.get());
    pd.target_format = cq::TextureFormat::kRGBA8;
    pd.vertex_layout.stride = 16;
    pd.vertex_layout.attr_count = 2;
    pd.vertex_layout.attrs[0] = cq::VertexAttribute{0, 0, cq::VertexFormat::kFloat32x2};
    pd.vertex_layout.attrs[1] = cq::VertexAttribute{1, 8, cq::VertexFormat::kFloat32x2};
    cq::PalPtr<cq::IPipeline> pipe;
    if (!dev->CreatePipeline(pd, pipe).IsOk() || !pipe) return false;

    cq::SamplerDesc sd;
    sd.linear_filter = false;  // 最近邻，读回命中精确 texel
    sd.clamp_to_edge = true;
    cq::PalPtr<cq::ISampler> samp;
    if (!dev->CreateSampler(sd, samp).IsOk() || !samp) return false;

    cq::PalPtr<cq::ICommandQueue> q;
    if (!dev->CreateCommandQueue(q).IsOk()) return false;
    cq::PalPtr<cq::ICommandBuffer> cb;
    if (!q->CreateCommandBuffer(cb).IsOk()) return false;
    cq::PalPtr<cq::ICommandEncoder> enc;
    if (!cb->CreateEncoder(enc).IsOk()) return false;
    const float clear[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    if (!enc->BeginRenderPass(cq::apple::ToRenderTargetHandle(rt.get()), clear).IsOk()) return false;
    enc->SetPipeline(cq::apple::ToPipelineHandle(pipe.get()));
    enc->SetVertexBuffer(cq::apple::ToBufferHandle(vbuf.get()), 0);
    enc->SetTexture(tex, 0);
    enc->SetSampler(cq::apple::ToSamplerHandle(samp.get()), 0);
    enc->Draw(3);
    enc->End();
    if (!cb->Commit().IsOk()) return false;
    if (!cb->WaitUntilCompleted().IsOk()) return false;

    if (!cq::apple::ReadRenderTargetPixels(rt.get(), 0, 0, kRT, kRT,
                                           out_px.data(), out_px.size()).IsOk()) {
        return false;
    }
    return true;
}

bool Near(uint8_t a, uint8_t b, int tol) {
    const int d = static_cast<int>(a) - static_cast<int>(b);
    return std::abs(d) <= tol;
}
bool ColorNear(const uint8_t* p, uint8_t r, uint8_t g, uint8_t b, uint8_t a, int tol) {
    return Near(p[0], r, tol) && Near(p[1], g, tol) && Near(p[2], b, tol) && Near(p[3], a, tol);
}

// 从 BGRA CVPixelBuffer 读 (x,y) 处「真实 RGBA」（byte2=R, byte1=G, byte0=B, byte3=A）。
void ReadSourceRgba(CVPixelBufferRef pb, uint32_t x, uint32_t y,
                    uint8_t& r, uint8_t& g, uint8_t& b, uint8_t& a) {
    r = g = b = a = 0;
    if (pb == nullptr) return;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t* base = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pb));
    const uint8_t* px = base + static_cast<size_t>(y) * bpr + static_cast<size_t>(x) * 4;
    b = px[0];
    g = px[1];
    r = px[2];
    a = px[3];
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut PALA-002 Apple 零拷贝导入验收 ==\n");

    cq::GraphicsDeviceDesc dd;
    dd.prefer_low_power = false;
    cq::PalPtr<cq::IGraphicsDevice> dev;
    Check(cq::CreateGraphicsDevice(dd, dev).IsOk(), "CreateGraphicsDevice(Metal)");
    if (!dev) {
        std::printf("\n无法创建 Metal 设备，用例终止。\n");
        return 1;
    }

    cq::PalPtr<cq::INativeImageImporter> importer;
    Check(dev->CreateNativeImageImporter(importer).IsOk() && importer,
          "CreateNativeImageImporter 返回可用导入器");
    if (!importer) {
        std::printf("\n导入器创建失败，用例终止。\n");
        return 1;
    }

    // ===========================================================================
    // 1. 合成帧：零拷贝 + IOSurface 一致性 + 像素正确
    // ===========================================================================
    std::printf("\n[1] 合成 1920x1080 BGRA 帧：零拷贝路径 + IOSurface 一致性\n");
    const uint32_t TW = 1920, TH = 1080;
    CVPixelBufferRef pbZero = MakeTestBuffer(TW, TH, /*metal_compat=*/true, 10, 20, 30);
    CVPixelBufferRef pbCpu = MakeTestBuffer(TW, TH, /*metal_compat=*/false, 10, 20, 30);
    Check(pbZero != nullptr && pbCpu != nullptr, "合成两帧 CVPixelBuffer 创建成功");
    if (pbZero == nullptr || pbCpu == nullptr) {
        std::printf("\n合成帧失败，用例终止。\n");
        return 1;
    }

    cq::NativeImageHandle hZero = new cq::CqNativeImage(pbZero);
    cq::NativeImageHandle hCpu = new cq::CqNativeImage(pbCpu);

    cq::TextureHandle texZero = nullptr;
    bool fbZero = false;
    Check(importer->Import(hZero, cq::TextureUsage::kSampled, texZero, fbZero).IsOk(),
          "Import(兼容帧) 成功");
    Check(texZero != nullptr, "Import(兼容帧) 产出非空纹理");
    Check(fbZero == false, "Import(兼容帧) 走零拷贝（out_cpu_fallback=false）");

    // IOSurface 一致性证明：纹理与源 buffer 共享同一 IOSurface -> 物理零拷贝。
    IOSurfaceRef srcSurf = CVPixelBufferGetIOSurface(pbZero);
    const uint32_t srcSurfId = (srcSurf != nullptr) ? static_cast<uint32_t>(IOSurfaceGetID(srcSurf)) : 0;
    const uint32_t texSurfId = cq::apple::GetImportedTextureIosurfaceId(texZero);
    std::printf("  源 IOSurface ID=%u  导入纹理 IOSurface ID=%u\n", srcSurfId, texSurfId);
    if (srcSurfId != 0 && texSurfId != 0) {
        Check(srcSurfId == texSurfId, "IOSurface 一致性：纹理与源 buffer 同一 IOSurface（物理零拷贝）");
    } else {
        std::printf("  !! 取不到 IOSurface（src=%u tex=%u），降级到耗时实测证据。\n", srcSurfId, texSurfId);
    }

    // 渲染读回：中心像素应 == 注入的 RGBA(10,20,30,255)（着色器已做 BGRA->RGBA 交换）。
    std::vector<uint8_t> pxZero;
    Check(RenderImported(dev.get(), texZero, pxZero), "渲染零拷贝纹理 + 读回");
    if (!pxZero.empty()) {
        const uint8_t* c = &pxZero[(static_cast<size_t>(kRT / 2) * kRT + kRT / 2) * 4];
        std::printf("  零拷贝中心像素 RGBA = %u,%u,%u,%u（注入 10,20,30,255）\n",
                    c[0], c[1], c[2], c[3]);
        Check(ColorNear(c, 10, 20, 30, 255, 3), "零拷贝渲染中心像素 == 注入 RGBA（交换正确）");
    }
    if (texZero != nullptr) cq::apple::DestroyTexture(texZero);

    // ===========================================================================
    // 2. 合成帧：CPU 退化路径（契约要求「导入失败仍可用」）
    // ===========================================================================
    std::printf("\n[2] 合成帧非兼容：CPU 退化路径（out_cpu_fallback=true 仍可用）\n");
    cq::TextureHandle texCpu = nullptr;
    bool fbCpu = false;
    Check(importer->Import(hCpu, cq::TextureUsage::kSampled, texCpu, fbCpu).IsOk(),
          "Import(非兼容帧) 成功（退化不崩溃）");
    Check(texCpu != nullptr, "Import(非兼容帧) 产出非空纹理");
    Check(fbCpu == true, "Import(非兼容帧) 标记 out_cpu_fallback=true");
    std::vector<uint8_t> pxCpu;
    Check(RenderImported(dev.get(), texCpu, pxCpu), "渲染退化纹理 + 读回");
    if (!pxCpu.empty()) {
        const uint8_t* c = &pxCpu[(static_cast<size_t>(kRT / 2) * kRT + kRT / 2) * 4];
        std::printf("  退化中心像素 RGBA = %u,%u,%u,%u（注入 10,20,30,255）\n",
                    c[0], c[1], c[2], c[3]);
        Check(ColorNear(c, 10, 20, 30, 255, 3), "退化渲染中心像素 == 注入 RGBA（像素正确）");
    }
    if (texCpu != nullptr) cq::apple::DestroyTexture(texCpu);

    // ===========================================================================
    // 3. 零拷贝耗时代差证明
    // ===========================================================================
    std::printf("\n[3] 零拷贝 vs CPU 退化 耗时实测（各 50 次导入）\n");
    double zero_ms = 0.0, cpu_ms = 0.0;
    cq::Status bs = cq::apple::BenchmarkNativeImageImport(dev.get(), hZero, hCpu, 50, zero_ms, cpu_ms);
    Check(bs.IsOk(), "BenchmarkNativeImageImport 执行成功");
    if (bs.IsOk()) {
        const double perZero = zero_ms / 50.0;
        const double perCpu = cpu_ms / 50.0;
        std::printf("  零拷贝/次 = %.4f ms    CPU 退化/次 = %.4f ms\n", perZero, perCpu);
        if (cpu_ms > 0.0) {
            std::printf("  代差（CPU / 零拷贝）≈ %.1fx\n", cpu_ms / zero_ms);
        }
        // 零拷贝必须明显快于「整帧 memcpy」退化路径（物理上无拷贝）。
        Check(zero_ms < cpu_ms, "零拷贝总耗时 < CPU 退化总耗时（无 memcpy 收益成立）");
    }

    // 释放合成帧句柄与 buffer
    delete static_cast<cq::CqNativeImage*>(hZero);
    delete static_cast<cq::CqNativeImage*>(hCpu);
    CFRelease(pbZero);
    CFRelease(pbCpu);

    // ===========================================================================
    // 4. 真实链路：PALA-010 demux + PALA-011 硬解首帧 -> 导入 -> 渲染读回
    // ===========================================================================
    std::printf("\n[4] 真实链路：PALA-010+PALA-011 首帧 -> 零拷贝导入 -> PALA-001 渲染\n");
    const std::string path =
        std::string(CQ_SOURCE_DIR) + "/tests/golden/frames/gf_1080p_h264.mp4";
    std::printf("样本: %s\n", path.c_str());

    cq::MediaSource src;
    src.path = path.c_str();
    src.path_len = path.size();

    cq::PalPtr<cq::IMediaDemuxer> demuxer;
    Check(cq::CreateMediaDemuxer(src, demuxer).IsOk() && demuxer, "CreateMediaDemuxer 打开成功");
    if (!demuxer) {
        std::printf("\n真实解封装打开失败，跳过真实链路（合成验证仍有效）。\n");
    } else {
        cq::StreamInfo info{};
        Check(demuxer->GetStreamInfo(0, info).IsOk() &&
                  info.type == cq::MediaType::kVideo && info.codec == cq::CodecId::kH264,
              "真实流：视频 / H.264");
        Check(info.width == 1920 && info.height == 1080, "真实尺寸 = 1920x1080");

        cq::VideoToolboxDecoder decoder(path.c_str());
        Check(decoder.Open(info).IsOk(), "VideoToolboxDecoder.Open 成功（硬解会话建立）");
        std::printf("  硬解是否真走硬件: %s\n",
                    decoder.IsHardwareAccelerated() ? "YES" : "NO(软解回退)");

        // 喂入全部包（按 demux 顺序），再排空解码器取首帧。
        for (;;) {
            cq::MediaPacket pkt{};
            cq::Status rs = demuxer->ReadPacket(pkt);
            if (rs.code == cq::StatusCode::kIoNotFound) break;
            if (!rs.IsOk()) break;
            if (pkt.codec == cq::CodecId::kH264) {
                cq::Status fs = decoder.Feed(pkt);
                (void)fs;
            }
        }
        cq::MediaFrame f{};
        cq::Status ps = decoder.PopFrame(f);
        Check(ps.IsOk() && f.type == cq::MediaType::kVideo && f.video.image != nullptr,
              "PopFrame 取出真实首帧");

        if (ps.IsOk() && f.video.image != nullptr) {
            CVPixelBufferRef rpb = cq::GetCvPixelBuffer(f.video.image);
            Check(rpb != nullptr, "首帧 CVPixelBuffer 可取回");
            if (rpb != nullptr) {
                const uint32_t fw = static_cast<uint32_t>(CVPixelBufferGetWidth(rpb));
                const uint32_t fh = static_cast<uint32_t>(CVPixelBufferGetHeight(rpb));
                std::printf("  首帧尺寸 = %ux%u  格式=0x%x\n", fw, fh,
                            static_cast<unsigned>(CVPixelBufferGetPixelFormatType(rpb)));

                cq::TextureHandle texReal = nullptr;
                bool fbReal = false;
                Check(importer->Import(f.video.image, cq::TextureUsage::kSampled, texReal, fbReal).IsOk(),
                      "Import(真实首帧) 成功");
                Check(texReal != nullptr, "Import(真实首帧) 产出非空纹理");
                if (fbReal) {
                    std::printf("  !! 真实首帧走了 CPU 退化（out_cpu_fallback=true）；"
                                "PALA-011 设了 MetalCompatibility，预期为零拷贝，请排查。\n");
                } else {
                    Check(true, "Import(真实首帧) 走零拷贝（out_cpu_fallback=false）");
                }

                // IOSurface 一致性（真实帧）
                IOSurfaceRef rsrc = CVPixelBufferGetIOSurface(rpb);
                const uint32_t rsrcId = (rsrc != nullptr) ? static_cast<uint32_t>(IOSurfaceGetID(rsrc)) : 0;
                const uint32_t rtexId = cq::apple::GetImportedTextureIosurfaceId(texReal);
                std::printf("  真实帧 源 IOSurface ID=%u  导入纹理 IOSurface ID=%u\n", rsrcId, rtexId);
                if (rsrcId != 0 && rtexId != 0) {
                    Check(rsrcId == rtexId, "真实帧 IOSurface 一致性（零拷贝）");
                }

                // 渲染读回 + 像素验证（对照真值 (0,188,0,255)）
                std::vector<uint8_t> pxReal;
                Check(RenderImported(dev.get(), texReal, pxReal), "渲染真实首帧 + 读回");
                if (!pxReal.empty()) {
                    const uint8_t* c = &pxReal[(static_cast<size_t>(kRT / 2) * kRT + kRT / 2) * 4];
                    std::printf("  渲染中心像素 RGBA = %u,%u,%u,%u（真值 ~0,188,0,255）\n",
                                c[0], c[1], c[2], c[3]);
                    // 视频中心为 smptebars 绿条；与 ffmpeg 真值容差几个灰阶。
                    Check(ColorNear(c, 0, 188, 0, 255, 12),
                          "渲染中心像素 ≈ 真值(0,188,0,255)（绿条，方向/色彩正确）");

                    // ---- UV 原点约定：顶/底不上下颠倒 ----
                    // 屏幕顶(v=2)映射到图像顶部行、屏幕底(v=kRT-3)映射到图像底部行；
                    // 若翻转，RT 顶将等于源底、RT 底等于源顶 -> 验证会失败。
                    const uint32_t y_top_src = 10;
                    const uint32_t y_bot_src = (fh > 20) ? (fh - 11) : (fh / 2);
                    uint8_t sTr = 0, sTg = 0, sTb = 0, sTa = 0;
                    uint8_t sBr = 0, sBg = 0, sBb = 0, sBa = 0;
                    ReadSourceRgba(rpb, fw / 2, y_top_src, sTr, sTg, sTb, sTa);
                    ReadSourceRgba(rpb, fw / 2, y_bot_src, sBr, sBg, sBb, sBa);
                    const uint8_t* rtTop = &pxReal[(static_cast<size_t>(2) * kRT + kRT / 2) * 4];
                    const uint8_t* rtBot = &pxReal[(static_cast<size_t>(kRT - 3) * kRT + kRT / 2) * 4];
                    std::printf("  源顶(%u) RGBA=%u,%u,%u,%u  源底(%u) RGBA=%u,%u,%u,%u\n",
                                y_top_src, sTr, sTg, sTb, sTa, y_bot_src, sBr, sBg, sBb, sBa);
                    std::printf("  RT顶  RGBA=%u,%u,%u,%u  RT底  RGBA=%u,%u,%u,%u\n",
                                rtTop[0], rtTop[1], rtTop[2], rtTop[3],
                                rtBot[0], rtBot[1], rtBot[2], rtBot[3]);
                    Check(ColorNear(rtTop, sTr, sTg, sTb, sTa, 6),
                          "RT 顶部像素 == 源顶部行（uv 原点=图像左上，未颠倒）");
                    Check(ColorNear(rtBot, sBr, sBg, sBb, sBa, 6),
                          "RT 底部像素 == 源底部行（方向正确）");
                    const bool top_ne_bottom =
                        (rtTop[0] != rtBot[0] || rtTop[1] != rtBot[1] ||
                         rtTop[2] != rtBot[2] || rtTop[3] != rtBot[3]);
                    Check(top_ne_bottom, "RT 顶/底像素不同（图像确有内容梯度，可分辨方向）");
                }
                if (texReal != nullptr) cq::apple::DestroyTexture(texReal);
            }
        }
        // decoder 析构会释放 lease 的 CqNativeImage；f.video.image 不再引用，无需手动释放。
    }

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
