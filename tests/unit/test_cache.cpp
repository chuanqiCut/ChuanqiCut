// ChuanqiCut — MEDIA-011 LruFrameCache 单测（跨平台，无平台后端）
//
// 验收（实测证据）：
//   1. 内存上界可控：插入 N 帧（每帧已知大小）超过上界后，UsedBytes() <= 上界。
//   2. LRU 确实淘汰最久未用（访问序列验证命中/未命中）。
//   3. 被 lease 的帧不被淘汰（move-out：借出后物理移出缓存，淘汰循环碰不到）。
//   4. 接入 SystemFrameProvider：AcquireFrame 命中缓存时跳过解码（feed/pop 不增长）。
//
// 无缓冲输出：崩溃/挂起时仍能看到进度。

#include <cstdint>
#include <cstdio>
#include <memory>
#include <set>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/media/cache.h"
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

constexpr int32_t kTs = 4;  // 单测时间网格（与项目 120000 逻辑等价）

cq::MediaFrame MakeVideoFrame(int64_t pts, uint32_t w, uint32_t h,
                              cq::PixelFormat fmt) {
    cq::MediaFrame f{};
    f.type = cq::MediaType::kVideo;
    f.video.pts = cq::RationalTime{pts, kTs};
    f.video.duration = cq::RationalTime{1, kTs};
    f.video.width = w;
    f.video.height = h;
    f.video.pixel_format = fmt;
    return f;
}

// ---------------------------------------------------------------------------
// 1. 内存上界可控
// ---------------------------------------------------------------------------
void TestBound() {
    std::printf("\n[1] 内存上界可控（单帧已知大小，超过上界后 UsedBytes <= 上界）\n");
    // 每帧 RGBA8，w=100 h=1 → 400 字节。上界 1000。
    constexpr int64_t kFrameBytes = 100 * 1 * 4;  // 400
    constexpr int64_t kMax = 1000;
    cq::LruFrameCache cache(kMax);
    Check(cache.MaxBytes() == kMax, "MaxBytes() == 1000");
    Check(cache.UsedBytes() == 0, "初始 UsedBytes == 0");

    for (int i = 0; i < 10; ++i) {
        cache.Insert(cq::RationalTime{static_cast<int64_t>(i), kTs},
                     MakeVideoFrame(i, 100, 1, cq::PixelFormat::kRGBA8));
        if (cache.UsedBytes() > kMax) {
            std::printf("    UsedBytes=%lld 超过上界 %lld（i=%d）\n",
                        static_cast<long long>(cache.UsedBytes()),
                        static_cast<long long>(kMax), i);
        }
        Check(cache.UsedBytes() <= kMax,
              "每次插入后 UsedBytes() <= 上界");
    }
    std::printf("    最终 UsedBytes=%lld（上界 %lld，保留最近 2 帧）\n",
                static_cast<long long>(cache.UsedBytes()),
                static_cast<long long>(kMax));
    Check(cache.UsedBytes() <= kMax, "最终 UsedBytes() <= 上界");
    Check(cache.UsedBytes() == kFrameBytes * 2, "最终保留最近 2 帧 = 800 字节");

    // SetMaxBytes 缩小时立即淘汰
    cache.SetMaxBytes(kFrameBytes);  // 上界降到 1 帧
    Check(cache.UsedBytes() <= kFrameBytes, "SetMaxBytes 缩小后 UsedBytes <= 1 帧");
    Check(cache.Size() == 1, "SetMaxBytes 缩小后仅剩 1 条");
}

// ---------------------------------------------------------------------------
// 2. LRU 淘汰顺序（最久未用先淘汰）
// ---------------------------------------------------------------------------
void TestLruOrder() {
    std::printf("\n[2] LRU 淘汰顺序（最久未用先淘汰）\n");
    constexpr int64_t kMax = 1200;  // 容 3 帧（3*400）
    cq::LruFrameCache cache(kMax);
    // 插入 t0,t1,t2（各 400）→ 1200，恰好不淘汰
    cache.Insert(cq::RationalTime{0, kTs}, MakeVideoFrame(0, 100, 1, cq::PixelFormat::kRGBA8));
    cache.Insert(cq::RationalTime{1, kTs}, MakeVideoFrame(1, 100, 1, cq::PixelFormat::kRGBA8));
    cache.Insert(cq::RationalTime{2, kTs}, MakeVideoFrame(2, 100, 1, cq::PixelFormat::kRGBA8));
    Check(cache.Size() == 3, "插入 3 帧后 Size == 3（未触发淘汰）");

    // 借出 t0（move-out，t0 离开缓存）→ 物理不在 LRU 中
    cq::MediaFrame loaned0{};
    bool hit0 = cache.Find(cq::RationalTime{0, kTs}, loaned0);
    Check(hit0 && loaned0.video.pts.value == 0, "Find(t0) 命中并借出");
    Check(!cache.Contains(cq::RationalTime{0, kTs}), "借出后 t0 不在缓存内");

    // 插入 t3,t4（各 400）。t3: 800+400=1200 不淘汰；t4: 1200+400>1200 淘汰 LRU 尾部
    // （缓存内仅 {t1,t2,t3}，LRU 尾部=t1）→ 淘汰 t1。
    cache.Insert(cq::RationalTime{3, kTs}, MakeVideoFrame(3, 100, 1, cq::PixelFormat::kRGBA8));
    cache.Insert(cq::RationalTime{4, kTs}, MakeVideoFrame(4, 100, 1, cq::PixelFormat::kRGBA8));
    Check(cache.Contains(cq::RationalTime{1, kTs}) == false, "LRU 淘汰了最久未用的 t1");
    Check(cache.Contains(cq::RationalTime{2, kTs}), "t2 仍在缓存");
    Check(cache.Contains(cq::RationalTime{3, kTs}), "t3 仍在缓存");
    Check(cache.Contains(cq::RationalTime{4, kTs}), "t4 仍在缓存");
    Check(cache.UsedBytes() == 1200, "UsedBytes == 1200（t2,t3,t4）");

    // t2 命中返回正确帧
    cq::MediaFrame f2{};
    Check(cache.Find(cq::RationalTime{2, kTs}, f2) && f2.video.pts.value == 2,
          "Find(t2) 命中返回 pts=2");
}

// ---------------------------------------------------------------------------
// 3. 被 lease 的帧不被淘汰（关键）
// ---------------------------------------------------------------------------
void TestLeaseProtection() {
    std::printf("\n[3] 被 lease 的帧不被淘汰（move-out 模型）\n");
    constexpr int64_t kMax = 1000;
    cq::LruFrameCache cache(kMax);
    // 插入 A（t0, width=100 作为哨兵标识），借出
    cq::MediaFrame a = MakeVideoFrame(0, 100, 1, cq::PixelFormat::kRGBA8);
    cache.Insert(cq::RationalTime{0, kTs}, a);
    cq::MediaFrame loaned_a{};
    bool hit = cache.Find(cq::RationalTime{0, kTs}, loaned_a);
    Check(hit && loaned_a.video.pts.value == 0 && loaned_a.video.width == 100,
          "A 借出：pts=0, width=100（哨兵）");
    Check(cache.UsedBytes() == 0, "借出后 UsedBytes == 0（A 已离开缓存）");

    // 疯狂插入 t1..t9（各 400，上界 1000）→ 反复淘汰，但 A 不在缓存内，永不被碰。
    for (int i = 1; i <= 9; ++i) {
        cache.Insert(cq::RationalTime{static_cast<int64_t>(i), kTs},
                     MakeVideoFrame(i, 100, 1, cq::PixelFormat::kRGBA8));
        Check(cache.UsedBytes() <= kMax, "插入过程中 UsedBytes <= 上界");
    }
    // 借出的 A 在调用方手中，内容必须完好（未被任何淘汰破坏）。
    Check(loaned_a.video.pts.value == 0 && loaned_a.video.width == 100,
          "借出的 A 在大量淘汰后仍完好（pts=0, width=100）");
    Check(!cache.Contains(cq::RationalTime{0, kTs}),
          "A 未因淘汰被悄悄改写/重新入缓存（仍属调用方独占）");
}

// ---------------------------------------------------------------------------
// 4. 接入 SystemFrameProvider：缓存命中跳过解码
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
        o.width = 64; o.height = 36;
        o.time_base = cq::RationalTime{1, kTs};
        return cq::Status::Ok();
    }
    cq::Status Seek(const cq::RationalTime&, const cq::CancelToken&) override {
        idx_ = 0; return cq::Status::Ok();
    }
    cq::Status ReadPacket(cq::MediaPacket& out) override {
        out = cq::MediaPacket{};
        if (idx_ >= gop_.size()) return cq::Status{cq::StatusCode::kIoNotFound};
        const GP& g = gop_[static_cast<size_t>(idx_++)];
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

class MockDecoder : public cq::IFrameDecoder {
public:
    struct Spec { int64_t dts, pts, release; };
    explicit MockDecoder(std::vector<Spec> specs) : specs_(std::move(specs)) {
        for (const Spec& s : specs_) all_pts_.insert(s.pts);
    }
    cq::Status Open(const cq::StreamInfo&) override { return cq::Status::Ok(); }
    cq::Status Feed(const cq::MediaPacket& pkt) override {
        ++feed_calls;
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
        ++pop_calls;
        size_t best_i = pending_.size();
        int64_t best_pts = 0;
        bool found = false;
        for (size_t i = 0; i < pending_.size(); ++i) {
            const P& fp = pending_[static_cast<size_t>(i)];
            if (fp.release > last_fed_dts_) continue;
            bool blocked = false;
            for (int64_t y : all_pts_) {
                if (y < fp.pts && fed_pts_.find(y) == fed_pts_.end()) { blocked = true; break; }
            }
            if (blocked) continue;
            if (!found || fp.pts < best_pts) { found = true; best_pts = fp.pts; best_i = i; }
        }
        if (!found) return cq::Status{cq::StatusCode::kIoNotFound};
        out = cq::MediaFrame{};
        out.type = cq::MediaType::kVideo;
        out.video.pts = cq::RationalTime{best_pts, kTs};
        out.video.duration = cq::RationalTime{1, kTs};
        out.video.width = 64; out.video.height = 36;
        out.video.pixel_format = cq::PixelFormat::kYUV420SemiPlanar;
        pending_.erase(pending_.begin() + static_cast<long>(best_i));
        return cq::Status::Ok();
    }
    void Flush() override { pending_.clear(); fed_pts_.clear(); last_fed_dts_ = -1; }

    int64_t feed_calls = 0;
    int64_t pop_calls = 0;
private:
    struct P { int64_t pts, release; };
    std::vector<Spec> specs_;
    std::vector<P> pending_;
    std::set<int64_t> all_pts_;
    std::set<int64_t> fed_pts_;
    int64_t last_fed_dts_ = -1;
};

std::vector<MockDemuxer::GP> MakeGop() {
    return {{0,0,true},{1,3,false},{2,1,false},{3,2,false}};
}
std::vector<MockDecoder::Spec> MakeSpec() {
    return {{0,0,0},{1,3,1},{2,1,1},{3,2,1}};
}

void TestProviderIntegration() {
    std::printf("\n[4] 接入 SystemFrameProvider：缓存命中跳过解码\n");
    auto demuxer = std::make_unique<MockDemuxer>(MakeGop());
    MockDecoder decoder(MakeSpec());
    cq::LruFrameCache cache(1024 * 1024 * 64);  // 大上界，不淘汰
    cq::MediaSource src{};
    auto provider = cq::CreateSystemFrameProvider(
        cq::PalPtr<cq::IMediaDemuxer>(demuxer.release()), &decoder);
    provider->SetFrameCache(&cache);
    cq::Status s = provider->Open(src);
    Check(s.IsOk(), "Open 成功");

    cq::CancelToken no_cancel;
    cq::FrameRequest req;
    req.at = cq::RationalTime{0, kTs};
    req.policy = cq::SeekPolicy::kExact;

    cq::MediaFrame f1{};
    int64_t feed_after_first = 0, pop_after_first = 0;
    s = provider->AcquireFrame(req, f1, no_cancel);
    feed_after_first = decoder.feed_calls;
    pop_after_first = decoder.pop_calls;
    Check(s.IsOk() && f1.video.pts.value == 0, "首次 AcquireFrame(t=0) 解码得到 pts=0");
    Check(feed_after_first > 0 && pop_after_first > 0, "首次解码确有 feed/pop");

    // 归还（交回缓存）
    provider->ReleaseFrame(f1);

    // 第二次请求同一 t=0：应命中缓存，跳过解码
    cq::MediaFrame f2{};
    s = provider->AcquireFrame(req, f2, no_cancel);
    Check(s.IsOk() && f2.video.pts.value == 0, "二次 AcquireFrame(t=0) 命中缓存 pts=0");
    Check(decoder.feed_calls == feed_after_first && decoder.pop_calls == pop_after_first,
          "二次请求未触发解码（feed/pop 计数不变 → 缓存命中）");
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut MEDIA-011 LruFrameCache 单测 ==\n");
    TestBound();
    TestLruOrder();
    TestLeaseProtection();
    TestProviderIntegration();
    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
