// ChuanqiCut — 预览渲染器验收（BIND-003 子步骤 4）
//
// 验收硬要求：不是「RenderFrame 返回 kOk」，而是「画面真的是时间线在该时刻的内容」。
// 本用例覆盖：
//   1. IBlitPass 方向约定：合成帧上半红 / 下半蓝 → RT 顶红底蓝（uv(0,0)=图像左上）。
//      ⚠️ 这条**必须**由本用例覆盖：blit pass 的 MSL 是独立的 Platform-Native 实现，
//      PALA-002 的用例用的是它自己内联的那份 shader，管不到这里。
//   2. 端到端：Timeline + AssetRegistry → 取帧 → 零拷贝导入 → 离屏 RT，
//      读回中心像素对照 smptebars 真值 (0,188,0,255)。
//   3. 零拷贝成立：LastImportCpuFallback() == false（持续为 true 说明链路断了）。
//   4. 空隙帧：返回 kIoNotFound（**不**伪造成功）+ 画面为黑。
//   5. 素材未注册：返回 kInvalidArgument（不静默渲染黑帧）。
//   6. 连续多帧：逐帧导入并释放纹理，20 帧无错（释放路径错了会崩在这）。
//   7. Resize：换分辨率后仍渲染正确。
//
// 仅 Apple 平台（需 PALA-001/002/010/011 后端）。无缓冲输出。

#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "cq/base/concurrency.h"
#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/gfx/gfx_device.h"
#include "cq/media/asset_registry.h"
#include "cq/model/timeline.h"
#include "cq/media/pal_frame_provider.h"  // PalFrameProviderFactory（经 PAL 工厂取帧）
#include "cq/pal/gfx.h"                   // IBlitPass / CreateBlitPass
#include "cq/preview/preview_renderer.h"
#include "gfx_metal_internal.h"  // ReadRenderTargetPixels
#include "media_decode.h"        // cq::CqNativeImage（合成帧包装，仅 Apple TU 可见）

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

cq::RationalTime Ms(int64_t ms) {
    return cq::RationalTime(ms * 120, cq::kProjectTimeScale);
}

bool Near(uint8_t a, uint8_t b, int tol) {
    const int d = static_cast<int>(a) - static_cast<int>(b);
    return std::abs(d) <= tol;
}
bool ColorNear(const uint8_t* p, uint8_t r, uint8_t g, uint8_t b, uint8_t a, int tol) {
    return Near(p[0], r, tol) && Near(p[1], g, tol) && Near(p[2], b, tol) && Near(p[3], a, tol);
}

// ---- 合成 CVPixelBuffer（BGRA，上半红 / 下半蓝）----
// 附加 MetalCompatibility，确保走零拷贝路径。
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
                // 字节序 BGRA
                row[x * 4 + 0] = top ? 0 : 255;    // B：上半 0，下半 255 → 下半蓝
                row[x * 4 + 1] = 0;                // G
                row[x * 4 + 2] = top ? 255 : 0;    // R：上半 255 → 上半红
                row[x * 4 + 3] = 255;              // A
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }
    return pb;
}

// 建一条「单视频轨 + 单个片段」的时间线。
void BuildSingleClipTimeline(cq::Timeline& tl, uint64_t asset_id, int64_t duration_ms) {
    uint64_t track_id = 0;
    tl.AddTrack(cq::TrackKind::kVideo, track_id);
    cq::Clip clip;
    clip.kind = cq::ClipKind::kVideo;
    clip.source.asset_id = asset_id;
    clip.source.source_in = cq::RationalTime(0, cq::kProjectTimeScale);
    clip.source.source_duration = Ms(duration_ms);
    clip.start = cq::RationalTime(0, cq::kProjectTimeScale);
    clip.duration = Ms(duration_ms);
    uint64_t clip_id = 0;
    tl.InsertClip(track_id, clip, clip_id);
}

bool ReadPixels(cq::IRenderTarget* rt, uint32_t w, uint32_t h, std::vector<uint8_t>& out) {
    out.assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 4, 0);
    if (rt == nullptr) return false;
    return cq::apple::ReadRenderTargetPixels(rt, 0, 0, w, h, out.data(), out.size()).IsOk();
}

// ---- UIA-009 子步骤 2：渲染输入改为模型快照提供者 ----
// 测试用固定快照：把本地构造的 timeline/assets 拷进一份不可变快照。
class FixedSnapshotProvider final : public cq::IModelSnapshotProvider {
public:
    FixedSnapshotProvider(const cq::Timeline& tl, const cq::AssetRegistry& assets)
        : snap_(std::make_shared<const cq::ModelSnapshot>(cq::ModelSnapshot{
              std::make_shared<const cq::Timeline>(tl),
              std::make_shared<const cq::AssetRegistry>(assets)})) {}
    std::shared_ptr<const cq::ModelSnapshot> CurrentSnapshot() const override {
        return snap_;
    }

private:
    std::shared_ptr<const cq::ModelSnapshot> snap_;
};

}  // namespace


int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut 预览渲染器验收（BIND-003 子步骤 4）==\n");

    // ---- 装配：PAL 设备 → GFX 设备 → blit pass / provider 工厂 ----
    cq::GraphicsDeviceDesc dd;
    dd.prefer_low_power = false;
    cq::PalPtr<cq::IGraphicsDevice> pal_device;
    Check(cq::CreateGraphicsDevice(dd, pal_device).IsOk(), "CreateGraphicsDevice(Metal)");
    if (!pal_device) return 1;

    cq::IGfxDevice* gfx = nullptr;
    Check(cq::CreateGfxDevice(pal_device, gfx).IsOk() && gfx != nullptr,
          "CreateGfxDevice（GFX-002 门面）");
    if (gfx == nullptr) return 1;

    // blit pass 走 **PAL 工厂**：它必然由平台原生 shader 实现，属于平台能力。
    cq::PalPtr<cq::IBlitPass> blit;
    Check(cq::CreateBlitPass(gfx->PalDevice(), cq::TextureFormat::kRGBA8, blit).IsOk() && blit,
          "CreateBlitPass（PAL 工厂 → Apple MSL 全屏拷贝）");
    // 取帧工厂走 core 默认实现：内部经 PAL 的 CreateFrameProvider，
    // 再适配成 core 的 FrameProvider（不引用任何 Apple 符号）。
    cq::PalFrameProviderFactory factory;
    if (!blit) return 1;

    // =========================================================================
    // 1. blit pass 方向约定（合成帧：上半红 / 下半蓝）
    // =========================================================================
    std::printf("\n[1] IBlitPass 方向：uv(0,0)=图像左上（RT 顶红 / 底蓝）\n");
    {
        const uint32_t S = 64;
        CVPixelBufferRef pb = MakeHalfRedHalfBlue(S, S);
        Check(pb != nullptr, "合成 64x64 半红半蓝帧");
        if (pb != nullptr) {
            cq::PalPtr<cq::INativeImageImporter> importer;
            Check(gfx->CreateNativeImageImporter(importer).IsOk() && importer,
                  "CreateNativeImageImporter");
            if (importer) {
                auto* img = new cq::CqNativeImage(pb);
                cq::TextureHandle tex = nullptr;
                bool fb = false;
                Check(importer->Import(img, cq::TextureUsage::kSampled, tex, fb).IsOk() &&
                          tex != nullptr && !fb,
                      "导入合成帧（零拷贝）");

                cq::RenderTargetDesc rd;
                rd.width = S;
                rd.height = S;
                rd.color_format = cq::TextureFormat::kRGBA8;
                cq::PalPtr<cq::IRenderTarget> rt;
                Check(gfx->CreateRenderTarget(rd, rt).IsOk() && rt, "创建 64x64 离屏 RT");

                if (rt && tex != nullptr) {
                    // 用与预览渲染器相同的调用形状（RenderFrame + 编码器客户端）驱动 blit pass。
                    struct Client final : public cq::IFrameEncoderClient {
                        cq::IBlitPass* blit_pass = nullptr;
                        cq::TextureHandle src = nullptr;
                        cq::Status Encode(cq::IGfxEncoder& enc, const cq::FrameContext&,
                                          const cq::CancelToken&) override {
                            // IBlitPass 在 PAL 层，收 PAL 的 ICommandEncoder。
                            cq::ICommandEncoder* pal_enc = enc.PalEncoder();
                            if (pal_enc == nullptr) return cq::Status(cq::StatusCode::kInternal);
                            return blit_pass->Encode(*pal_enc, src);
                        }
                    } client;
                    client.blit_pass = blit.get();
                    client.src = tex;

                    cq::FrameContext ctx;
                    ctx.target = rt->Handle();
                    cq::CancelToken token;
                    Check(gfx->RenderFrame(ctx, rt.get(), client, token).IsOk(),
                          "RenderFrame（经 blit pass）");

                    std::vector<uint8_t> px;
                    Check(ReadPixels(rt.get(), S, S, px), "读回 64x64 像素");
                    if (!px.empty()) {
                        const uint8_t* top = &px[(static_cast<size_t>(4) * S + S / 2) * 4];
                        const uint8_t* bot = &px[(static_cast<size_t>(S - 5) * S + S / 2) * 4];
                        std::printf("  RT顶 RGBA=%u,%u,%u,%u  RT底 RGBA=%u,%u,%u,%u\n",
                                    top[0], top[1], top[2], top[3], bot[0], bot[1], bot[2],
                                    bot[3]);
                        Check(ColorNear(top, 255, 0, 0, 255, 6), "RT 顶部 == 红（源上半）");
                        Check(ColorNear(bot, 0, 0, 255, 255, 6), "RT 底部 == 蓝（源下半）");
                    }
                }
                if (tex != nullptr) importer->ReleaseTexture(tex);
                delete img;
            }
            CFRelease(pb);
        }
    }

    // =========================================================================
    // 2. 端到端：时间线 + 素材表 → 真实取帧 → 离屏 RT
    // =========================================================================
    std::printf("\n[2] 端到端：Timeline+AssetRegistry → 取帧 → 零拷贝导入 → 离屏 RT\n");
    const std::string path =
        std::string(CQ_SOURCE_DIR) + "/tests/golden/frames/gf_1080p_h264.mp4";
    std::printf("样本: %s\n", path.c_str());

    cq::AssetRegistry assets;
    Check(assets.Register(1, path).IsOk(), "AssetRegistry.Register(asset_id=1)");

    cq::Timeline timeline;
    BuildSingleClipTimeline(timeline, 1, 3000);  // 0 ~ 3s 单片段
    Check(timeline.Tracks().size() == 1, "时间线：单视频轨 + 单片段");

    cq::PreviewRenderer::Config cfg;
    cfg.width = 256;
    cfg.height = 256;
    cfg.format = cq::TextureFormat::kRGBA8;
    FixedSnapshotProvider snapshot_provider(timeline, assets);
    cq::PreviewRenderer renderer(gfx, blit.get(), &factory, &snapshot_provider, cfg);

    cq::CancelToken token;
    cq::TextureHandle out = nullptr;
    cq::Status s = renderer.RenderFrame(Ms(500), out, token);
    std::printf("  RenderFrame(t=0.5s) code=%d\n", static_cast<int>(s.code));
    Check(s.IsOk(), "RenderFrame(t=0.5s) 成功");
    Check(out != nullptr, "导出非空纹理句柄（中性句柄，Swift 侧 reinterpret）");
    Check(renderer.LastHitClip(), "命中片段（LastHitClip=true）");
    Check(!renderer.LastImportCpuFallback(), "零拷贝导入成立（LastImportCpuFallback=false）");
    Check(renderer.LastSourceTime().value == Ms(500).value, "素材内时间 == 请求时间（0.5s）");
    // ⚠️ 关键：彩条是静态内容，像素相同**不能**证明取对了帧。只有实际帧 pts 能区分
    //    「取到 t 时刻那一帧」与「反复复用同一帧」。容差取 40ms（>1 帧 @25fps，
    //    用于吸收「展示区间归属」带来的帧内偏移）。
    {
        const int64_t want = Ms(500).value;              // 60000 ticks
        const int64_t got = renderer.LastFramePts().value;
        const int64_t diff = got > want ? got - want : want - got;
        std::printf("  请求 pts=%lld  实际帧 pts=%lld  偏差=%lld ticks\n",
                    static_cast<long long>(want), static_cast<long long>(got),
                    static_cast<long long>(diff));
        Check(diff <= 4800, "实际解码帧 pts ≈ 请求时间（不是复用同一帧）");
    }

    std::vector<uint8_t> px;
    Check(ReadPixels(renderer.Target(), 256, 256, px), "读回 256x256 像素");
    if (!px.empty()) {
        const uint8_t* c = &px[(static_cast<size_t>(128) * 256 + 128) * 4];
        std::printf("  中心像素 RGBA=%u,%u,%u,%u（smptebars 真值 ~0,188,0,255）\n",
                    c[0], c[1], c[2], c[3]);
        Check(ColorNear(c, 0, 188, 0, 255, 12), "中心像素 ≈ 真值(0,188,0,255)（画面真的是素材内容）");
    }

    // =========================================================================
    // 3. 空隙帧：如实返回 kIoNotFound + 黑屏
    // =========================================================================
    std::printf("\n[3] 空隙（t=5s，超出片段）：kIoNotFound + 清屏为黑\n");
    cq::TextureHandle out_gap = nullptr;
    s = renderer.RenderFrame(Ms(5000), out_gap, token);
    std::printf("  RenderFrame(t=5.0s) code=%d\n", static_cast<int>(s.code));
    Check(s.code == cq::StatusCode::kIoNotFound, "空隙返回 kIoNotFound（不伪造成功）");
    Check(!renderer.LastHitClip(), "LastHitClip=false");
    std::vector<uint8_t> px_gap;
    Check(ReadPixels(renderer.Target(), 256, 256, px_gap), "读回空隙帧像素");
    if (!px_gap.empty()) {
        const uint8_t* c = &px_gap[(static_cast<size_t>(128) * 256 + 128) * 4];
        std::printf("  空隙中心像素 RGBA=%u,%u,%u,%u\n", c[0], c[1], c[2], c[3]);
        Check(ColorNear(c, 0, 0, 0, 255, 2), "空隙帧为黑（已清屏）");
    }

    // =========================================================================
    // 4. 素材未注册：kInvalidArgument
    // =========================================================================
    std::printf("\n[4] 片段引用未注册素材：kInvalidArgument\n");
    {
        cq::Timeline tl_unknown;
        BuildSingleClipTimeline(tl_unknown, 999, 3000);
        FixedSnapshotProvider snap_unknown(tl_unknown, assets);
        cq::PreviewRenderer r_unknown(gfx, blit.get(), &factory, &snap_unknown, cfg);
        cq::TextureHandle out_u = nullptr;
        cq::Status su = r_unknown.RenderFrame(Ms(500), out_u, token);
        std::printf("  RenderFrame(asset_id=999) code=%d\n", static_cast<int>(su.code));
        Check(su.code == cq::StatusCode::kInvalidArgument, "未注册素材返回 kInvalidArgument");
    }

    // =========================================================================
    // 5. 连续多帧：逐帧导入 + 逐帧释放（释放路径错了会崩在这）
    // =========================================================================
    std::printf("\n[5] 连续 12 帧（0.3s ~ 1.8s）：导入纹理逐帧释放\n");
    {
        bool all_ok = true;
        bool all_zero_copy = true;
        for (int i = 0; i < 12; ++i) {
            const int64_t t = 300 + static_cast<int64_t>(i) * 135;  // 300 ~ 1785 ms
            cq::TextureHandle o = nullptr;
            cq::Status rs = renderer.RenderFrame(Ms(t), o, token);
            if (!rs.IsOk()) {
                std::printf("  FAIL: t=%lldms code=%d\n", static_cast<long long>(t),
                            static_cast<int>(rs.code));
                all_ok = false;
                break;
            }
            if (renderer.LastImportCpuFallback()) all_zero_copy = false;
        }
        Check(all_ok, "连续 12 帧全部渲染成功（导入/释放循环正常，无崩）");
        Check(all_zero_copy, "12 帧全部走零拷贝（无静默退化）");
    }

    // =========================================================================
    // 6. Resize：换分辨率后仍正确
    // =========================================================================
    std::printf("\n[6] Resize(128x128) 后重新渲染\n");
    Check(renderer.Resize(128, 128).IsOk(), "Resize(128,128)");
    cq::TextureHandle out_small = nullptr;
    s = renderer.RenderFrame(Ms(1000), out_small, token);
    Check(s.IsOk(), "Resize 后 RenderFrame 成功");
    {
        // t=1.0s：帧 pts 应随之推进（与 0.5s 那次不同），再次证明不是复用同一帧。
        const int64_t want = Ms(1000).value;  // 120000 ticks
        const int64_t got = renderer.LastFramePts().value;
        const int64_t diff = got > want ? got - want : want - got;
        std::printf("  请求 pts=%lld  实际帧 pts=%lld  偏差=%lld ticks\n",
                    static_cast<long long>(want), static_cast<long long>(got),
                    static_cast<long long>(diff));
        Check(diff <= 4800, "Resize 后帧 pts ≈ 1.0s（帧随时间推进）");
        Check(got != Ms(500).value, "帧 pts 与 0.5s 那次不同（时间真的推进了）");
    }
    std::vector<uint8_t> px_small;
    Check(ReadPixels(renderer.Target(), 128, 128, px_small), "读回 128x128 像素");
    if (!px_small.empty()) {
        const uint8_t* c = &px_small[(static_cast<size_t>(64) * 128 + 64) * 4];
        std::printf("  中心像素 RGBA=%u,%u,%u,%u\n", c[0], c[1], c[2], c[3]);
        Check(ColorNear(c, 0, 188, 0, 255, 12), "Resize 后中心像素仍为真值（未退化）");
    }

    // =========================================================================
    // 7. 单帧耗时实测（UIA-010 子步骤 5）
    // =========================================================================
    // 目的：把「预览帧率」从估算变成实测数字（.ai/memory/baselines.md 的数据来源）。
    // 这里**不做**耗时断言 —— 阈值会随机器漂移，一断言就变成 flaky。
    // 只断言"每一帧都成功且各段都被计时"，数字交给 baselines 记录。
    //
    // ⚠️ 顺序效应：第 1 帧含解码会话建立 / 管线创建 / GPU 唤醒，明显偏慢（实测
    //    本机首帧 total 约为稳态的 2 倍）。故先跑 3 帧预热，只统计后面的。
    std::printf("\n[7] 单帧耗时实测（256x256，30 帧，前 3 帧预热不计入）\n");
    {
        const int kTotal = 33;
        const int kWarmup = 3;
        int64_t sum_acq = 0, sum_imp = 0, sum_drw = 0, sum_tot = 0;
        int64_t max_tot = 0, min_tot = INT64_MAX;
        int ok_count = 0;
        int timed = 0;
        for (int i = 0; i < kTotal; ++i) {
            const int64_t t = 300 + static_cast<int64_t>(i) * 40;  // 300 ~ 1580 ms
            cq::TextureHandle o = nullptr;
            const cq::Status rs = renderer.RenderFrame(Ms(t), o, token);
            if (!rs.IsOk()) {
                std::printf("  FAIL: t=%lldms code=%d\n", static_cast<long long>(t),
                            static_cast<int>(rs.code));
                continue;
            }
            ++ok_count;
            if (i < kWarmup) continue;
            const cq::PreviewRenderer::Timings& tm = renderer.LastTimings();
            sum_acq += tm.acquire_ns;
            sum_imp += tm.import_ns;
            sum_drw += tm.draw_ns;
            sum_tot += tm.total_ns;
            if (tm.total_ns > max_tot) max_tot = tm.total_ns;
            if (tm.total_ns < min_tot) min_tot = tm.total_ns;
            ++timed;
        }
        Check(ok_count == kTotal, "33 帧全部渲染成功");
        Check(timed == kTotal - kWarmup, "30 帧进入统计");
        if (timed > 0) {
            const double n = static_cast<double>(timed);
            std::printf("  均值 ns : acquire=%lld import=%lld draw=%lld total=%lld\n",
                        static_cast<long long>(static_cast<double>(sum_acq) / n),
                        static_cast<long long>(static_cast<double>(sum_imp) / n),
                        static_cast<long long>(static_cast<double>(sum_drw) / n),
                        static_cast<long long>(static_cast<double>(sum_tot) / n));
            std::printf("  单帧 total: min=%lld max=%lld ns（%.2f ms / %.2f ms）\n",
                        static_cast<long long>(min_tot), static_cast<long long>(max_tot),
                        static_cast<double>(min_tot) / 1e6,
                        static_cast<double>(max_tot) / 1e6);
            std::printf("  稳态上限帧率 ≈ %.1f fps（1 / 均值 total）\n",
                        1e9 / (static_cast<double>(sum_tot) / n));
            Check(sum_tot > 0, "total 有累计（埋点可用）");
            Check(max_tot > 0, "max total > 0");
        }
    }

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
