// ChuanqiCut — MEDIA-012 DecoderPool 单测（跨平台，无平台后端）
//
// 验收（实测证据）：
//   1. 超路数请求不崩溃、返回可预期 Status（kResourceExhausted，非 crash、非挂起）。
//   2. 释放后能重新 Acquire（池确实复用，复用同一 handle）。
//   3. ActiveCount() / MaxHardwarePaths() 返回值符合预期；SetMaxHardwarePaths 可覆盖。
//   4. 并发借/还无挂起（10s 超时上界，CORE-005 教训）。
//   5. 接入 SystemFrameProvider：Open 从池借路解码；池满时 Open 如实返回 kResourceExhausted。
//
// 无缓冲输出：崩溃/挂起时仍能看到进度。

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <future>
#include <memory>
#include <set>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/rational_time.h"
#include "cq/media/decoder_pool.h"
#include "cq/media/system_frame_provider.h"
#include "cq/pal/pal_common.h"
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

constexpr int32_t kTs = 4;

// ---- Mock 解码器（供 provider 集成解码用）----
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
            if (s.dts == pkt.dts.value) { pending_.push_back(P{s.pts, s.release}); break; }
        }
        return cq::Status::Ok();
    }
    cq::Status PopFrame(cq::MediaFrame& out) override {
        size_t best_i = pending_.size(); int64_t best_pts = 0; bool found = false;
        for (size_t i = 0; i < pending_.size(); ++i) {
            const P& fp = pending_[static_cast<size_t>(i)];
            if (fp.release > last_fed_dts_) continue;  // 参考帧未齐备
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
    void Flush() override { pending_.clear(); last_fed_dts_ = -1; }
private:
    struct P { int64_t pts, release; };
    std::vector<Spec> specs_;
    std::vector<P> pending_;
    std::set<int64_t> all_pts_;
    int64_t last_fed_dts_ = -1;
};

// ---- Mock 解码器工厂（创建 CqDecoder 包装一个 MockDecoder）----
class MockDecoderFactory : public cq::IDecoderFactory {
public:
    MockDecoderFactory()
        : dec_(std::vector<MockDecoder::Spec>{
              {0, 0, 0}, {1, 3, 1}, {2, 1, 1}, {3, 2, 1}}) {}
    cq::Status Create(cq::CodecId, cq::DecoderHandle& out) override {
        auto* d = new cq::CqDecoder();
        d->decoder = &dec_;
        d->id = ++id_;
        out = d;
        return cq::Status::Ok();
    }
    void Destroy(cq::DecoderHandle d) override { delete d; }
    MockDecoder dec_;          // 池内所有 CqDecoder 共享此 MockDecoder（仅测试用）
    int id_ = 0;
};

// ---- Mock demuxer（供 provider 集成用）----
class MockDemuxer : public cq::IMediaDemuxer {
public:
    struct GP { int64_t dts, pts; bool kf; };
    explicit MockDemuxer(std::vector<GP> gop) : gop_(std::move(gop)) {}
    void Destroy() override { delete this; }
    cq::Status Open(const cq::MediaSource&) override { idx_ = 0; return cq::Status::Ok(); }
    cq::Status GetDuration(cq::RationalTime& d) const override {
        d = cq::RationalTime{static_cast<int64_t>(gop_.size()), kTs}; return cq::Status::Ok();
    }
    int32_t GetStreamCount() const override { return 1; }
    cq::Status GetStreamInfo(int32_t, cq::StreamInfo& o) const override {
        o = cq::StreamInfo{}; o.type = cq::MediaType::kVideo; o.codec = cq::CodecId::kH264;
        o.width = 64; o.height = 36; o.time_base = cq::RationalTime{1, kTs}; return cq::Status::Ok();
    }
    cq::Status Seek(const cq::RationalTime&, const cq::CancelToken&) override { idx_ = 0; return cq::Status::Ok(); }
    cq::Status ReadPacket(cq::MediaPacket& out) override {
        out = cq::MediaPacket{};
        if (idx_ >= gop_.size()) return cq::Status{cq::StatusCode::kIoNotFound};
        const GP& g = gop_[static_cast<size_t>(idx_++)];
        out.pts = cq::RationalTime{g.pts, kTs}; out.dts = cq::RationalTime{g.dts, kTs};
        out.codec = cq::CodecId::kH264; out.is_keyframe = g.kf; out.data = buf_.data(); out.size = buf_.size();
        return cq::Status::Ok();
    }
private:
    std::vector<GP> gop_;
    size_t idx_ = 0;
    std::vector<uint8_t> buf_ = std::vector<uint8_t>(16, 0xAB);
};

std::vector<MockDemuxer::GP> MakeGop() {
    return {{0,0,true},{1,3,false},{2,1,false},{3,2,false}};
}

// ---------------------------------------------------------------------------
// 1. 超路数不崩溃 + 返回可预期 Status + 复用 + 计数
// ---------------------------------------------------------------------------
void TestOverLimitAndReuse() {
    std::printf("\n[1] 超路数降级：不崩溃、返回 kResourceExhausted、释放后复用\n");
    auto factory = std::make_unique<MockDecoderFactory>();
    cq::DecoderPool pool(1, std::move(factory));
    Check(pool.MaxHardwarePaths() == 1, "默认 MaxHardwarePaths == 1");
    Check(pool.ActiveCount() == 0, "初始 ActiveCount == 0");

    cq::DecoderHandle h1 = nullptr;
    cq::Status s1 = pool.AcquireDecoder(cq::CodecId::kH264, h1);
    Check(s1.IsOk() && h1 != nullptr, "第一路借到（Ok，handle 非空）");
    Check(pool.ActiveCount() == 1, "借出 1 路后 ActiveCount == 1");

    // 第二路：满且无空闲 → kResourceExhausted（不崩溃、不挂起）
    cq::DecoderHandle h2 = nullptr;
    cq::Status s2 = pool.AcquireDecoder(cq::CodecId::kH264, h2);
    Check(s2.code == cq::StatusCode::kResourceExhausted,
          "第二路超上限返回 kResourceExhausted（非 crash / 非挂起）");
    Check(h2 == nullptr, "超上限 out_decoder == nullptr");
    Check(pool.ActiveCount() == 1, "超上限时 ActiveCount 仍为 1（未偷偷多开）");

    // 释放后复用（池生效：同一个 handle 被复用）
    pool.ReleaseDecoder(h1);
    Check(pool.ActiveCount() == 0, "释放后 ActiveCount == 0");
    cq::DecoderHandle h3 = nullptr;
    cq::Status s3 = pool.AcquireDecoder(cq::CodecId::kH264, h3);
    Check(s3.IsOk() && h3 == h1, "释放后重新 Acquire 复用同一 handle（池化生效）");

    // SetMaxHardwarePaths 覆盖
    pool.SetMaxHardwarePaths(3);
    Check(pool.MaxHardwarePaths() == 3, "SetMaxHardwarePaths 覆盖为 3");
    // 现在可借到 2 路（共 3）
    cq::DecoderHandle h4 = nullptr, h5 = nullptr;
    cq::Status s4 = pool.AcquireDecoder(cq::CodecId::kH264, h4);
    cq::Status s5 = pool.AcquireDecoder(cq::CodecId::kH264, h5);
    Check(s4.IsOk() && s5.IsOk(), "上界放宽到 3 后可借到 2 路");
    Check(pool.ActiveCount() == 3, "ActiveCount == 3");
    // 第 4 路再次超上限
    cq::DecoderHandle h6 = nullptr;
    cq::Status s6 = pool.AcquireDecoder(cq::CodecId::kH264, h6);
    Check(s6.code == cq::StatusCode::kResourceExhausted, "第 4 路再次超上限返回 kResourceExhausted");
    pool.ReleaseDecoder(h3); pool.ReleaseDecoder(h4); pool.ReleaseDecoder(h5);
}

// ---------------------------------------------------------------------------
// 2. 并发借/还不挂起（超时上界）
// ---------------------------------------------------------------------------
void TestConcurrentNoHang() {
    std::printf("\n[2] 并发借/还无挂起（8 线程 x 500 次，10s 超时）\n");
    constexpr int32_t kMax = 2;
    auto factory = std::make_unique<MockDecoderFactory>();
    cq::DecoderPool pool(kMax, std::move(factory));

    auto worker = [&]() {
        for (int i = 0; i < 500; ++i) {
            cq::DecoderHandle h = nullptr;
            cq::Status s = pool.AcquireDecoder(cq::CodecId::kH264, h);
            if (s.IsOk()) pool.ReleaseDecoder(h);  // 立即归还
        }
    };

    std::vector<std::future<void>> futures;
    for (int t = 0; t < 8; ++t) {
        futures.push_back(std::async(std::launch::async, worker));
    }
    bool all_done = true;
    for (auto& f : futures) {
        // 非阻塞等待：若 10s 内未完成说明有挂起（不应发生）
        if (f.wait_for(std::chrono::seconds(10)) != std::future_status::ready) {
            all_done = false;
        }
    }
    Check(all_done, "8 线程并发 4000 次借/还全部在 10s 内完成（无挂起）");
    Check(pool.ActiveCount() <= kMax, "并发结束后 ActiveCount <= 上限(2)");
    Check(pool.MaxHardwarePaths() == kMax, "MaxHardwarePaths == 2");
}

// ---------------------------------------------------------------------------
// 3. 接入 SystemFrameProvider
// ---------------------------------------------------------------------------
void TestProviderIntegration() {
    std::printf("\n[3] 接入 SystemFrameProvider：从池借路解码；池满 Open 返回 kResourceExhausted\n");
    auto factory = std::make_unique<MockDecoderFactory>();
    cq::DecoderPool pool(1, std::move(factory));  // 上限 1 路

    // provider1：Open 从池借 1 路并解码
    auto demuxer1 = std::make_unique<MockDemuxer>(MakeGop());
    auto provider1 = cq::CreateSystemFrameProvider(
        cq::PalPtr<cq::IMediaDemuxer>(demuxer1.release()), nullptr);
    provider1->SetDecoderPool(&pool);
    cq::MediaSource src{};
    cq::Status so1 = provider1->Open(src);
    Check(so1.IsOk(), "provider1 Open 从池借到 1 路并成功");
    Check(pool.ActiveCount() == 1, "provider1 持有期间 ActiveCount == 1");

    cq::CancelToken no_cancel;
    cq::FrameRequest req; req.at = cq::RationalTime{0, kTs}; req.policy = cq::SeekPolicy::kExact;
    cq::MediaFrame f{};
    cq::Status sa = provider1->AcquireFrame(req, f, no_cancel);
    Check(sa.IsOk() && f.video.pts.value == 0, "provider1 经池解码得到 pts=0");
    provider1->ReleaseFrame(f);

    // provider2：池已满 → Open 如实返回 kResourceExhausted（不崩溃）
    auto demuxer2 = std::make_unique<MockDemuxer>(MakeGop());
    auto provider2 = cq::CreateSystemFrameProvider(
        cq::PalPtr<cq::IMediaDemuxer>(demuxer2.release()), nullptr);
    provider2->SetDecoderPool(&pool);
    cq::Status so2 = provider2->Open(src);
    Check(so2.code == cq::StatusCode::kResourceExhausted,
          "provider2 Open 池满 → kResourceExhausted（解码能力降级，非崩溃）");
    Check(so2.IsError(), "kResourceExhausted 是错误（调用方据此背压）");

    // provider1 析构归还路数，池恢复空闲
    provider1.reset();
    Check(pool.ActiveCount() == 0, "provider1 析构后释放路数，ActiveCount == 0");
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut MEDIA-012 DecoderPool 单测 ==\n");
    TestOverLimitAndReuse();
    TestConcurrentNoHang();
    TestProviderIntegration();
    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
