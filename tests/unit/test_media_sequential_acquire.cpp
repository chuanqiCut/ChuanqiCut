// ChuanqiCut — MEDIA-021 顺序取帧快路径单测（Mock 驱动，逐帧 pts 断言）
//
// 背景（TASK-MEDIA-021 / ADR-0017 / pitfalls P38）：顺序播放时每帧
// 「seek + Flush + 重解 GOP」是预览帧率真瓶颈。本测试验证快路径的正确性与
// 生效条件，重点不是"播起来了"，而是**逐帧 pts 断言** —— 静态彩条素材看不
// 出差一帧，pts 是唯一可判定的证据。
//
// 覆盖（对照任务卡验收）：
//   A. 顺序递进 16 帧（4 GOP × I P B B）：每帧 pts 正确 + 区间归属 +
//      seek/flush 只发生在学习期（自适应阈值 proven_span 收敛后不再 seek）。
//   B. 同帧重复请求：仍返回同一帧（consumed_ 修复——旧实现会错误返回下一帧）。
//   C. 回退请求：走慢路径 seek，帧正确。
//   D. 超阈值大步前进：走慢路径 seek（继续解码跨多 GOP 不划算）。
//   E. 混合序列（前进/回退交替）与「每帧都 seek 的参照实现」逐帧一致。
//   F. kKeyframeBefore 行为不受快路径影响（仍每次取关键帧）。
//   G. 取消语义：快路径中取消返回 kCancelled，且后续请求恢复正常。
//   H. 显式 Seek + Acquire 契约用法：不双重 seek；重复 Acquire 同目标会重新 seek。
//
// Mock 与 test_system_frame_provider.cpp 的差异（本文件必须自带，不复用）：
//   * 多 GOP 结构（4 个 GOP），Seek 落到 <= t 的最近关键帧（对齐 PAL 语义）；
//   * demuxer 记 seek 次数、decoder 记 flush 次数（断言快路径不触发）；
//   * decoder 的 DPB 压帧规则限定同 GOP（closed-GOP seek 语义：seek 后前一个
//     GOP 的帧不在 DPB 里，不得阻塞本 GOP 输出）。

#include <cstdint>
#include <cstdio>
#include <memory>
#include <set>
#include <vector>

#include "cq/base/concurrency.h"
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

// 16 帧 = 4 GOP × (I P B B)，每帧 duration = 1 tick @timescale 4。
constexpr int32_t kTs = 4;
constexpr int64_t kGopLen = 4;   // 帧数
constexpr int64_t kFrames = 16;  // 总帧数

bool Contains(const cq::MediaFrame& f, const cq::RationalTime& t) {
    if (f.type != cq::MediaType::kVideo) return false;
    cq::RationalTime end{0, 1};
    cq::Status s = cq::AddRational(f.video.pts, f.video.duration, end);
    if (!s.IsOk()) return false;
    return cq::CompareRational(f.video.pts, t) <= 0 && cq::CompareRational(t, end) < 0;
}

// ---------------------------------------------------------------------------
// CountingDemuxer：多 GOP，解码序返回包，Seek 落到 <= t 最近关键帧，计 seek 次数。
// ---------------------------------------------------------------------------
class CountingDemuxer : public cq::IMediaDemuxer {
public:
    struct GP { int64_t dts, pts; bool kf; };
    explicit CountingDemuxer(std::vector<GP> gop) : packets_(std::move(gop)) {}

    void Destroy() override { delete this; }
    cq::Status Open(const cq::MediaSource&) override { idx_ = 0; return cq::Status::Ok(); }
    cq::Status GetDuration(cq::RationalTime& d) const override {
        d = cq::RationalTime{kFrames, kTs};
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
        ++seek_calls_;
        // 与 PAL 语义一致：落到 <= t 的最近关键帧。
        size_t target = 0;
        bool found = false;
        for (size_t i = 0; i < packets_.size(); ++i) {
            if (packets_[i].kf &&
                cq::CompareRational(cq::RationalTime{packets_[i].pts, kTs}, t) <= 0) {
                target = i;
                found = true;
            }
        }
        if (!found) return cq::Status{cq::StatusCode::kIoNotFound};
        idx_ = target;
        return cq::Status::Ok();
    }
    cq::Status ReadPacket(cq::MediaPacket& out) override {
        out = cq::MediaPacket{};
        if (idx_ >= packets_.size()) return cq::Status{cq::StatusCode::kIoNotFound};
        const GP& g = packets_[idx_++];
        out.stream_index = 0;
        out.pts = cq::RationalTime{g.pts, kTs};
        out.dts = cq::RationalTime{g.dts, kTs};
        out.codec = cq::CodecId::kH264;
        out.is_keyframe = g.kf;
        out.data = buf_.data();
        out.size = buf_.size();
        return cq::Status::Ok();
    }

    int seek_calls() const { return seek_calls_; }

private:
    std::vector<GP> packets_;
    size_t idx_ = 0;
    int seek_calls_ = 0;
    std::vector<uint8_t> buf_ = std::vector<uint8_t>(16, 0xAB);
};

// ---------------------------------------------------------------------------
// CountingDecoder：带 B 帧 DPB 重排的解码接缝 + flush 计数。
// 压帧规则与单 GOP 版一致，但限定同 GOP（closed-GOP：seek 落 IDR 后，前一 GOP
// 的显示帧不在 DPB，不阻塞本 GOP 输出 —— 与 VideoToolbox seek 后行为一致）。
// ---------------------------------------------------------------------------
class CountingDecoder : public cq::IFrameDecoder {
public:
    struct Spec { int64_t dts, pts, release, gop; };
    explicit CountingDecoder(std::vector<Spec> specs) : specs_(std::move(specs)) {
        for (const Spec& s : specs_) all_pts_.insert({s.pts, s.gop});
    }

    cq::Status Open(const cq::StreamInfo&) override { return cq::Status::Ok(); }
    cq::Status Feed(const cq::MediaPacket& pkt) override {
        last_fed_dts_ = pkt.dts.value;
        for (const Spec& s : specs_) {
            if (s.dts == pkt.dts.value) {
                pending_.push_back(P{s.pts, s.release, s.gop});
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
            const P& fp = pending_[i];
            if (fp.release > last_fed_dts_) continue;  // 参考帧未齐备
            bool blocked = false;
            for (const auto& y : all_pts_) {
                if (y.second == fp.gop && y.first < fp.pts &&
                    fed_pts_.find(y.first) == fed_pts_.end()) {
                    blocked = true;  // 同 GOP 内显示序更前的帧尚未喂入，被 DPB 压住
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
        ++flush_calls_;
        pending_.clear();
        fed_pts_.clear();
        last_fed_dts_ = -1;
    }

    int flush_calls() const { return flush_calls_; }

private:
    struct P { int64_t pts, release, gop; };
    std::vector<Spec> specs_;
    std::vector<P> pending_;
    std::set<std::pair<int64_t, int64_t>> all_pts_;  // (pts, gop) 全集
    std::set<int64_t> fed_pts_;
    int64_t last_fed_dts_ = -1;
    int flush_calls_ = 0;
};

// 组装 4 个 GOP（I P B B × 4）：GOP k 占显示 pts [4k, 4k+4)。
std::vector<CountingDemuxer::GP> MakePackets() {
    std::vector<CountingDemuxer::GP> pkts;
    for (int64_t k = 0; k < kFrames / kGopLen; ++k) {
        const int64_t b = k * kGopLen;
        pkts.push_back({b + 0, b + 0, true});   // I  显示 b+0
        pkts.push_back({b + 1, b + 3, false});  // P  显示 b+3
        pkts.push_back({b + 2, b + 1, false});  // B  显示 b+1（依赖 P）
        pkts.push_back({b + 3, b + 2, false});  // B  显示 b+2（依赖 P）
    }
    return pkts;
}
std::vector<CountingDecoder::Spec> MakeSpecs() {
    std::vector<CountingDecoder::Spec> specs;
    for (int64_t k = 0; k < kFrames / kGopLen; ++k) {
        const int64_t b = k * kGopLen;
        specs.push_back({b + 0, b + 0, b + 0, k});  // I  release=自身
        specs.push_back({b + 1, b + 3, b + 1, k});  // P  release=自身
        specs.push_back({b + 2, b + 1, b + 1, k});  // B  release=P
        specs.push_back({b + 3, b + 2, b + 1, k});  // B  release=P
    }
    return specs;
}

// 被测对象：provider + 两个 mock 的组合（seek/flush 计数从 mock 读）。
struct Rig {
    CountingDemuxer* demuxer = nullptr;  // 所有权在 provider（PalPtr）
    CountingDecoder* decoder = nullptr;  // 栈对象生命周期由调用方保证
    std::unique_ptr<cq::FrameProvider> provider;
};

Rig MakeRig() {
    Rig rig;
    rig.demuxer = new CountingDemuxer(MakePackets());
    static CountingDecoder* s_decoder_anchor = nullptr;  // 防悬垂：单测进程内 mock 永生
    (void)s_decoder_anchor;
    rig.decoder = new CountingDecoder(MakeSpecs());
    rig.provider = cq::CreateSystemFrameProvider(
        cq::PalPtr<cq::IMediaDemuxer>(rig.demuxer), rig.decoder);
    cq::MediaSource src{};
    cq::Status s = rig.provider->Open(src);
    if (!s.IsOk()) {
        std::printf("  FATAL: Open 失败\n");
        return rig;
    }
    return rig;
}

cq::Status Acquire(cq::FrameProvider& fp, int64_t t_val, cq::SeekPolicy policy,
                   const cq::CancelToken& token, cq::MediaFrame& out) {
    cq::FrameRequest req;
    req.at = cq::RationalTime{t_val, kTs};
    req.policy = policy;
    out = cq::MediaFrame{};
    return fp.AcquireFrame(req, out, token);
}

// 取一帧并断言 pts == expect 且区间包含；失败打印实际值。
void ExpectFrame(cq::FrameProvider& fp, int64_t t_val, int64_t expect_pts,
                 const cq::CancelToken& token, const char* tag) {
    cq::MediaFrame f{};
    cq::Status s = Acquire(fp, t_val, cq::SeekPolicy::kExact, token, f);
    const bool ok = s.IsOk() && f.type == cq::MediaType::kVideo &&
                    f.video.pts.value == expect_pts &&
                    Contains(f, cq::RationalTime{t_val, kTs});
    std::printf("  [%s] t=%lld -> pts=%lld (expect %lld) ok=%d\n", tag,
                static_cast<long long>(t_val),
                static_cast<long long>(f.video.pts.value),
                static_cast<long long>(expect_pts), ok ? 1 : 0);
    char msg[96];
    std::snprintf(msg, sizeof(msg), "[%s] t=%lld 返回展示帧 pts=%lld 且区间归属", tag,
                  static_cast<long long>(t_val), static_cast<long long>(expect_pts));
    Check(ok, msg);
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut MEDIA-021 顺序取帧快路径单测 ==\n");

    cq::CancelToken no_cancel;

    // ---- A. 顺序递进 16 帧：逐帧正确 + 学习期后不再 seek/flush ----
    std::printf("\n[A] 顺序递进 %lld 帧（每帧 +1 tick）\n", static_cast<long long>(kFrames));
    int seeks_after_learn = 0;
    {
        Rig rig = MakeRig();
        if (rig.provider == nullptr) return 1;
        for (int64_t t = 0; t < kFrames; ++t) {
            ExpectFrame(*rig.provider, t, t, no_cancel, "A");
        }
        // 学习期：t=0（无锚点）与 t=1（跨度 1 > 已证实跨度 0）各 seek 一次；
        // t=2 起 span=1 <= proven=1 走快路径；t=4 快路径跨 GOP 时喂到第二个关键帧，
        // KF 间隔实证（4 tick）进一步放大阈值，其后全部快路径。
        // flush 数 = Open 的初始 flush(1) + 学习期两次 Seek 各一次。
        const int seeks = rig.demuxer->seek_calls();
        const int flushes = rig.decoder->flush_calls();
        std::printf("  seek_calls=%d flush_calls=%d（预期 2 / 3）\n", seeks, flushes);
        Check(seeks == 2, "顺序 16 帧仅学习期 seek 2 次（其后全快路径）");
        Check(flushes == seeks + 1, "flush 仅出现在 Open 与学习期 Seek（快路径不重置 DPB）");
        seeks_after_learn = seeks;

        // ---- B. 同帧重复请求：仍返回同一帧（consumed_ 修复）----
        std::printf("\n[B] 同帧重复请求（旧实现会错返回下一帧）\n");
        const int seeks_b0 = rig.demuxer->seek_calls();
        ExpectFrame(*rig.provider, kFrames - 1, kFrames - 1, no_cancel, "B-repeat");
        ExpectFrame(*rig.provider, kFrames - 1, kFrames - 1, no_cancel, "B-repeat");
        Check(rig.demuxer->seek_calls() == seeks_b0 + 2,
              "同帧重复各重新 seek 一次（像素已按 lease 让渡，必须重解）");

        // ---- C. 回退请求：走慢路径，帧正确 ----
        std::printf("\n[C] 回退请求（t < 上次交付）\n");
        const int seeks_c0 = rig.demuxer->seek_calls();
        ExpectFrame(*rig.provider, 3, 3, no_cancel, "C-back");
        ExpectFrame(*rig.provider, 0, 0, no_cancel, "C-back");
        Check(rig.demuxer->seek_calls() > seeks_c0, "回退请求触发 seek（快路径不适用）");
        delete rig.decoder;
    }

    // ---- D. 超阈值大步前进：走慢路径 ----
    std::printf("\n[D] 超过已证实跨度的大步前进\n");
    {
        Rig rig = MakeRig();
        if (rig.provider == nullptr) return 1;
        // 学到 proven=1（t=0,1 各一次慢路径，同 A）。
        ExpectFrame(*rig.provider, 0, 0, no_cancel, "D");
        ExpectFrame(*rig.provider, 1, 1, no_cancel, "D");
        ExpectFrame(*rig.provider, 2, 2, no_cancel, "D");
        ExpectFrame(*rig.provider, 3, 3, no_cancel, "D");
        const int seeks_d0 = rig.demuxer->seek_calls();
        Check(seeks_d0 == 2, "D 前置：学习期 seek 2 次");
        // 跨度 7 > proven（1）→ 慢路径 seek。
        ExpectFrame(*rig.provider, 10, 10, no_cancel, "D-jump");
        Check(rig.demuxer->seek_calls() == seeks_d0 + 1, "大步前进触发 seek");
        delete rig.decoder;
    }

    // ---- E. 混合序列 vs 「每帧都 seek」的参照实现：逐帧一致 ----
    std::printf("\n[E] 混合序列与参照实现逐帧一致\n");
    {
        Rig rig = MakeRig();
        Rig ref = MakeRig();
        if (rig.provider == nullptr || ref.provider == nullptr) return 1;
        const int64_t seq[] = {0, 1, 2, 3, 4, 2, 1, 5, 9, 6, 7, 15, 11, 12, 13};
        int mismatches = 0;
        for (int64_t t : seq) {
            cq::MediaFrame f{};
            cq::Status s1 = Acquire(*rig.provider, t, cq::SeekPolicy::kExact, no_cancel, f);
            const int64_t got = s1.IsOk() ? f.video.pts.value : -1;

            cq::MediaFrame g{};
            // 参照：显式 Seek 强制「每帧都从关键帧重解」的旧语义。
            cq::Status s0 = ref.provider->Seek(cq::RationalTime{t, kTs},
                                               cq::SeekPolicy::kExact, no_cancel);
            cq::Status s2;
            if (s0.IsOk()) s2 = Acquire(*ref.provider, t, cq::SeekPolicy::kExact, no_cancel, g);
            const int64_t want = (s0.IsOk() && s2.IsOk()) ? g.video.pts.value : -2;

            const bool ok = got == want && got >= 0;
            if (!ok) ++mismatches;
            std::printf("  t=%lld -> 被测 pts=%lld 参照 pts=%lld %s\n",
                        static_cast<long long>(t), static_cast<long long>(got),
                        static_cast<long long>(want), ok ? "ok" : "MISMATCH");
        }
        Check(mismatches == 0, "混合序列 15 步与参照实现逐帧一致");
        delete rig.decoder;
        delete ref.decoder;
    }

    // ---- F. kKeyframeBefore 行为不受快路径影响 ----
    std::printf("\n[F] kKeyframeBefore 顺序请求（缩略图语义）\n");
    {
        Rig rig = MakeRig();
        if (rig.provider == nullptr) return 1;
        const struct { int64_t t, kf; } cases[] = {{2, 0}, {5, 4}, {10, 8}, {15, 12}};
        for (const auto& c : cases) {
            cq::MediaFrame f{};
            cq::Status s = Acquire(*rig.provider, c.t, cq::SeekPolicy::kKeyframeBefore,
                                   no_cancel, f);
            const bool ok = s.IsOk() && f.video.pts.value == c.kf;
            std::printf("  t=%lld -> 关键帧 pts=%lld (expect %lld)\n",
                        static_cast<long long>(c.t),
                        static_cast<long long>(f.video.pts.value),
                        static_cast<long long>(c.kf));
            char msg[96];
            std::snprintf(msg, sizeof(msg), "kKeyframeBefore t=%lld 返回关键帧 pts=%lld",
                          static_cast<long long>(c.t), static_cast<long long>(c.kf));
            Check(ok, msg);
        }
        delete rig.decoder;
    }

    // ---- G. 取消语义：快路径中取消 + 取消后恢复 ----
    std::printf("\n[G] 取消（快路径中返回 kCancelled，之后恢复）\n");
    {
        Rig rig = MakeRig();
        if (rig.provider == nullptr) return 1;
        ExpectFrame(*rig.provider, 0, 0, no_cancel, "G");
        ExpectFrame(*rig.provider, 1, 1, no_cancel, "G");
        cq::CancelToken cancelled;
        cancelled.RequestCancel();
        cq::MediaFrame f{};
        cq::Status s = Acquire(*rig.provider, 2, cq::SeekPolicy::kExact, cancelled, f);
        Check(s.IsCancelled() && !s.IsError(), "取消返回 kCancelled（非错误）");
        // 取消使锚点失效，下一请求必须走慢路径对齐且正确。
        ExpectFrame(*rig.provider, 2, 2, no_cancel, "G-after-cancel");
        ExpectFrame(*rig.provider, 3, 3, no_cancel, "G-after-cancel");
        delete rig.decoder;
    }

    // ---- H. 显式 Seek + Acquire 契约：不双重 seek；同目标重复消费会重新 seek ----
    std::printf("\n[H] 显式 Seek + AcquireFrame 契约用法\n");
    {
        Rig rig = MakeRig();
        if (rig.provider == nullptr) return 1;
        cq::MediaFrame f{};
        cq::Status s0 = rig.provider->Seek(cq::RationalTime{6, kTs},
                                           cq::SeekPolicy::kExact, no_cancel);
        Check(s0.IsOk(), "显式 Seek(6) 成功");
        cq::Status s1 = Acquire(*rig.provider, 6, cq::SeekPolicy::kExact, no_cancel, f);
        Check(s1.IsOk() && f.video.pts.value == 6, "显式 Seek 后 Acquire 返回帧 6");
        Check(rig.demuxer->seek_calls() == 1 && rig.decoder->flush_calls() == 2,
              "显式 Seek 后 Acquire 不重复内部 seek/flush（flush=Open+显式 Seek）");
        // 同目标第二次 Acquire：目标已被消费 → 必须重新 seek 重解（返回同帧）。
        cq::Status s2 = Acquire(*rig.provider, 6, cq::SeekPolicy::kExact, no_cancel, f);
        Check(s2.IsOk() && f.video.pts.value == 6, "同目标重复 Acquire 仍返回帧 6");
        Check(rig.demuxer->seek_calls() == 2, "同目标重复 Acquire 重新 seek（旧实现错帧）");
        delete rig.decoder;
    }

    std::printf("\n== 结果：%d 项检查，%d 项失败（学习期 seek 计=%d）==\n", g_checks,
                g_failures, seeks_after_learn);
    return g_failures == 0 ? 0 : 1;
}
