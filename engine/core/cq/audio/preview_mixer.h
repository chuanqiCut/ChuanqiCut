// ChuanqiCut — 预览音频混音器（AUDIO-002，MEDIA-030 全量音画同步的前置）
//
// 职责：回答「时间线在 [t0,t1) 这一段该出什么声音」，产 PCM 块写入平台播放引擎。
//   模型快照（Timeline + AssetRegistry）→ 逐轨逐 clip 命中测试 → 每个活动 clip
//   一个 IAudioTrackReader（独立读位）→ 源时间 1:1 映射（恒速，与视频预览同语义，
//   MEDIA-013 TimeMap 落地前如此）→ 交错求和 + 削波 → IAudioEngine::Write。
//
// 时钟语义（MVP，MEDIA-030 前的诚实边界）：
//   * **视频（墙钟 Player）为主时钟，音频为从**：Sync(playhead, playing) 由调用方
//     每帧喂入（60Hz tick）；混音线程在两次 Sync 之间按墙钟外推目标窗口。
//   * 漂移护栏：缓冲前沿 pts 与外推播放头差超过 resync_threshold 时 Flush + 重锚
//     （seek/暂停/拖拽播放头都经此收敛；音频丢、画面不丢，可感知度低且自恢复）。
//   * 欠载（缓冲耗尽）不谎报正常：重新锚定到当前播放头，静音缺口如实发生并计数。
//
// 线程模型（红线 #8 的音频面执行点）：
//   * Sync —— 主线程（60Hz tick）；临界区 = 几次赋值，微秒级。
//   * 混音线程（自有 std::thread，feed_hz 节拍）—— 快照加载、命中测试、读取器 IO、
//     求和、Write。**非实时线程**：允许分配/加锁/阻塞。
//   * 实时音频回调（引擎内部）—— 只触碰引擎内部的 SPSC 环，本类不经手。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常；统计一律原子量。

#ifndef CQ_AUDIO_PREVIEW_MIXER_H_
#define CQ_AUDIO_PREVIEW_MIXER_H_

#include <atomic>
#include <chrono>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "cq/audio/audio_types.h"
#include "cq/audio/track_reader.h"
#include "cq/base/concurrency.h"
#include "cq/base/rational_time.h"
#include "cq/base/status.h"
#include "cq/model/model_snapshot.h"
#include "cq/model/timeline.h"
#include "cq/platform/audio.h"

namespace cq {

class PreviewAudioMixer {
public:
    struct Config {
        AudioGraphSpec spec{};               // 输出块规格（全链恒定）
        uint32_t lookahead_ms = 150;         // 预渲染窗口（引擎缓冲水位目标）
        uint32_t feed_hz = 30;               // 混音线程节拍
        uint32_t resync_threshold_ms = 120;  // 漂移护栏（超阈值即 Flush + 重锚）
    };

    struct Stats {
        uint64_t blocks_rendered = 0;  // 成功 Write 的块数
        uint64_t blocks_dropped = 0;   // 引擎缓冲满被整块丢弃的块数
        uint64_t underruns = 0;        // 缓冲耗尽（可闻静音缺口）次数
        uint64_t resyncs = 0;          // 漂移护栏触发的 Flush+重锚次数
    };

    // 依赖全部为**注入的非拥有指针**，生命周期由装配方持有（本类不 delete、
    // 不持有 shared_ptr）。engine 须已完成 OpenOutput（规格 = cfg.spec）。
    PreviewAudioMixer(IAudioTrackReaderFactory* readers,
                      IModelSnapshotProvider* snapshots,
                      IAudioEngine* engine, const Config& cfg);

    ~PreviewAudioMixer();

    PreviewAudioMixer(const PreviewAudioMixer&) = delete;
    PreviewAudioMixer& operator=(const PreviewAudioMixer&) = delete;

    // 启动混音线程并 Start 引擎。重复 Start 幂等返回 kOk。
    Status Start();
    // 停线程并 Stop 引擎。析构自动调用。
    void Stop();

    // 播放头同步（主线程 tick 调用）。
    //   playing=false（暂停/停止/暂停态拖拽）：立即 Flush 引擎（静音），并登记
    //     重锚点 —— 恢复播放时从新播放头起混。
    //   playing=true：更新播放头与墙钟锚点；播放中的大幅跳变由混音线程的
    //     漂移护栏在下一个周期收敛（≤ 一个 feed 周期）。
    void Sync(const RationalTime& playhead, bool playing);

    Stats GetStats() const;

    // 输出规格（装配方建引擎时要同一份）。
    const AudioGraphSpec& spec() const { return cfg_.spec; }

private:
    // 每个「活动 clip」一份的读取状态。只在混音线程触碰。
    struct ClipEntry {
        uint64_t clip_id = 0;
        uint64_t asset_id = 0;
        std::string path;
        int64_t clip_start_tick = 0;    // 时间线起点（项目网格）
        int64_t source_in_tick = 0;     // 素材内入点（项目网格）
        int64_t clip_end_tick = 0;      // start + duration
        AudioReaderPtr reader;          // 平台读取器（nil = 尚未创建）
        bool has_audio = false;         // 容器无音频流（直通静音）
        bool eof = false;
        bool needs_seek = true;         // 下次消费前须 Seek
        // 未消费样本 FIFO（交错 float32，线程内私有）。fifo_start_tick =
        // 首样本的时间线位置；eof 后不再补充。
        std::vector<float> fifo;
        int64_t fifo_start_tick = 0;
        int warn_count = 0;             // 读取失败的节流日志计数
    };

    void FeedLoop();
    // 渲染 [from, target_end) 的全部整块到引擎。返回推进后的位置（失败即停）。
    int64_t RenderWindow(int64_t from_tick, int64_t target_end_tick,
                         const std::shared_ptr<const ModelSnapshot>& snap);
    // 组装一块 [block_start, block_start + block_ticks)：全部活动 clip 求和进 acc。
    void MixBlock(int64_t block_start_tick,
                  const std::shared_ptr<const ModelSnapshot>& snap);
    // 取（必要时建）clip 的读取状态；快照版本变化时整体重建。
    ClipEntry* EnsureEntry(const std::shared_ptr<const ModelSnapshot>& snap,
                           const Clip& clip);
    // 把 entry 重锚到 timeline_tick：Seek 读取器、清 FIFO（消费位置对不上时用）。
    void AnchorEntry(ClipEntry& e, int64_t timeline_tick);
    // 补足 entry.fifo 覆盖到 timeline until_tick（或 eof）。
    void FillFifo(ClipEntry& e, int64_t until_tick);
    // 快照版本变化 / 重锚后清空全部读取状态。
    void DropEntries();

    // ticks ↔ frames（输出规格网格）。调用方保证入参在 int64 范围内。
    int64_t TicksToFrames(int64_t ticks) const;
    int64_t FramesToTicks(int64_t frames) const;
    int64_t MsToTicks(int64_t ms) const;

    Config cfg_;
    int64_t block_ticks_ = 0;        // frames_per_block * ts / rate（构造期校验为整）
    int64_t lookahead_ticks_ = 0;
    int64_t resync_threshold_ticks_ = 0;

    IAudioTrackReaderFactory* readers_ = nullptr;      // 非拥有
    IModelSnapshotProvider* snapshots_ = nullptr;      // 非拥有
    IAudioEngine* engine_ = nullptr;                   // 非拥有

    // ---- 同步状态（sync_mu_ 保护；主线程写 / 混音线程读）----
    std::mutex sync_mu_;
    RationalTime playhead_{0, 1};        // 最近一次 Sync 的播放头
    bool playing_ = false;
    std::chrono::steady_clock::time_point sync_wall_{};
    int64_t reanchor_to_tick_ = 0;       // 重锚目标（epoch 变化时生效）
    uint64_t reanchor_epoch_ = 0;        // 递增即触发混音线程重锚
    bool running_ = false;               // Start/Stop 生命周期（sync_mu_ 保护）

    // ---- 混音线程私有（除 have_buffered_ 经 sync_mu_ 交接）----
    std::thread feed_thread_;
    bool thread_started_ = false;        // feed_thread_ 是否 joinable 过（Stop 用）
    uint64_t seen_epoch_ = 0;
    int64_t rendered_upto_tick_ = 0;     // 下一块的起始（只由混音线程写）
    bool have_buffered_ = false;         // 本播放会话是否已有样本进入引擎
                                         //（sync_mu_ 保护：Sync 置 false，feed 置 true）
    uint64_t snapshot_version_seen_ = 0; // 0 = 尚未装载
    int64_t underrun_warn_count_ = 0;    // 欠载日志节流（线程内私有）
    std::map<uint64_t, ClipEntry> entries_;  // clip_id → 状态（快照版本内有效）
    std::vector<float> acc_;             // 块累加缓冲（预分配后复用，无逐块分配）
    CancelToken stop_token_;             // Stop 时触发，读取器 IO 提前退出

    // ---- 统计（跨线程读，原子量）----
    std::atomic<uint64_t> blocks_rendered_{0};
    std::atomic<uint64_t> blocks_dropped_{0};
    std::atomic<uint64_t> underruns_{0};
    std::atomic<uint64_t> resyncs_{0};
};

}  // namespace cq

#endif  // CQ_AUDIO_PREVIEW_MIXER_H_
