// ChuanqiCut — MEDIA-020 SystemFrameProvider 编排逻辑单测（Mock 驱动）
//
// 不依赖任何真实解码器 / 平台后端。用 MockDemuxer + MockDecoder 注入一个带 B 帧的
// 小 GOP（I P B B，解码序 dts 0,1,2,3；显示序 pts 0,1,2,3），重点验证：
//   * kExact 在 t 处返回「真正的展示帧」——尤其 t 落在 B 帧（pts=2）时，provider
//     必须前向解码到其依赖的 P 帧（dts=1）之后，才能弹出该 B 帧（精确 seek 核心）。
//   * kKeyframeBefore 返回 <= t 最近关键帧（缩略图语义）。
//   * kNearest 返回 |pts - t| 最小的可解码帧。
//   * 取消：AcquireFrame 返回 kCancelled，且 IsError()==false（取消非错误）。
//   * 帧-at-t 用「显示区间归属」pts <= t < pts+duration 判定。
//
// 无缓冲输出：崩溃/挂起时仍能看到进度。

#include <cstdint>
#include <cstdio>
#include <memory>
#include <set>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/media/system_frame_provider.h"
#include "cq/pal/common.h"
#include "cq/pal/media.h"

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

// 测试 GOP 的本地时间网格（4 帧 @4fps，每帧 duration=1 tick；仅用于单测，
// 与项目 120000 网格逻辑等价，算法正确性不受 timescale 影响）。
constexpr int32_t kTs = 4;

bool Contains(const cq::MediaFrame& f, const cq::RationalTime& t) {
    if (f.type != cq::MediaType::kVideo) return false;
    cq::RationalTime end{0, 1};
    cq::Status s = cq::AddRational(f.video.pts, f.video.duration, end);
    if (!s.IsOk()) return false;
    return cq::CompareRational(f.video.pts, t) <= 0 && cq::CompareRational(t, end) < 0;
}

const char* Rt(const cq::RationalTime& t) {
    static char buf[8][64];
    static int slot = 0;
    char* b = buf[slot++ % 8];
    std::snprintf(b, sizeof(buf[0]), "v=%lld/%d", static_cast<long long>(t.value),
                  static_cast<int>(t.timescale));
    return b;
}

// ---------------------------------------------------------------------------
// MockDemuxer：单 GOP、解码序返回包，Seek 落到 <= t 最近关键帧。
// ---------------------------------------------------------------------------
class MockDemuxer : public cq::IMediaDemuxer {
public:
    struct GP { int64_t dts, pts; bool kf; };
    explicit MockDemuxer(std::vector<GP> gop) : gop_(std::move(gop)) {}

    void Destroy() override { delete this; }
    cq::Status Open(const cq::MediaSource&) override { idx_ = 0; return cq::Status::Ok(); }
    cq::Status GetDuration(cq::RationalTime& d) const override {
        d = cq::RationalTime{static_cast<int64_t>(gop_.size()), kTs};
        return cq::Status::Ok();
    }
    int32_t GetStreamCount() const override { return 1; }
    cq::Status GetStreamInfo(int32_t, cq::StreamInfo& o) const override {
        o = cq::StreamInfo{};
        o.type = cq::MediaType::kVideo;
        o.codec = cq::CodecId::kH264;
        o.width = 64;
        o.height = 36;
        o.time_base = cq::RationalTime{1, kTs};
        return cq::Status::Ok();
    }
    cq::Status Seek(const cq::RationalTime& t, const cq::CancelToken&) override {
        // 唯一关键帧在 pts=0；任何 t>=0 都落到它。
        idx_ = 0;
        (void)t;
        return cq::Status::Ok();
    }
    cq::Status ReadPacket(cq::MediaPacket& out) override {
        out = cq::MediaPacket{};
        if (idx_ >= gop_.size()) return cq::Status{cq::StatusCode::kIoNotFound};
        const GP& g = gop_[static_cast<size_t>(idx_++)];
        out.stream_index = 0;
        out.pts = cq::RationalTime{g.pts, kTs};
        out.dts = cq::RationalTime{g.dts, kTs};
        out.codec = cq::CodecId::kH264;
        out.is_keyframe = g.kf;
        out.data = buf_.data();
        out.size = buf_.size();
        return cq::Status::Ok();
    }

private:
    std::vector<GP> gop_;
    size_t idx_ = 0;
    std::vector<uint8_t> buf_ = std::vector<uint8_t>(16, 0xAB);
};

// ---------------------------------------------------------------------------
// MockDecoder：带 B 帧 DPB 重排的解码接缝（忠实建模真实解码器行为）。
//   * release = 该帧可被重建所要求「最后喂入的 dts」（参考帧齐备）。
//     I/P 帧 release = 自身 dts；B 帧 release = 其依赖的 P 帧 dts。
//   * 关键 DPB 规则：某帧要「显示」出来，除了自身已喂入且参考齐备，还要求所有
//     **显示序更靠前（pts 更小）的帧都已喂入**——否则 P 帧不能越过尚未进入解码器
//     的 B 帧先显示（真实 DPB 会压住 P 帧）。这条规则正是精确 seek 必须对 B 帧
//     继续前向解码的成因，故必须被 mock 如实建模，否则测不出 provider 的正确行为。
// ---------------------------------------------------------------------------
class MockDecoder : public cq::IFrameDecoder {
public:
    struct Spec { int64_t dts, pts, release; };
    explicit MockDecoder(std::vector<Spec> specs) : specs_(std::move(specs)) {
        for (const Spec& s : specs_) all_pts_.insert(s.pts);
    }

    cq::Status Open(const cq::StreamInfo&) override { return cq::Status::Ok(); }
    cq::Status Feed(const cq::MediaPacket& pkt) override {
        last_fed_dts_ = pkt.dts.value;
        for (const Spec& s : specs_) {
            if (s.dts == pkt.dts.value) {
                pending_.push_back(P{s.pts, s.release});
                fed_pts_.insert(s.pts);
                break;
            }
        }
        return cq::Status::Ok();
    }
    cq::Status PopFrame(cq::MediaFrame& out) override {
        size_t best_i = pending_.size();
        int64_t best_pts = 0;
        bool found = false;
        for (size_t i = 0; i < pending_.size(); ++i) {
            const P& fp = pending_[static_cast<size_t>(i)];
            if (fp.release > last_fed_dts_) continue;  // 参考帧未齐备
            // 显示序更靠前的帧若尚未喂入，则本帧被 DPB 压住，不能越前显示。
            bool blocked = false;
            for (int64_t y : all_pts_) {
                if (y < fp.pts && fed_pts_.find(y) == fed_pts_.end()) {
                    blocked = true;
                    break;
                }
            }
            if (blocked) continue;
            if (!found || fp.pts < best_pts) {
                found = true;
                best_pts = fp.pts;
                best_i = i;
            }
        }
        if (!found) return cq::Status{cq::StatusCode::kIoNotFound};
        out = cq::MediaFrame{};
        out.type = cq::MediaType::kVideo;
        out.video.pts = cq::RationalTime{best_pts, kTs};
        out.video.duration = cq::RationalTime{1, kTs};
        out.video.width = 64;
        out.video.height = 36;
        out.video.pixel_format = cq::PixelFormat::kYUV420SemiPlanar;
        pending_.erase(pending_.begin() + static_cast<long>(best_i));
        return cq::Status::Ok();
    }
    void Flush() override {
        pending_.clear();
        fed_pts_.clear();
        last_fed_dts_ = -1;
    }

private:
    struct P { int64_t pts, release; };
    std::vector<Spec> specs_;
    std::vector<P> pending_;
    std::set<int64_t> all_pts_;   // 本 GOP 全部显示 pts（已知结构）
    std::set<int64_t> fed_pts_;   // 已喂入的 pts（输出后保留，表示已解决）
    int64_t last_fed_dts_ = -1;
};

// 构造一个 4 帧 GOP（I P B B）：解码序 dts 0,1,2,3；显示序 pts 0,1,2,3。
std::vector<MockDemuxer::GP> MakeGop() {
    return {
        {0, 0, true},   // I  (显示 0)
        {1, 3, false},  // P  (显示 3)
        {2, 1, false},  // B  (显示 1，依赖 P dts=1)
        {3, 2, false},  // B  (显示 2，依赖 P dts=1)
    };
}
std::vector<MockDecoder::Spec> MakeSpec() {
    return {
        {0, 0, 0},  // I  release=0
        {1, 3, 1},  // P  release=1
        {2, 1, 1},  // B  release=1（依赖 P）
        {3, 2, 1},  // B  release=1（依赖 P）
    };
}

// 取一帧并打印真实数字。
cq::Status Acquire(cq::FrameProvider& fp, int64_t t_val, cq::SeekPolicy policy,
                   const cq::CancelToken& token, cq::MediaFrame& out) {
    cq::FrameRequest req;
    req.at = cq::RationalTime{t_val, kTs};
    req.policy = policy;
    return fp.AcquireFrame(req, out, token);
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut MEDIA-020 SystemFrameProvider 编排单测 ==\n");

    auto demuxer = std::make_unique<MockDemuxer>(MakeGop());
    MockDecoder decoder(MakeSpec());
    cq::MediaSource src{};
    auto provider = cq::CreateSystemFrameProvider(
        cq::PalPtr<cq::IMediaDemuxer>(demuxer.release()), &decoder);
    cq::Status s = provider->Open(src);
    Check(s.IsOk(), "Open 成功（demuxer + decoder 注入）");
    if (!s.IsOk()) {
        std::printf("\nOpen 失败，用例终止。\n");
        return 1;
    }

    cq::RationalTime dur{0, 1};
    s = provider->GetDuration(dur);
    Check(s.IsOk() && dur.value == 4 && dur.timescale == kTs,
          "GetDuration = 4 帧 @4fps");

    cq::CancelToken no_cancel;

    // ---- kExact：每个 t 返回真正包含 t 的展示帧（含 B 帧 t=2）----
    std::printf("\n[kExact] 逐帧精确 seek（含 B 帧）\n");
    const int64_t expect_pts[] = {0, 1, 2, 3};  // 显示序
    for (int64_t t = 0; t < 4; ++t) {
        cq::MediaFrame f{};
        s = Acquire(*provider, t, cq::SeekPolicy::kExact, no_cancel, f);
        bool ok = s.IsOk() && f.type == cq::MediaType::kVideo &&
                  f.video.pts.value == expect_pts[static_cast<size_t>(t)] &&
                  Contains(f, cq::RationalTime{t, kTs});
        std::printf("  t=%lld -> 帧 pts=%s (expect %lld) 区间包含=%d\n",
                    static_cast<long long>(t), Rt(f.video.pts),
                    static_cast<long long>(expect_pts[static_cast<size_t>(t)]),
                    Contains(f, cq::RationalTime{t, kTs}) ? 1 : 0);
        char msg[64];
        std::snprintf(msg, sizeof(msg), "kExact t=%lld 返回展示帧 pts=%lld 且区间归属",
                      static_cast<long long>(t),
                      static_cast<long long>(expect_pts[static_cast<size_t>(t)]));
        Check(ok, msg);
    }

    // ---- kKeyframeBefore：t=2 应返回关键帧（pts=0），而非精确帧（pts=2）----
    std::printf("\n[kKeyframeBefore] t=2 应返回 <=t 最近关键帧\n");
    {
        cq::MediaFrame f{};
        s = Acquire(*provider, 2, cq::SeekPolicy::kKeyframeBefore, no_cancel, f);
        bool ok = s.IsOk() && f.video.pts.value == 0 && !Contains(f, cq::RationalTime{2, kTs});
        std::printf("  t=2 -> 帧 pts=%s（关键帧 pts=0，非精确帧 pts=2）\n", Rt(f.video.pts));
        Check(ok, "kKeyframeBefore t=2 返回关键帧 pts=0（缩略图语义）");
    }

    // ---- kNearest：t=2 返回最近帧（pts=2，dist=0）----
    std::printf("\n[kNearest] t=2 返回 |pts-t| 最小帧\n");
    {
        cq::MediaFrame f{};
        s = Acquire(*provider, 2, cq::SeekPolicy::kNearest, no_cancel, f);
        bool ok = s.IsOk() && f.video.pts.value == 2;
        std::printf("  t=2 -> 帧 pts=%s（nearest=2）\n", Rt(f.video.pts));
        Check(ok, "kNearest t=2 返回最近帧 pts=2");
    }

    // ---- 取消语义：返回 kCancelled 且 IsError()==false ----
    std::printf("\n[取消] AcquireFrame 在取消时返回 kCancelled（非错误）\n");
    {
        cq::CancelToken cancelled;
        cancelled.RequestCancel();
        cq::MediaFrame f{};
        s = Acquire(*provider, 1, cq::SeekPolicy::kExact, cancelled, f);
        std::printf("  -> code=%s IsError=%d IsCancelled=%d\n",
                    cq::StatusToString(s.code), s.IsError() ? 1 : 0, s.IsCancelled() ? 1 : 0);
        Check(s.IsCancelled() && !s.IsError(),
              "取消返回 kCancelled 且 IsError()==false（取消非错误）");
    }

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
