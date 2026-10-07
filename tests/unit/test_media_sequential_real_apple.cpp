// ChuanqiCut — MEDIA-021 顺序取帧快路径真实链路验证（Apple 硬解）
//
// 素材：tests/golden/frames/gf_1080p_h264_long_gop_bframes.mp4
// （manifest: fps=30, frame_count=300, gop_size=60, bframes=3, vfr=false）。
// 这是 P38 修复（顺序取帧不每帧 seek）的**端到端验收**：
//
//   1. 正确性：模拟泵的顺序请求（每步 +1/30s），逐帧断言 pts 严格递增 +
//      展示区间归属 —— 静态彩条像素看不出差一帧，pts 是唯一证据。
//   2. 性能：快路径 acquire 均值显著低于「每帧显式 seek」的对照实例；
//      同时输出两段的均值/最大值（写回 .ai/memory/baselines.md）。
//
// 对照实例 = 独立 provider + 每次显式 Seek（强制旧的「从关键帧重解 GOP」语义）。
// 性能断言只做宽松比较（快 < 慢），具体倍数因机型而异，不写死阈值。

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "cq/base/concurrency.h"
#include "cq/base/status.h"
#include "cq/base/rational_time.h"
#include "cq/media/system_frame_provider.h"
#include "cq/pal/media.h"
#include "media_decode.h"  // PALA-011 VideoToolboxDecoder（仅 Apple TU 可见）

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

bool Contains(const cq::MediaFrame& f, const cq::RationalTime& t) {
    if (f.type != cq::MediaType::kVideo) return false;
    cq::RationalTime end{0, 1};
    if (!cq::AddRational(f.video.pts, f.video.duration, end).IsOk()) return false;
    return cq::CompareRational(f.video.pts, t) <= 0 && cq::CompareRational(t, end) < 0;
}

// 请求网格必须用整数 ticks 构造：浮点 ms*120 会截断出 3999/4000 交替的步长，
// 大量请求落回同一帧展示区间内（重复取帧是正确行为，但会污染"严格递增"断言
// 与性能均值 —— 首版实测 120 请求只有 31 个不同 pts，即此因）。
constexpr int64_t kStartTicks = 120000;  // 1.0s：避开首 GOP 的 2 帧起始偏移
constexpr int64_t kStepTicks = 4000;     // 1/30s：恰好每步跨一帧界

using Clock = std::chrono::steady_clock;

struct RunStats {
    int64_t count = 0;
    double total_ms = 0.0;
    double max_ms = 0.0;
    void Add(double ms) {
        ++count;
        total_ms += ms;
        max_ms = std::max(max_ms, ms);
    }
    double MeanMs() const { return count > 0 ? total_ms / static_cast<double>(count) : 0.0; }
};

// 组装真实链路：PALA-010 demuxer + PALA-011 硬解 + MEDIA-020 编排。
// 每个实例独立（对照实验不能共享解码器状态）。
std::unique_ptr<cq::FrameProvider> MakeProvider(const cq::MediaSource& src,
                                                cq::VideoToolboxDecoder** out_decoder) {
    cq::PalPtr<cq::IMediaDemuxer> demuxer;
    if (!cq::CreateMediaDemuxer(src, demuxer).IsOk() || !demuxer) return nullptr;
    auto* decoder = new cq::VideoToolboxDecoder(src.path);
    auto provider = cq::CreateSystemFrameProvider(
        std::move(demuxer), std::unique_ptr<cq::IFrameDecoder>(decoder));
    if (!provider->Open(src).IsOk()) return nullptr;
    if (out_decoder != nullptr) *out_decoder = decoder;
    return provider;
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("=== MEDIA-021：顺序取帧快路径（真实硬解链路）===\n");

    const std::string path =
        std::string(CQ_SOURCE_DIR) + "/tests/golden/frames/gf_1080p_h264_long_gop_bframes.mp4";
    std::printf("样本: %s（30fps / GOP 60 / B帧3 / 300 帧）\n", path.c_str());

    cq::MediaSource src;
    src.path = path.c_str();
    src.path_len = path.size();

    // 请求序列：从 1.0s 起连续 120 帧（跨 2 个 GOP 边界），步长恰为一帧（整数
    // ticks，见 kStepTicks 注释）。起点避开首 GOP 的 2 帧起始偏移（首 IDR 在
    // 0.0667s），让区间归属判定稳定。
    constexpr int kFrames = 120;
    std::vector<cq::RationalTime> reqs;
    reqs.reserve(kFrames);
    for (int i = 0; i < kFrames; ++i) {
        reqs.push_back(cq::RationalTime{kStartTicks + i * kStepTicks, cq::kProjectTimeScale});
    }

    cq::CancelToken no_cancel;

    // ---- 1. 被测实例：纯顺序请求（快路径应逐步接管）----
    std::printf("\n[快路径] 顺序请求 %d 帧（每步 +1/30s）\n", kFrames);
    cq::VideoToolboxDecoder* fast_decoder = nullptr;
    auto fast = MakeProvider(src, &fast_decoder);
    Check(fast != nullptr, "被测实例 Open 成功（PALA-010/011 + MEDIA-020）");
    if (fast == nullptr) return 1;
    std::printf("  硬解: %s\n",
                (fast_decoder != nullptr && fast_decoder->IsHardwareAccelerated()) ? "是"
                                                                                    : "否（软解/回退）");

    RunStats fast_stats;
    int64_t prev_pts = -1;
    int monotonic_ok = 0;   // pts 严格递增次数
    int contains_ok = 0;    // 区间归属次数
    int failed = 0;
    std::vector<int64_t> fast_pts;
    for (int i = 0; i < kFrames; ++i) {
        cq::FrameRequest req;
        req.at = reqs[static_cast<size_t>(i)];
        req.policy = cq::SeekPolicy::kExact;
        cq::MediaFrame f;
        const Clock::time_point t0 = Clock::now();
        cq::Status s = fast->AcquireFrame(req, f, no_cancel);
        const double ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
        if (!s.IsOk() || f.type != cq::MediaType::kVideo) {
            ++failed;
            std::printf("  FAIL: 第 %d 帧取帧失败 code=%d\n", i, static_cast<int>(s.code));
            continue;
        }
        fast_stats.Add(ms);
        fast_pts.push_back(f.video.pts.value);
        if (f.video.pts.value > prev_pts) ++monotonic_ok;
        if (Contains(f, reqs[static_cast<size_t>(i)])) ++contains_ok;
        prev_pts = f.video.pts.value;
    }
    std::printf("  acquire: n=%lld mean=%.2fms max=%.2fms\n",
                static_cast<long long>(fast_stats.count), fast_stats.MeanMs(),
                fast_stats.max_ms);
    std::printf("  严格递增 %d/%d，区间归属 %d/%d，失败 %d\n", monotonic_ok, kFrames,
                contains_ok, kFrames, failed);
    Check(failed == 0, "顺序 120 帧全部取帧成功");
    Check(monotonic_ok == kFrames, "逐帧 pts 严格递增（每步跨帧界，无重复/回跳）");
    Check(contains_ok == kFrames, "逐帧区间归属（kExact：拿到的是请求时刻的展示帧）");

    // ---- 2. 对照实例：每帧显式 Seek（旧「重解 GOP」语义）----
    std::printf("\n[对照] 同序列、每帧显式 Seek（强制从关键帧重解）\n");
    auto slow = MakeProvider(src, nullptr);
    Check(slow != nullptr, "对照实例 Open 成功");
    if (slow == nullptr) return 1;

    RunStats slow_stats;
    std::vector<int64_t> slow_pts;
    for (int i = 0; i < kFrames; ++i) {
        cq::FrameRequest req;
        req.at = reqs[static_cast<size_t>(i)];
        req.policy = cq::SeekPolicy::kExact;
        if (!slow->Seek(req.at, req.policy, no_cancel).IsOk()) continue;
        cq::MediaFrame f;
        const Clock::time_point t0 = Clock::now();
        cq::Status s = slow->AcquireFrame(req, f, no_cancel);
        const double ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
        if (s.IsOk() && f.type == cq::MediaType::kVideo) {
            slow_stats.Add(ms);
            slow_pts.push_back(f.video.pts.value);
        }
    }
    std::printf("  acquire: n=%lld mean=%.2fms max=%.2fms\n",
                static_cast<long long>(slow_stats.count), slow_stats.MeanMs(),
                slow_stats.max_ms);

    // ---- 3. 对照：两实例逐帧 pts 一致（正确性不受快路径影响）----
    {
        const bool same = fast_pts.size() == slow_pts.size() &&
                          std::equal(fast_pts.begin(), fast_pts.end(), slow_pts.begin());
        Check(same, "快/慢路径 120 帧 pts 逐帧一致（kExact 语义不变）");
        if (!same && fast_pts.size() == slow_pts.size()) {
            for (size_t i = 0; i < fast_pts.size(); ++i) {
                if (fast_pts[i] != slow_pts[i]) {
                    std::printf("  首个不一致: #%zu fast=%lld slow=%lld\n", i,
                                static_cast<long long>(fast_pts[i]),
                                static_cast<long long>(slow_pts[i]));
                    break;
                }
            }
        }
    }

    // ---- 4. 性能：快路径均值必须低于对照（宽松断言；数字写 baselines）----
    {
        std::printf("  均值对比: fast=%.2fms slow=%.2fms (%.1fx)\n", fast_stats.MeanMs(),
                    slow_stats.MeanMs(),
                    slow_stats.MeanMs() > 0.0 ? slow_stats.MeanMs() / fast_stats.MeanMs() : 0.0);
        Check(fast_stats.MeanMs() < slow_stats.MeanMs(),
              "快路径 acquire 均值 < 每帧 seek 对照（优化真实生效）");
    }

    std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
