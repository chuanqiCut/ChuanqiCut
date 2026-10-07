// ChuanqiCut — MEDIA-020 真实 B 帧文件精确 seek 验证（Apple：真实 PALA-010 demux）
//
// 把 B 帧精确 seek 从「mock 小 GOP」升级到「真实仓库 golden 文件」：
//   tests/golden/frames/gf_1080p_h264_long_gop_bframes.mp4
//   （manifest: fps=30, frame_count=300, gop_size=60, bframes=3）。
//
// 本测试验证的组件 = MEDIA-020 SystemFrameProvider 的 kExact 编排 + PALA-010 解封装/
// 关键帧判定/Seek 吸附（修复后）。修复后「是否关键帧」与「kKeyframeBefore 是否回退关键帧」
// 均改回用 **demuxer 自己的 is_keyframe 标志** 做断言（不再依赖 ffprobe 真值兜底）。
//
// ground truth（ffprobe / AVFoundation 一致，仅当参考基准）：关键帧(I) 显示时间
//   0.0667/2.0667/4.0667/6.0667/8.0667 s → 项目网格 ticks {8000, 248000, 488000, 728000, 968000}。
// 注意：本 golden 文件首个 IDR 样本 native pts = 1024（15360 timebase）= 第 2 帧 = 0.0667s，
//   即存在 2 帧(8000 ticks)起始偏移，关键帧落在 0.0667/2.0667/...s 而非 0/2/4/...s（"0/2/4" 是
//   约数）。demuxer 解析 IDR/IRAP 后报出的集合应与下逐帧吻合。B 帧如 0.066667/0.100000/2.066667 s。

#include <cstdint>
#include <cstdio>
#include <memory>
#include <set>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/rational_time.h"
#include "cq/media/system_frame_provider.h"
#include "cq/pal/media.h"

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

const char* Rt(const cq::RationalTime& t) {
    static char buf[8][64];
    static int slot = 0;
    char* b = buf[slot++ % 8];
    std::snprintf(b, sizeof(buf[0]), "v=%lld/%d", static_cast<long long>(t.value),
                  static_cast<int>(t.timescale));
    return b;
}

// ----- 真实文件 ground truth（来自 ffprobe，仓库 golden 的稳定真值）-----
constexpr int64_t kTs = cq::kProjectTimeScale;  // 120000
constexpr int64_t kFrameTicks = kTs / 30;        // 30fps → 4000 ticks/帧
constexpr int64_t kExpectedFrames = 300;
// 该 golden 文件真实关键帧（I）位置：0.0667/2.0667/4.0667/6.0667/8.0667 s（见上方说明的 2 帧起始偏移）。
const int64_t kTruthKF[] = {8000, 248000, 488000, 728000, 968000};
constexpr int kTruthKFCount = static_cast<int>(sizeof(kTruthKF) / sizeof(kTruthKF[0]));
// 选作目标的 B 帧（显示时间，秒）——均为 B 帧（非关键帧），其展示帧正是精确 seek 要取的。
// 注意：本文件关键帧落在 0.0667/2.0667/4.0667/…，故不能把 0.0667/2.0667 当 B 帧目标
// （它们本身就是关键帧），这里取 GOP 内部的真实 B 帧：0.1000(f3)/2.1000(f63)/4.1000(f123)。
const double kBTargetSec[] = {0.100000, 2.100000, 4.100000};

// ---------------------------------------------------------------------------
// ReorderingMockDecoder：仅依据「pts 网格」把解码序包重排为显示序，不预知 GOP。
//   规则：缓冲已喂入的包；当最小 pts 的缓冲帧 X 满足「[min_pts, X] 之间按帧距 dt 的
//   所有 pts 都已被喂入(received)」时才弹出 X（显示序）。忠实建模 DPB：P 帧在它之前的
//   B 帧被喂入前不会越前显示；从而把真实 demuxer 的解码序包还原成显示序。刻意暴露并
//   正确消化「解码序 ≠ 显示序」分离。
// ---------------------------------------------------------------------------
class ReorderingMockDecoder : public cq::IFrameDecoder {
public:
    explicit ReorderingMockDecoder(int64_t frame_ticks) : dt_(frame_ticks) {}

    cq::Status Open(const cq::StreamInfo&) override { return cq::Status::Ok(); }

    cq::Status Feed(const cq::MediaPacket& pkt) override {
        int64_t p = pkt.pts.value;  // demuxer 已 Rescale 到 120000 网格
        buf_.push_back(F{p, pkt.is_keyframe});
        received_.insert(p);
        if (min_pts_ == kUnset || p < min_pts_) min_pts_ = p;
        return cq::Status::Ok();
    }

    cq::Status PopFrame(cq::MediaFrame& out) override {
        if (buf_.empty()) return cq::Status{cq::StatusCode::kIoNotFound};
        size_t cand = 0;
        for (size_t i = 1; i < buf_.size(); ++i) {
            if (buf_[i].pts < buf_[cand].pts) cand = i;
        }
        const int64_t X = buf_[cand].pts;
        if (dt_ > 0 && min_pts_ != kUnset) {
            int64_t steps = (X - min_pts_) / dt_;
            for (int64_t k = 0; k <= steps; ++k) {
                if (received_.count(min_pts_ + k * dt_) == 0) {
                    return cq::Status{cq::StatusCode::kIoNotFound};  // 还有更小的帧未到
                }
            }
        }
        out = cq::MediaFrame{};
        out.type = cq::MediaType::kVideo;
        out.video.pts = cq::RationalTime{X, kTs};
        out.video.duration = cq::RationalTime{dt_, kTs};
        out.video.width = 1920;
        out.video.height = 1080;
        out.video.pixel_format = cq::PixelFormat::kYUV420SemiPlanar;
        buf_.erase(buf_.begin() + static_cast<long>(cand));
        return cq::Status::Ok();
    }

    void Flush() override {
        buf_.clear();
        received_.clear();
        min_pts_ = kUnset;
    }

private:
    struct F { int64_t pts; bool kf; };
    static constexpr int64_t kUnset = 0x7fffffffffffffffLL;
    std::vector<F> buf_;
    std::set<int64_t> received_;
    int64_t min_pts_ = kUnset;
    int64_t dt_;
};

struct PktInfo { int64_t pts; bool kf; };

// demuxer 报告的关键帧 pts 集合中是否含某 pts（用 demuxer 自己的 is_keyframe 标志）。
// 关键帧 pts 是精确整数网格值，用「远小于一帧」的容差判定，避免与相邻 B 帧（同 GOP 内
// 仅差一帧，如 0.0667s 关键帧与 0.1000s B 帧相差 4000 ticks）误判为关键帧。
bool DemuxReportsKeyframe(const std::vector<int64_t>& demux_kf, int64_t pts) {
    const int64_t tol = kFrameTicks / 4;  // 1000 ticks < 一帧(4000)，仅精确命中关键帧
    for (int64_t k : demux_kf) {
        if (k >= pts - tol && k <= pts + tol) return true;
    }
    return false;
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut MEDIA-020 真实 B 帧文件精确 seek 验证 ==\n");
    std::printf("样本: tests/golden/frames/gf_1080p_h264_long_gop_bframes.mp4\n");

    const std::string path =
        std::string(CQ_SOURCE_DIR) + "/tests/golden/frames/gf_1080p_h264_long_gop_bframes.mp4";
    cq::MediaSource src;
    src.path = path.c_str();
    src.path_len = path.size();

    cq::PalPtr<cq::IMediaDemuxer> demuxer;
    cq::Status s = cq::CreateMediaDemuxer(src, demuxer);
    Check(s.IsOk() && demuxer, "CreateMediaDemuxer（真实 B 帧文件）打开成功");
    if (!demuxer) {
        std::printf("\n真实 demuxer 打开失败，用例终止。\n");
        return 1;
    }

    // ---- PASS 1：真实 demuxer 全读一遍，收集帧数/pts 集合/is_keyframe ----
    std::vector<PktInfo> all_pkts;
    std::set<int64_t> all_pts;
    std::vector<int64_t> demux_kf_pts;   // demuxer 自带 is_keyframe 报告的关键帧 pts
    int64_t prev_raw_pts = -1;
    bool raw_monotonic = true;
    int total = 0;
    cq::MediaPacket pkt{};
    cq::CancelToken no_cancel;
    while (true) {
        cq::Status r = demuxer->ReadPacket(pkt);
        if (r.code == cq::StatusCode::kIoNotFound) break;
        if (!r.IsOk()) {
            std::printf("  ReadPacket 错误: %s\n", cq::StatusToString(r.code));
            break;
        }
        if (total > 0 &&
            cq::CompareRational(pkt.pts, cq::RationalTime{prev_raw_pts, kTs}) < 0) {
            raw_monotonic = false;  // 解码序下 B 帧会让 pts 回退
        }
        prev_raw_pts = pkt.pts.value;
        all_pkts.push_back(PktInfo{pkt.pts.value, pkt.is_keyframe});
        all_pts.insert(pkt.pts.value);
        if (pkt.is_keyframe) demux_kf_pts.push_back(pkt.pts.value);
        ++total;
    }
    std::printf("\n[真实 demuxer] 共 %d 包；原始(dts)序下 pts 单调=%s\n",
                total, raw_monotonic ? "true" : "false（符合 B 帧解码序预期）");
    Check(total == static_cast<int>(kExpectedFrames), "真实总帧数 = 300（对照 manifest/ffprobe）");
    Check(all_pts.size() == static_cast<size_t>(kExpectedFrames),
          "300 个 pts 互异（无重复/无缺失，线性网格）");
    Check(!raw_monotonic, "原始(dts)序 pts 非单调：真实暴露「解码序≠显示序」分离（团队警示点）");

    // ---- 解码序→显示序重排正确性：把所有包喂入重排 MockDecoder，弹出应严格递增 ----
    {
        ReorderingMockDecoder dec(kFrameTicks);
        dec.Open(cq::StreamInfo{});
        for (const PktInfo& p : all_pkts) {
            cq::MediaPacket mp{};
            mp.pts = cq::RationalTime{p.pts, kTs};
            mp.is_keyframe = p.kf;
            dec.Feed(mp);
        }
        std::vector<int64_t> out_pts;
        cq::MediaFrame f{};
        while (dec.PopFrame(f).IsOk()) out_pts.push_back(f.video.pts.value);
        bool disp_mono = true;
        for (size_t i = 1; i < out_pts.size(); ++i) {
            if (out_pts[i] <= out_pts[i - 1]) disp_mono = false;
        }
        Check(out_pts.size() == static_cast<size_t>(kExpectedFrames),
              "重排后输出 300 帧（解码序→显示序无损）");
        Check(disp_mono, "重排后显示序严格单调递增（B 帧被正确重排到显示位）");
    }

    // ===== 验收 1：demuxer 关键帧集合必须与 ffprobe key_frame=1 逐帧吻合 =====
    {
        std::printf("\n[验收 1 — demuxer 关键帧 vs ffprobe key_frame=1]\n");
        std::printf("  demuxer 报告关键帧数 = %zu；ffprobe 真值关键帧数 = %d\n",
                    demux_kf_pts.size(), kTruthKFCount);
        // 逐帧吻合：每个 demuxer 关键帧都能在真值里找到 ≤1 帧容差的位置，且计数一致。
        int matched = 0;
        for (int64_t dk : demux_kf_pts) {
            bool ok = false;
            for (int i = 0; i < kTruthKFCount; ++i) {
                if (dk >= kTruthKF[i] - kFrameTicks && dk <= kTruthKF[i] + kFrameTicks) {
                    ok = true; break;
                }
            }
            if (ok) ++matched;
        }
        // 反向：每个真值关键帧都被 demuxer 命中
        int truth_hit = 0;
        for (int i = 0; i < kTruthKFCount; ++i) {
            bool hit = false;
            for (int64_t dk : demux_kf_pts) {
                if (dk >= kTruthKF[i] - kFrameTicks && dk <= kTruthKF[i] + kFrameTicks) {
                    hit = true; break;
                }
            }
            if (hit) ++truth_hit;
        }
        std::printf("  demuxer 关键帧命中真值 = %d/%zu；真值关键帧被命中 = %d/%d\n",
                    matched, demux_kf_pts.size(), truth_hit, kTruthKFCount);
        Check(demux_kf_pts.size() == static_cast<size_t>(kTruthKFCount),
              "关键帧数量与 ffprobe 真值一致（逐帧吻合前提：数量相等）");
        Check(matched == static_cast<int>(demux_kf_pts.size()) && truth_hit == kTruthKFCount,
              "关键帧集合与 ffprobe 逐帧吻合（双向命中，容差 1 帧）");
    }

    // ---- 验收 3（回归）：MEDIA-020 kExact 精确 seek 取真实 B 帧展示帧 ----
    std::printf("\n[验收 3 — MEDIA-020 / kExact] 对 B 帧时间点取「真实展示帧」（回归）\n");
    ReorderingMockDecoder decode(kFrameTicks);
    auto provider = cq::CreateSystemFrameProvider(std::move(demuxer), &decode);
    s = provider->Open(src);
    Check(s.IsOk(), "SystemFrameProvider.Open（真实 demux + 重排 decoder）");

    for (double bt : kBTargetSec) {
        int64_t target = static_cast<int64_t>(bt * kTs + 0.5);  // B 帧目标 ticks
        cq::FrameRequest req;
        req.at = cq::RationalTime{target, kTs};
        req.policy = cq::SeekPolicy::kExact;
        cq::MediaFrame f{};
        s = provider->AcquireFrame(req, f, no_cancel);
        bool ok = s.IsOk() && f.type == cq::MediaType::kVideo;
        bool pts_ok = ok && (f.video.pts.value >= target - kFrameTicks &&
                             f.video.pts.value <= target + kFrameTicks);
        // 「不是关键帧」用 demuxer 自己的 is_keyframe 标志集合核对（修复后已可靠）。
        bool not_kf = ok && !DemuxReportsKeyframe(demux_kf_pts, f.video.pts.value);
        std::printf("  t=%s B帧 → 取到帧 pts=%s（期望~%lld）\n",
                    Rt(req.at), Rt(f.video.pts), static_cast<long long>(target));
        char msg[96];
        std::snprintf(msg, sizeof(msg),
                      "kExact t=%.4fs 返回展示帧(pts=%lld≈B帧) 且 demuxer 标志为非关键帧",
                      bt, static_cast<long long>(target));
        Check(ok && pts_ok && not_kf, msg);
    }

    // ===== 验收 2：kKeyframeBefore 必须返回 ≤t 真值关键帧（修复 Seek 吸附后）=====
    std::printf("\n[验收 2 — kKeyframeBefore 返回 demuxer 关键帧（修复后）]\n");
    for (double bt : kBTargetSec) {
        int64_t target = static_cast<int64_t>(bt * kTs + 0.5);
        cq::PalPtr<cq::IMediaDemuxer> d2;
        cq::CreateMediaDemuxer(src, d2);
        ReorderingMockDecoder dec2(kFrameTicks);
        auto p2 = cq::CreateSystemFrameProvider(std::move(d2), &dec2);
        p2->Open(src);
        // 期望 = demuxer 报告的关键帧中 <=target 的最大者（用 demuxer 自己的标志）。
        int64_t exp_kf = 0;
        for (int64_t k : demux_kf_pts) {
            if (k <= target && k > exp_kf) exp_kf = k;
        }
        cq::FrameRequest req;
        req.at = cq::RationalTime{target, kTs};
        req.policy = cq::SeekPolicy::kKeyframeBefore;
        cq::MediaFrame fk{};
        cq::Status sk = p2->AcquireFrame(req, fk, no_cancel);
        bool match = sk.IsOk() && (fk.video.pts.value >= exp_kf - kFrameTicks &&
                                   fk.video.pts.value <= exp_kf + kFrameTicks);
        std::printf("  t=%.4fs 期望关键帧=%lld → 实际返回 pts=%s（命中=%s）\n",
                    bt, static_cast<long long>(exp_kf), Rt(fk.video.pts),
                    match ? "yes" : "no");
        char msg[96];
        std::snprintf(msg, sizeof(msg),
                      "kKeyframeBefore t=%.4fs 返回 <=t 关键帧(pts=%lld)", bt,
                      static_cast<long long>(exp_kf));
        Check(match, msg);
    }

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
