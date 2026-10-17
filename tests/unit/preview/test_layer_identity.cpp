// ChuanqiCut — 变换层 GPU 恒等回归（RENDER-010 验收）
//
// 判据是**同一帧走两条路**：全屏拷贝 `Encode()` vs 恒等变换 `EncodeLayer()`，读回整张 RT
// 逐像素相减。卡片原文写的「golden ≥40dB」在本仓没有比对器可执行（golden 入口只校验
// 夹具齐备性），故换成这个当场可判的形式 —— 恒不命中的判据比没有更坏（P162）。
//
// 覆盖：
//   1. 恒等 A/B：两路读回像素的最大通道差（并打印实测数字）
//   2. 变换真的生效：scale 0.5 后四角回到清屏色、中心仍按源着色
// 仅 Apple（需 Metal）。heavy：跑真 GPU，Debug 档跳过、Release 档才计。

#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "cq/base/chq_concurrency.h"
#include "cq/base/chq_status.h"
#include "cq/gfx/chq_gfx_device.h"
#include "cq/platform/chq_gfx.h"
#include "cq/render/chq_layer_geometry.h"
#include "gfx_metal_internal.h"  // ReadRenderTargetPixels
#include "media_decode.h"        // cq::CqNativeImage

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

bool Near(uint8_t a, uint8_t b, int tol) { return std::abs(static_cast<int>(a) - static_cast<int>(b)) <= tol; }
bool ColorNear(const uint8_t* p, uint8_t r, uint8_t g, uint8_t b, uint8_t a, int tol) {
    return Near(p[0], r, tol) && Near(p[1], g, tol) && Near(p[2], b, tol) && Near(p[3], a, tol);
}

// 合成帧：上半红 / 下半蓝（BGRA，MetalCompatibility → 零拷贝）
CVPixelBufferRef MakeHalfRedHalfBlue(uint32_t w, uint32_t h) {
    CFTypeRef keys[1] = {kCVPixelBufferMetalCompatibilityKey};
    CFTypeRef vals[1] = {kCFBooleanTrue};
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CVPixelBufferRef pb = nullptr;
    const CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, static_cast<size_t>(w),
                                             static_cast<size_t>(h), kCVPixelFormatType_32BGRA,
                                             attrs, &pb);
    CFRelease(attrs);
    if (ret != kCVReturnSuccess || pb == nullptr) return nullptr;
    if (CVPixelBufferLockBaseAddress(pb, 0) == kCVReturnSuccess) {
        uint8_t* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pb));
        const size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        for (uint32_t y = 0; y < h; ++y) {
            uint8_t* row = base + static_cast<size_t>(y) * bpr;
            const bool top = (y < h / 2);
            for (uint32_t x = 0; x < w; ++x) {
                row[x * 4 + 0] = top ? 0 : 255;
                row[x * 4 + 1] = 0;
                row[x * 4 + 2] = top ? 255 : 0;
                row[x * 4 + 3] = 255;
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }
    return pb;
}

// 两条编码路径共用一个客户端：mode 0 = 全屏拷贝，mode 1 = 恒等变换层。
struct Client final : public cq::ChqIFrameEncoderClient {
    cq::ChqIBlitPass* blit_pass = nullptr;
    cq::TextureHandle src = nullptr;
    const float* verts = nullptr;
    int mode = 0;
    cq::ChqStatus Encode(cq::ChqIGfxEncoder& enc, const cq::ChqFrameContext&,
                         const cq::ChqCancelToken&) override {
        cq::ChqICommandEncoder* p = enc.PlatformEncoder();
        if (p == nullptr) return cq::ChqStatus(cq::ChqStatusCode::kInternal);
        if (mode == 0) return blit_pass->Encode(*p, src);
        return blit_pass->EncodeLayer(*p, src, verts, cq::kLayerVertexCount);
    }
};

uint32_t MaxChannelDiff(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b) {
    uint32_t worst = 0;
    const size_t n = a.size() < b.size() ? a.size() : b.size();
    for (size_t i = 0; i < n; ++i) {
        const uint32_t d = static_cast<uint32_t>(a[i] > b[i] ? a[i] - b[i] : b[i] - a[i]);
        if (d > worst) worst = d;
    }
    return worst;
}

bool ReadPixels(cq::ChqIRenderTarget* rt, uint32_t w, uint32_t h, std::vector<uint8_t>& out) {
    out.assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 4, 0);
    if (rt == nullptr) return false;
    return cq::apple::ReadRenderTargetPixels(rt, 0, 0, w, h, out.data(), out.size()).IsOk();
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== 变换层 GPU 恒等回归（RENDER-010）==\n");

    cq::ChqGraphicsDeviceDesc dd;
    dd.prefer_low_power = false;
    cq::ChqPlatformPtr<cq::ChqIGraphicsDevice> platform_device;
    Check(cq::CreateGraphicsDevice(dd, platform_device).IsOk(), "CreateGraphicsDevice(Metal)");
    if (!platform_device) return 1;

    cq::ChqIGfxDevice* gfx = nullptr;
    Check(cq::CreateGfxDevice(platform_device, gfx).IsOk() && gfx != nullptr, "CreateGfxDevice");
    if (gfx == nullptr) return 1;

    cq::ChqPlatformPtr<cq::ChqIBlitPass> blit;
    Check(cq::CreateBlitPass(gfx->PlatformDevice(), cq::ChqTextureFormat::kRGBA8, blit).IsOk() && blit,
          "CreateBlitPass（同一对象同时提供拷贝与变换层）");
    if (!blit) return 1;

    const uint32_t S = 64;
    CVPixelBufferRef pb = MakeHalfRedHalfBlue(S, S);
    Check(pb != nullptr, "合成 64x64 半红半蓝帧");
    if (pb == nullptr) return 1;

    cq::ChqPlatformPtr<cq::ChqINativeImageImporter> importer;
    if (!gfx->CreateNativeImageImporter(importer).IsOk() || !importer) return 1;
    auto* img = new cq::CqNativeImage(pb);
    cq::TextureHandle tex = nullptr;
    bool fb = false;
    Check(importer->Import(img, cq::ChqTextureUsage::kSampled, tex, fb).IsOk() && tex && !fb,
          "导入合成帧（零拷贝）");

    cq::ChqRenderTargetDesc rd;
    rd.width = S;
    rd.height = S;
    rd.color_format = cq::ChqTextureFormat::kRGBA8;

    // 恒等输入：画布 = RT = 64，源 = 64x64 → stretch 整画布（与 blit 同一批像素的前提）
    cq::ChqLayerInput in;
    in.canvas_width = S;
    in.canvas_height = S;
    in.source_width = S;
    in.source_height = S;
    float identity[cq::kLayerFloatCapacity] = {};
    Check(cq::BakeLayerQuad(in, identity, cq::kLayerFloatCapacity).IsOk(), "恒等顶点烘焙");

    std::vector<uint8_t> px_blit;
    std::vector<uint8_t> px_layer;
    {
        cq::ChqPlatformPtr<cq::ChqIRenderTarget> rt;
        Check(gfx->CreateRenderTarget(rd, rt).IsOk() && rt, "创建 64x64 RT（走 blit）");
        Client client;
        client.blit_pass = blit.get();
        client.src = tex;
        client.verts = identity;
        client.mode = 0;
        cq::ChqFrameContext ctx;
        ctx.target = rt->Handle();
        cq::ChqCancelToken token;
        Check(gfx->RenderFrame(ctx, rt.get(), client, token).IsOk(), "RenderFrame（全屏拷贝）");
        Check(ReadPixels(rt.get(), S, S, px_blit), "读回 blit 路径像素");
    }
    {
        cq::ChqPlatformPtr<cq::ChqIRenderTarget> rt;
        Check(gfx->CreateRenderTarget(rd, rt).IsOk() && rt, "创建 64x64 RT（走变换层）");
        Client client;
        client.blit_pass = blit.get();
        client.src = tex;
        client.verts = identity;
        client.mode = 1;
        cq::ChqFrameContext ctx;
        ctx.target = rt->Handle();
        cq::ChqCancelToken token;
        Check(gfx->RenderFrame(ctx, rt.get(), client, token).IsOk(), "RenderFrame（恒等变换层）");
        Check(ReadPixels(rt.get(), S, S, px_layer), "读回变换层路径像素");
    }

    std::printf("\n[1] 恒等 A/B（同帧两路读回）\n");
    if (px_blit.size() == px_layer.size() && !px_blit.empty()) {
        const uint32_t worst = MaxChannelDiff(px_blit, px_layer);
        std::printf("  实测：64x64 两路最大通道差 = %u（0 = 逐位相同）\n", worst);
        Check(worst <= 2, "恒等变换层与全屏拷贝逐像素一致（容差 2，覆盖浮点光栅化末位）");
        const size_t off = (static_cast<size_t>(4) * S + S / 2) * 4;
        Check(ColorNear(&px_layer[off], 255, 0, 0, 255, 6), "变换层 RT 顶部 = 红（uv 约定未被打乱）");
        Check(ColorNear(&px_layer[(static_cast<size_t>(S - 5) * S + S / 2) * 4], 0, 0, 255, 255, 6),
              "变换层 RT 底部 = 蓝");
    } else {
        Check(false, "两路像素尺寸一致（比对前提）");
    }

    std::printf("\n[2] scale 0.5：变换在 GPU 上真的生效\n");
    {
        cq::ChqLayerInput shrunk = in;
        shrunk.clip.scale_x = 0.5f;
        shrunk.clip.scale_y = 0.5f;
        float verts[cq::kLayerFloatCapacity] = {};
        Check(cq::BakeLayerQuad(shrunk, verts, cq::kLayerFloatCapacity).IsOk(), "缩放顶点烘焙");
        cq::ChqPlatformPtr<cq::ChqIRenderTarget> rt;
        if (gfx->CreateRenderTarget(rd, rt).IsOk() && rt) {
            Client client;
            client.blit_pass = blit.get();
            client.src = tex;
            client.verts = verts;
            client.mode = 1;
            cq::ChqFrameContext ctx;
            ctx.target = rt->Handle();
            cq::ChqCancelToken token;
            Check(gfx->RenderFrame(ctx, rt.get(), client, token).IsOk(), "RenderFrame（缩放层）");
            std::vector<uint8_t> px;
            Check(ReadPixels(rt.get(), S, S, px), "读回缩放像素");
            if (!px.empty()) {
                Check(ColorNear(&px[4], 0, 0, 0, 0, 6) || ColorNear(&px[4], 0, 0, 0, 255, 6),
                      "左上角 (2,0) 已无内容（回到清屏色）→ 证明缩放生效");
                Check(ColorNear(&px[(static_cast<size_t>(S * 0.3f) * S + S / 2) * 4], 255, 0, 0, 255, 6),
                      "中心上半仍是红");
                Check(ColorNear(&px[(static_cast<size_t>(S * 0.7f) * S + S / 2) * 4], 0, 0, 255, 255, 6),
                      "中心下半仍是蓝");
            }
        }
    }

    if (tex != nullptr) importer->ReleaseTexture(tex);
    delete img;
    CFRelease(pb);

    std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
