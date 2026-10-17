// ChuanqiCut — ChqPreviewAudioMixer 单测（AUDIO-002）
//
// 验收面（全 core，无平台依赖：引擎/读取器/快照均为确定性假实现）：
//   1. 块网格连续性：写入引擎的块 pts 从重锚点起严格 +block_ticks 递进。
//   2. 时间线命中与混音：单 clip 幅度、轨间求和、削波、静音轨、clip 间隙静音。
//   3. 源时间映射：source_in 偏移（timeline t ↔ source t-start+source_in）。
//   4. EOF 诚实降级：素材音频短于片段 → 余下时长静音（不崩溃、不伪造）。
//   5. 暂停/恢复：暂停 Flush 且停写；恢复后从新播放头重锚。
//   6. 统计量可观测（blocks_rendered / flush 计数）。
//
// 时序说明：混音线程按真实墙钟节拍运行（feed_hz=200），断言只覆盖「窗口必然
// 已到达」的时间段并留足余量；块 pts 的连续性断言是精确的（不依赖时序）。

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "cq/audio/chq_preview_mixer.h"
#include "cq/audio/chq_track_reader.h"
#include "cq/base/chq_rational_time.h"
#include "cq/model/chq_model_snapshot.h"
#include "cq/platform/chq_audio.h"

using namespace cq;  // NOLINT（测试文件，直用内核命名空间）

namespace {

int g_failures = 0;

#define CHECK(cond, msg)                                              \
    do {                                                              \
        if (!(cond)) {                                                \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, \
                         msg);                                          \
            ++g_failures;                                               \
        }                                                               \
    } while (0)

constexpr int32_t kTs = kProjectTimeScale;  // 120000
constexpr int64_t kRate = 48000;
constexpr int64_t kBlockFrames = 4800;      // 100ms @ 48k → 12000 ticks（整）
constexpr int64_t kBlockTicks = kBlockFrames * kTs / kRate;

// ---------------------------------------------------------------------------
// 假读取器：按路径配置幅度函数与素材总长；Seek 幂等；EOF 后 kIoNotFound。
// 幅度 = amp_fn(源 tick)（默认常数；映射测试用分段函数）。
// ---------------------------------------------------------------------------
class FakeReader final : public ChqIAudioTrackReader {
public:
    void Destroy() override { delete this; }
    ChqStatus Open(const ChqMediaSource& src) override {
        (void)src;
        return ChqStatus::Ok();
    }
    bool HasAudio() const override { return has_audio_; }
    ChqStatus GetDuration(ChqRationalTime& out) const override {
        out = ChqRationalTime{total_ticks_, kTs};
        return ChqStatus::Ok();
    }
    ChqStatus Seek(const ChqRationalTime& src_time, const ChqCancelToken& token) override {
        (void)token;
        pos_ticks_ = src_time.value;
        eof_ = false;
        ++seek_count_;
        return ChqStatus::Ok();
    }
    ChqStatus ReadBlock(ChqPcmBuffer& out, const ChqCancelToken& token) override {
        if (token.IsCancelled()) return token.Cancelled();
        if (eof_ || pos_ticks_ >= total_ticks_) {
            eof_ = true;
            return ChqStatus{ChqStatusCode::kIoNotFound};
        }
        const uint64_t frames = frames_per_block_;
        const float amp = amp_fn_(pos_ticks_);
        for (uint64_t i = 0; i < frames; ++i) {
            scratch_[i * 2] = amp;
            scratch_[i * 2 + 1] = amp;
        }
        out.format = ChqSampleFormat::kFloat32;
        out.channels = 2;
        out.sample_rate = static_cast<uint32_t>(kRate);
        out.frame_count = frames;
        out.data = scratch_.data();
        out.data_bytes = frames * 2 * sizeof(float);
        out.pts = ChqRationalTime{pos_ticks_, kTs};
        pos_ticks_ += static_cast<int64_t>(frames) * kTs / kRate;
        return ChqStatus::Ok();
    }

    bool has_audio_ = true;
    int64_t total_ticks_ = 10 * kTs;
    int64_t pos_ticks_ = 0;
    uint64_t frames_per_block_ = static_cast<uint64_t>(kBlockFrames);
    int seek_count_ = 0;
    std::function<float(int64_t)> amp_fn_ = [](int64_t) { return 0.25f; };
    std::vector<float> scratch_ = std::vector<float>(kBlockFrames * 2, 0.0f);

private:
    bool eof_ = false;
};

// ---------------------------------------------------------------------------
// 假读取器工厂：按路径配置（"fake://<amp>|<seconds>" 协议，够用且自明）。
// ---------------------------------------------------------------------------
class FakeReaderFactory final : public ChqIAudioTrackReaderFactory {
public:
    struct Cfg {
        float amp = 0.25f;
        int64_t total_ticks = 10 * kTs;
        bool has_audio = true;
    };
    ChqStatus Create(const ChqMediaSource& src, const ChqAudioGraphSpec& spec,
                  ChqAudioReaderPtr& out) override {
        const std::string path(src.path, src.path_len);
        // 路径协议：fake://a 即查 configs_["a"]；无配置 = 默认。
        const std::string key = path.substr(std::min<size_t>(7, path.size()));
        const Cfg cfg = configs_.count(key) ? configs_[key] : Cfg{};
        auto* r = new FakeReader();
        r->has_audio_ = cfg.has_audio;
        r->total_ticks_ = cfg.total_ticks;
        const float amp = cfg.amp;
        r->amp_fn_ = [amp](int64_t) { return amp; };
        if (amp_fn_) r->amp_fn_ = amp_fn_;  // 全局覆盖（映射测试）
        created_paths_.push_back(key);
        out = ChqAudioReaderPtr(static_cast<ChqIAudioTrackReader*>(r));
        (void)spec;
        return ChqStatus::Ok();
    }
    std::map<std::string, Cfg> configs_;
    std::function<float(int64_t)> amp_fn_;
    std::vector<std::string> created_paths_;
};

// ---------------------------------------------------------------------------
// 假引擎：记录写入块（pts + 峰值幅度），按真实时间流逝消费（1:1 实时），
// FlushOutput 清账（与真引擎 Flush 语义一致：缓冲即空）。
// ---------------------------------------------------------------------------
class FakeEngine final : public ChqIAudioEngine {
public:
    void Destroy() override { delete this; }
    ChqStatus OpenOutput(uint32_t sample_rate, uint32_t channels, ChqSampleFormat fmt,
                      uint32_t frames_per_buffer) override {
        (void)channels;
        (void)frames_per_buffer;
        rate_ = sample_rate;
        fmt_ok_ = (fmt == ChqSampleFormat::kFloat32);
        return ChqStatus::Ok();
    }
    ChqStatus Write(const ChqPcmBuffer& buf) override {
        std::lock_guard<std::mutex> lock(mu_);
        const auto* s = static_cast<const float*>(buf.data);
        float peak = 0.0f;
        for (uint64_t i = 0; i < buf.frame_count * buf.channels; ++i) {
            peak = std::max(peak, std::fabs(s[i]));
        }
        written_.push_back(Written{buf.pts.value, buf.frame_count, peak});
        if (total_frames_ == 0) anchor_ = std::chrono::steady_clock::now();
        total_frames_ += buf.frame_count;
        return ChqStatus::Ok();
    }
    ChqStatus FlushOutput() override {
        std::lock_guard<std::mutex> lock(mu_);
        ++flush_count_;
        total_frames_ = 0;  // 缓冲清空（真引擎 Flush 语义）
        return ChqStatus::Ok();
    }
    uint64_t BufferedFrames() const override {
        std::lock_guard<std::mutex> lock(mu_);
        if (total_frames_ == 0 || !fmt_ok_) return 0;
        const auto elapsed_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                    std::chrono::steady_clock::now() - anchor_)
                                    .count();
        const uint64_t consumed =
            static_cast<uint64_t>(elapsed_ns) * rate_ / 1'000'000'000ULL;
        return consumed >= total_frames_ ? 0 : total_frames_ - consumed;
    }
    ChqStatus OpenInput(uint32_t, uint32_t, ChqSampleFormat, uint32_t) override {
        return ChqStatus{ChqStatusCode::kDecodeUnsupported};
    }
    ChqStatus Read(ChqPcmBuffer&, const ChqCancelToken&) override {
        return ChqStatus{ChqStatusCode::kDecodeUnsupported};
    }
    ChqStatus Start() override {
        ++start_count_;
        return ChqStatus::Ok();
    }
    ChqStatus Stop() override {
        ++stop_count_;
        return ChqStatus::Ok();
    }

    struct Written {
        int64_t pts;
        uint64_t frames;
        float peak;
    };
    std::vector<Written> ChqSnapshot() const {
        std::lock_guard<std::mutex> lock(mu_);
        return written_;
    }
    int FlushCount() const {
        std::lock_guard<std::mutex> lock(mu_);
        return flush_count_;
    }
    size_t WrittenCount() const {
        std::lock_guard<std::mutex> lock(mu_);
        return written_.size();
    }

    mutable std::mutex mu_;
    std::vector<Written> written_;
    int flush_count_ = 0;
    uint64_t total_frames_ = 0;
    uint32_t rate_ = 48000;
    bool fmt_ok_ = true;
    int start_count_ = 0;
    int stop_count_ = 0;
    std::chrono::steady_clock::time_point anchor_{};
};

// ---------------------------------------------------------------------------
// 假快照源 + 装配助手
// ---------------------------------------------------------------------------
class FakeSnapshots final : public ChqIModelSnapshotProvider {
public:
    std::shared_ptr<const ChqModelSnapshot> CurrentSnapshot() const override {
        return snap_;
    }
    std::shared_ptr<ChqModelSnapshot> snap_;
};

// 轨道类型：预览音频把视频轨片段的内嵌音频同样计入（与真混音器一致）。
struct ClipSpec {
    uint64_t asset_id;
    int64_t start_ms;
    int64_t dur_ms;
    int64_t source_in_ms;
};

std::shared_ptr<ChqModelSnapshot> MakeSnapshot(
    const std::vector<std::pair<ChqTrackKind, std::vector<ClipSpec>>>& tracks,
    const std::map<uint64_t, std::string>& assets) {
    auto timeline = std::make_shared<ChqTimeline>();
    for (const auto& [kind, clips] : tracks) {
        uint64_t track_id = 0;
        CHECK(timeline->AddTrack(kind, track_id).IsOk(), "AddTrack");
        // ChqClipKind 必须与 ChqTrackKind 匹配（InsertClip 类型校验）。
        const ChqClipKind clip_kind =
            (kind == ChqTrackKind::kAudio) ? ChqClipKind::kAudio : ChqClipKind::kVideo;
        for (const ClipSpec& cs : clips) {
            ChqClip c;
            c.kind = clip_kind;
            c.source.asset_id = cs.asset_id;
            c.source.source_in = ChqRationalTime{cs.source_in_ms * kTs / 1000, kTs};
            c.source.source_duration = ChqRationalTime{cs.dur_ms * kTs / 1000, kTs};
            c.start = ChqRationalTime{cs.start_ms * kTs / 1000, kTs};
            c.duration = ChqRationalTime{cs.dur_ms * kTs / 1000, kTs};
            uint64_t clip_id = 0;
            CHECK(timeline->InsertClip(track_id, c, clip_id).IsOk(), "InsertClip");
        }
    }
    auto registry = std::make_shared<ChqAssetRegistry>();
    for (const auto& [id, path] : assets) {
        CHECK(registry->Register(id, path).IsOk(), "Register");
    }
    auto snap = std::make_shared<ChqModelSnapshot>();
    snap->timeline = timeline;
    snap->assets = registry;
    return snap;
}

ChqPreviewAudioMixer::Config TestConfig() {
    ChqPreviewAudioMixer::Config cfg;
    cfg.spec.format = ChqSampleFormat::kFloat32;
    cfg.spec.channels = 2;
    cfg.spec.sample_rate = static_cast<uint32_t>(kRate);
    cfg.spec.frames_per_block = static_cast<uint32_t>(kBlockFrames);
    cfg.feed_hz = 200;
    cfg.lookahead_ms = 100;
    cfg.resync_threshold_ms = 80;
    return cfg;
}

// 最近一次 Sync 的播放头（测试辅助：保持墙钟外推不把窗口拉飞）。
void SyncAt(ChqPreviewAudioMixer& m, int64_t ms, bool playing) {
    m.Sync(ChqRationalTime{ms * kTs / 1000, kTs}, playing);
}

}  // namespace

int main() {
    // ---- 用例 1：单 clip 块网格连续 + 幅度正确 ----
    {
        FakeReaderFactory readers;
        readers.configs_["a"] = {0.25f, 10 * kTs, true};
        FakeEngine engine;
        FakeSnapshots snaps;
        snaps.snap_ = MakeSnapshot({{ChqTrackKind::kAudio,
                                     {{1, 0, 5000, 0}}}},
                                   {{1, "fake://a"}});
        ChqPreviewAudioMixer mixer(&readers, &snaps, &engine, TestConfig());
        CHECK(mixer.Start().IsOk(), "Start");
        SyncAt(mixer, 0, true);
        std::this_thread::sleep_for(std::chrono::milliseconds(600));
        SyncAt(mixer, 600, false);  // 停写，冻结窗口
        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        const auto blocks = engine.ChqSnapshot();
        CHECK(blocks.size() >= 5, "case1: 至少 5 块（0.6s 窗口 / 0.1s 块）");
        if (!blocks.empty()) {
            CHECK(blocks[0].pts == 0, "case1: 首块 pts=0（重锚点）");
            for (size_t i = 1; i < blocks.size(); ++i) {
                CHECK(blocks[i].pts - blocks[i - 1].pts == kBlockTicks,
                      "case1: 块 pts 严格连续（+12000）");
            }
            for (const auto& b : blocks) {
                CHECK(b.frames == static_cast<uint64_t>(kBlockFrames),
                      "case1: 块帧数恒定");
                if (b.pts < 5000 * kTs / 1000) {
                    CHECK(std::fabs(b.peak - 0.25f) < 1e-4f, "case1: 幅度 0.25");
                }
            }
        }
        const auto st = mixer.GetStats();
        CHECK(st.blocks_rendered >= blocks.size(), "case1: stats≥实际写入");
        mixer.Stop();
        CHECK(engine.stop_count_ >= 1, "case1: Stop 引擎");
    }

    // ---- 用例 2：clip 间隙静音（[0,0.3s) 0.25 → 间隙 0 → [0.5s,1.2s) 0.5）----
    {
        FakeReaderFactory readers;
        readers.configs_["a"] = {0.25f, 10 * kTs, true};
        readers.configs_["b"] = {0.5f, 10 * kTs, true};
        FakeEngine engine;
        FakeSnapshots snaps;
        snaps.snap_ = MakeSnapshot({{ChqTrackKind::kAudio,
                                     {{1, 0, 300, 0}, {2, 500, 700, 0}}}},
                                   {{1, "fake://a"}, {2, "fake://b"}});
        ChqPreviewAudioMixer mixer(&readers, &snaps, &engine, TestConfig());
        CHECK(mixer.Start().IsOk(), "Start");
        SyncAt(mixer, 0, true);
        std::this_thread::sleep_for(std::chrono::milliseconds(900));
        SyncAt(mixer, 900, false);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        const auto blocks = engine.ChqSnapshot();
        int checked_25 = 0, checked_gap = 0, checked_50 = 0;
        for (const auto& b : blocks) {
            const int64_t ms = b.pts * 1000 / kTs;
            if (ms + 100 <= 300) {  // 块完全落在 [0,0.3s)
                CHECK(std::fabs(b.peak - 0.25f) < 1e-4f, "case2: [0,0.3s) 幅度 0.25");
                ++checked_25;
            } else if (ms >= 300 && ms + 100 <= 500) {  // 完全落在间隙
                CHECK(b.peak < 1e-5f, "case2: 间隙静音");
                ++checked_gap;
            } else if (ms >= 500 && ms + 100 <= 1200) {  // 完全落在第二 clip
                CHECK(std::fabs(b.peak - 0.5f) < 1e-4f, "case2: [0.5s,) 幅度 0.5");
                ++checked_50;
            }
        }
        CHECK(checked_25 >= 2, "case2: 覆盖第一段");
        CHECK(checked_gap >= 1, "case2: 覆盖间隙");
        CHECK(checked_50 >= 4, "case2: 覆盖第二段");
        mixer.Stop();
    }

    // ---- 用例 3：轨间求和 + 削波（0.9 + 0.9 → 1.0）----
    {
        FakeReaderFactory readers;
        readers.configs_["a"] = {0.9f, 10 * kTs, true};
        FakeEngine engine;
        FakeSnapshots snaps;
        snaps.snap_ = MakeSnapshot({{ChqTrackKind::kAudio, {{1, 0, 1000, 0}}},
                                    {ChqTrackKind::kAudio, {{1, 0, 1000, 0}}}},
                                   {{1, "fake://a"}});
        ChqPreviewAudioMixer mixer(&readers, &snaps, &engine, TestConfig());
        CHECK(mixer.Start().IsOk(), "Start");
        SyncAt(mixer, 0, true);
        std::this_thread::sleep_for(std::chrono::milliseconds(400));
        SyncAt(mixer, 400, false);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        const auto blocks = engine.ChqSnapshot();
        CHECK(blocks.size() >= 3, "case3: 有块");
        for (const auto& b : blocks) {
            CHECK(std::fabs(b.peak - 1.0f) < 1e-4f, "case3: 求和削波到 1.0");
        }
        mixer.Stop();
    }

    // ---- 用例 4：muted 轨不计入（0.25 + muted 0.25 → 0.25）----
    {
        FakeReaderFactory readers;
        readers.configs_["a"] = {0.25f, 10 * kTs, true};
        FakeEngine engine;
        FakeSnapshots snaps;
        snaps.snap_ = MakeSnapshot({{ChqTrackKind::kAudio, {{1, 0, 1000, 0}}}},
                                   {{1, "fake://a"}});
        // muted 轨经 ChqTimeline 公开恢复面（RestoreTrack，实体自带 id/muted）注入。
        {
            ChqTrack muted;
            muted.id = 99;
            muted.kind = ChqTrackKind::kAudio;
            muted.muted = true;
            ChqClip c;
            c.id = 9901;  // Restore 契约：实体自带 id 且非零（timeline.cpp:210）
            c.kind = ChqClipKind::kAudio;  // 与轨类型匹配（RestoreTrack 校验）
            c.source.asset_id = 1;
            c.source.source_in = ChqRationalTime{0, kTs};
            c.source.source_duration = ChqRationalTime{1000 * kTs / 1000, kTs};
            c.start = ChqRationalTime{0, kTs};
            c.duration = ChqRationalTime{1000 * kTs / 1000, kTs};
            muted.clips.push_back(c);
            auto timeline = std::const_pointer_cast<ChqTimeline>(snaps.snap_->timeline);
            CHECK(timeline->RestoreTrack(muted).IsOk(), "case4: RestoreTrack(muted)");
        }
        ChqPreviewAudioMixer mixer(&readers, &snaps, &engine, TestConfig());
        CHECK(mixer.Start().IsOk(), "Start");
        SyncAt(mixer, 0, true);
        std::this_thread::sleep_for(std::chrono::milliseconds(400));
        SyncAt(mixer, 400, false);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        const auto blocks = engine.ChqSnapshot();
        CHECK(blocks.size() >= 3, "case4: 有块");
        for (const auto& b : blocks) {
            CHECK(std::fabs(b.peak - 0.25f) < 1e-4f, "case4: muted 轨不计入（0.25）");
        }
        mixer.Stop();
    }

    // ---- 用例 5：EOF 诚实静音（素材 0.4s < 片段 1.5s）----
    {
        FakeReaderFactory readers;
        readers.configs_["short"] = {0.5f, 400 * kTs / 1000, true};
        FakeEngine engine;
        FakeSnapshots snaps;
        snaps.snap_ = MakeSnapshot({{ChqTrackKind::kAudio, {{1, 0, 1500, 0}}}},
                                   {{1, "fake://short"}});
        ChqPreviewAudioMixer mixer(&readers, &snaps, &engine, TestConfig());
        CHECK(mixer.Start().IsOk(), "Start");
        SyncAt(mixer, 0, true);
        std::this_thread::sleep_for(std::chrono::milliseconds(900));
        SyncAt(mixer, 900, false);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        const auto blocks = engine.ChqSnapshot();
        for (const auto& b : blocks) {
            const int64_t ms = b.pts * 1000 / kTs;
            if (ms + 100 <= 400) {
                CHECK(std::fabs(b.peak - 0.5f) < 1e-4f, "case5: EOF 前正常幅度");
            } else if (ms >= 400) {
                CHECK(b.peak < 1e-5f, "case5: EOF 后静音（不伪造）");
            }
        }
        mixer.Stop();
    }

    // ---- 用例 6：source_in 映射（timeline 0 ↔ source 2s；幅度按源秒阶梯）----
    {
        FakeReaderFactory readers;
        readers.configs_["ladder"] = {0.0f, 10 * kTs, true};
        readers.amp_fn_ = [](int64_t src_tick) {
            const int64_t sec = src_tick / kTs;
            return 0.1f + 0.1f * static_cast<float>(sec % 10);
        };
        FakeEngine engine;
        FakeSnapshots snaps;
        snaps.snap_ = MakeSnapshot({{ChqTrackKind::kAudio, {{1, 0, 2000, 2000}}}},
                                   {{1, "fake://ladder"}});
        ChqPreviewAudioMixer mixer(&readers, &snaps, &engine, TestConfig());
        CHECK(mixer.Start().IsOk(), "Start");
        SyncAt(mixer, 0, true);
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        SyncAt(mixer, 500, false);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        const auto blocks = engine.ChqSnapshot();
        for (const auto& b : blocks) {
            const int64_t timeline_ms = b.pts * 1000 / kTs;
            const int64_t src_ms = timeline_ms + 2000;  // source_in = 2s
            const float expect = 0.1f + 0.1f * static_cast<float>((src_ms / 1000) % 10);
            CHECK(std::fabs(b.peak - expect) < 1e-4f, "case6: source_in 映射正确");
        }
        mixer.Stop();
    }

    // ---- 用例 7：暂停 Flush + 恢复重锚（新播放头起混）----
    {
        FakeReaderFactory readers;
        readers.configs_["a"] = {0.25f, 10 * kTs, true};
        FakeEngine engine;
        FakeSnapshots snaps;
        snaps.snap_ = MakeSnapshot({{ChqTrackKind::kAudio, {{1, 0, 20000, 0}}}},
                                   {{1, "fake://a"}});
        ChqPreviewAudioMixer mixer(&readers, &snaps, &engine, TestConfig());
        CHECK(mixer.Start().IsOk(), "Start");
        SyncAt(mixer, 0, true);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        SyncAt(mixer, 300, false);
        CHECK(engine.FlushCount() >= 1, "case7: 暂停触发 Flush");
        const size_t frozen = engine.WrittenCount();
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        // 暂停期间不写入（设计上界：Sync 与在飞窗口的竞态 ≤ 1 块，
        // 且该尾巴由混音器暂停分支的补 Flush 清掉，不可闻）。
        CHECK(engine.WrittenCount() <= frozen + 1, "case7: 暂停期间不写入（≤1 块竞态尾巴）");

        // 恢复：拖拽到 5s 再播 → 首块 pts == 5s。
        SyncAt(mixer, 5000, true);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        SyncAt(mixer, 5300, false);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        const auto blocks = engine.ChqSnapshot();
        // 找到恢复后首块（pts ≥ 5s）。
        bool found_reanchor = false;
        for (const auto& b : blocks) {
            if (b.pts == 5000 * kTs / 1000) {
                found_reanchor = true;
                break;
            }
        }
        CHECK(found_reanchor, "case7: 恢复后从新播放头重锚（5s 块存在）");
        mixer.Stop();
    }

    if (g_failures == 0) {
        std::printf("test_preview_mixer: all checks passed\n");
        return 0;
    }
    std::printf("test_preview_mixer: %d failures\n", g_failures);
    return 1;
}
