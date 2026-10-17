// ChuanqiCut — 预览音频混音器实现（AUDIO-002）
//
// 时钟/重锚/欠载语义见头文件注释。实现要点：
//   * 时间一律 int64 tick（项目网格 kProjectTimeScale）——ChqRationalTime 只在
//     Sync 边界与读取器 Seek 处出现，块级运算全是整数（可断言、无浮点漂移）。
//   * rendered_upto_tick_ 只由混音线程写（Sync 经 reanchor_epoch_ 间接重锚），
//     免锁；同步状态经 sync_mu_（临界区微秒级，主线程零阻塞）。
//   * 读取失败/EOF 不伪造数据：缺口 = 静音 + 节流日志 + 计数。
//   * 求和/削波走 AUDIO-004 混音原语（chq_mix.h）—— 全仓只有一套混音实现，
//     本类只做「哪段样本进哪个偏移」的编排，不做样本数学。

#include "cq/audio/chq_preview_mixer.h"

#include <algorithm>

#include "cq/audio/chq_mix.h"
#include "cq/base/chq_logging.h"

namespace cq {

namespace {

constexpr int kMixLogThrottle = 100;  // 读取失败/欠载日志的节流系数

// 轨增益：模型 ChqTrack 尚无音量字段（mute 已有，音量属模型线写集），
// 当前恒 1.0 直通。**模型立音量字段后，此处即唯一改点** —— 混音数学本身
// 已在 chq_mix.h 支持任意增益（含反相），无需再动本类。
constexpr float kTrackGainUnity = 1.0f;

// 节流告警（Release 可见 —— 可闻缺口是「链路病了」的最外层症状，别塞回 NDEBUG）。
void WarnThrottled(const char* what, int& count, const char* detail) {
    if (count % kMixLogThrottle == 0) {
        CQ_LOG_WARN_WF(ChqWorkflow::kPreview, "预览音频：", what, " ", detail);
    }
    ++count;
}

}  // namespace

ChqPreviewAudioMixer::ChqPreviewAudioMixer(ChqIAudioTrackReaderFactory* readers,
                                           ChqIModelSnapshotProvider* snapshots,
                                           ChqIAudioEngine* engine, const Config& cfg)
    : cfg_(cfg), readers_(readers), snapshots_(snapshots), engine_(engine) {
    // 块规格合法性：ticks 必须为整（frames*ts 必须被 rate 整除），否则块网格断裂。
    const int64_t rate = static_cast<int64_t>(cfg.spec.sample_rate);
    const int64_t ts = static_cast<int64_t>(kProjectTimeScale);
    int64_t block_ticks = static_cast<int64_t>(cfg.spec.frames_per_block) * ts;
    if (rate > 0 && block_ticks % rate == 0) {
        block_ticks_ = block_ticks / rate;
    } else {
        block_ticks_ = 0;  // 构造完成但 Start() 会拒绝
    }
    lookahead_ticks_ = MsToTicks(static_cast<int64_t>(cfg.lookahead_ms));
    resync_threshold_ticks_ = MsToTicks(static_cast<int64_t>(cfg.resync_threshold_ms));
}

ChqPreviewAudioMixer::~ChqPreviewAudioMixer() {
    Stop();
}

int64_t ChqPreviewAudioMixer::TicksToFrames(int64_t ticks) const {
    const int64_t rate = static_cast<int64_t>(cfg_.spec.sample_rate);
    return (ticks * rate) / static_cast<int64_t>(kProjectTimeScale);
}

int64_t ChqPreviewAudioMixer::FramesToTicks(int64_t frames) const {
    const int64_t rate = static_cast<int64_t>(cfg_.spec.sample_rate);
    return (frames * static_cast<int64_t>(kProjectTimeScale)) / rate;
}

int64_t ChqPreviewAudioMixer::MsToTicks(int64_t ms) const {
    // ms * 120000 / 1000 —— ms 级入参，int64 不会溢出（1 小时 = 3.6e6 ms）。
    return ms * static_cast<int64_t>(kProjectTimeScale) / 1000;
}

ChqStatus ChqPreviewAudioMixer::Start() {
    if (block_ticks_ == 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);  // 块网格非整（见构造函数）
    }
    std::thread worker;
    {
        std::lock_guard<std::mutex> lock(sync_mu_);
        if (running_) {
            return ChqStatus::Ok();
        }
        const ChqStatus s = engine_->Start();
        if (!s.IsOk()) {
            return s;  // 引擎起不来：如实失败（调用方据此走「预览无声」降级）
        }
        running_ = true;
    }
    // std::thread 构造失败会 terminate（本仓禁异常）—— 与 preview_pump 同口径：
    // 线程资源耗尽属进程级病态，不静默吞。
    worker = std::thread([this] { FeedLoop(); });
    feed_thread_ = std::move(worker);
    thread_started_ = true;
    return ChqStatus::Ok();
}

void ChqPreviewAudioMixer::Stop() {
    {
        std::lock_guard<std::mutex> lock(sync_mu_);
        if (!running_) {
            return;
        }
        running_ = false;
    }
    stop_token_.RequestCancel();  // 读取器 IO 提前退出
    if (thread_started_ && feed_thread_.joinable()) {
        feed_thread_.join();
        thread_started_ = false;
    }
    (void)engine_->Stop();
}

void ChqPreviewAudioMixer::Sync(const ChqRationalTime& playhead, bool playing) {
    ChqRationalTime t{playhead.value, playhead.timescale};
    if (t.timescale != kProjectTimeScale) {
        Rescale(t, kProjectTimeScale, ChqRoundMode::kRound, t);
    }
    std::lock_guard<std::mutex> lock(sync_mu_);
    const bool was_playing = playing_;
    playhead_ = t;
    playing_ = playing;
    sync_wall_ = std::chrono::steady_clock::now();
    if (was_playing && !playing) {
        // 暂停/停止：立即静音（引擎缓冲在途的 ≤ lookahead 一段不播）。
        (void)engine_->FlushOutput();
        have_buffered_ = false;
    }
    // 恢复播放（含从暂停态拖拽后播放）：登记重锚点，混音线程下个周期生效。
    if (!was_playing && playing) {
        reanchor_to_tick_ = t.value;
        ++reanchor_epoch_;
    }
}

ChqPreviewAudioMixer::Stats ChqPreviewAudioMixer::GetStats() const {
    Stats s;
    s.blocks_rendered = blocks_rendered_.load(std::memory_order_relaxed);
    s.blocks_dropped = blocks_dropped_.load(std::memory_order_relaxed);
    s.underruns = underruns_.load(std::memory_order_relaxed);
    s.resyncs = resyncs_.load(std::memory_order_relaxed);
    return s;
}

void ChqPreviewAudioMixer::DropEntries() {
    // 混音线程专用：读取器 Destroy 可能拆平台解码会话（毫秒级），
    // 不在音频实时路径 —— 本线程允许。
    entries_.clear();
    snapshot_version_seen_ = 0;
}

void ChqPreviewAudioMixer::FeedLoop() {
    std::shared_ptr<const ChqModelSnapshot> snap;
    while (true) {
        bool playing = false;
        bool have_buffered = false;
        ChqRationalTime playhead{0, 1};
        std::chrono::steady_clock::time_point wall{};
        uint64_t epoch = 0;
        int64_t reanchor_to = 0;
        {
            std::lock_guard<std::mutex> lock(sync_mu_);
            playing = playing_;
            have_buffered = have_buffered_;
            playhead = playhead_;
            wall = sync_wall_;
            epoch = reanchor_epoch_;
            reanchor_to = reanchor_to_tick_;
            if (!running_) {
                return;  // Stop() 持锁置位后再取一次状态即退出
            }
        }

        const auto nap = [this] {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(1000 / static_cast<int>(cfg_.feed_hz)));
        };

        if (!playing) {
            // 暂停分支：Sync 已 Flush；若上一个周期在飞的窗口在本 Sync 之后
            // 又写入了块（逐块查播放态只保证 ≤ 1 块的竞态窗口），在这里补一次
            // Flush 清掉尾巴 —— 暂停后不残留任何可闻样本。
            if (have_buffered) {
                (void)engine_->FlushOutput();
                have_buffered = false;
            }
            nap();  // 空转节拍：只等播放恢复
            continue;
        }

        // 重锚（恢复播放 / 暂停后恢复）：清读取状态 + 渲染位置对齐重锚点。
        if (epoch != seen_epoch_) {
            seen_epoch_ = epoch;
            DropEntries();
            rendered_upto_tick_ = reanchor_to;
            have_buffered = false;
        }

        // 外推播放头：Sync 时刻的播放头 + 已流逝的墙钟。
        const auto now = std::chrono::steady_clock::now();
        const int64_t elapsed_ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(now - wall).count();
        const int64_t elapsed_ticks =
            elapsed_ns * static_cast<int64_t>(kProjectTimeScale) / 1'000'000'000;
        const int64_t extrapolated = playhead.value + elapsed_ticks;

        // 快照装载。快照实例更换 = 模型可能已变：读取状态全部失效
        //（快照每次变更都重建实例，指针身份即版本；重建于各 clip 首次命中）。
        snap = snapshots_->CurrentSnapshot();
        if (snap == nullptr) {
            nap();
            continue;
        }
        const auto version = reinterpret_cast<uintptr_t>(snap.get());
        if (static_cast<uint64_t>(version) != snapshot_version_seen_) {
            DropEntries();
            snapshot_version_seen_ = static_cast<uint64_t>(version);
        }

        // 引擎缓冲水位：B = 引擎里尚未播放的帧数（Query 近似快照）。
        const uint64_t buffered_frames = engine_->BufferedFrames();

        // 欠载检测：本会话写过数据后引擎缓冲又耗尽 → 已渲染位置全部过期，
        // 丢弃并重锚到当前播放头（可闻静音缺口如实发生，不伪造连续）。
        if (have_buffered && buffered_frames == 0) {
            underruns_.fetch_add(1, std::memory_order_relaxed);
            if (underrun_warn_count_ % kMixLogThrottle == 0) {
                CQ_LOG_WARN_WF(ChqWorkflow::kPreview,
                               "预览音频欠载：缓冲耗尽，重锚到外推播放头");
            }
            ++underrun_warn_count_;
            (void)engine_->FlushOutput();
            DropEntries();
            rendered_upto_tick_ = extrapolated;
            have_buffered = false;
        }

        // 漂移护栏：缓冲前沿（= 渲染前沿 - 在途样本）与外推播放头差超阈值
        // → Flush + 重锚。播放中 seek / 拖拽播放头都在这里收敛（≤ 一个 feed
        // 周期）；稳态下前沿 ≈ 播放头（缓冲覆盖 [now, now+lookahead]），drift ≈ 0。
        if (have_buffered && buffered_frames > 0) {
            const int64_t front =
                rendered_upto_tick_ - FramesToTicks(static_cast<int64_t>(buffered_frames));
            const int64_t drift = front - extrapolated;
            if (drift > resync_threshold_ticks_ || -drift > resync_threshold_ticks_) {
                resyncs_.fetch_add(1, std::memory_order_relaxed);
                CQ_LOG_WARN_WF(ChqWorkflow::kPreview,
                               "预览音频漂移超阈值：flush 并重锚 drift_ticks=%lld",
                               static_cast<long long>(drift));
                (void)engine_->FlushOutput();
                DropEntries();
                rendered_upto_tick_ = extrapolated;
                have_buffered = false;
            }
        }

        // 渲染窗口：[rendered_upto, extrapolated + lookahead)。
        const int64_t target_end = extrapolated + lookahead_ticks_;
        if (rendered_upto_tick_ < target_end) {
            const int64_t before = rendered_upto_tick_;
            rendered_upto_tick_ = RenderWindow(rendered_upto_tick_, target_end, snap);
            if (rendered_upto_tick_ > before) {
                have_buffered = true;  // 本周期确实写进了引擎
            }
        }

        {
            std::lock_guard<std::mutex> lock(sync_mu_);
            have_buffered_ = have_buffered;
        }
        nap();
    }
}

int64_t ChqPreviewAudioMixer::RenderWindow(int64_t from_tick, int64_t target_end_tick,
                                           const std::shared_ptr<const ChqModelSnapshot>& snap) {
    int64_t pos = from_tick;
    while (pos < target_end_tick) {
        if (stop_token_.IsCancelled()) {
            break;
        }
        // 逐块查播放态：Sync(暂停) 可能落在本窗口渲染中途 —— 立即停写，
        // 残留的 ≤1 块竞态尾巴由暂停分支的补 Flush 清掉。临界区微秒级。
        {
            std::lock_guard<std::mutex> lock(sync_mu_);
            if (!playing_) {
                break;
            }
        }
        acc_.assign(static_cast<size_t>(cfg_.spec.frames_per_block) *
                        static_cast<size_t>(cfg_.spec.channels),
                    0.0f);
        MixBlock(pos, snap);

        ChqPcmBuffer out;
        out.format = cfg_.spec.format;
        out.channels = cfg_.spec.channels;
        out.sample_rate = cfg_.spec.sample_rate;
        out.frame_count = cfg_.spec.frames_per_block;
        out.data = acc_.data();
        out.data_bytes = acc_.size() * sizeof(float);
        out.pts = ChqRationalTime{pos, kProjectTimeScale};

        const ChqStatus ws = engine_->Write(out);
        if (!ws.IsOk()) {
            // 引擎缓冲满：整块不写（全有或全无），渲染位置不推进，下周期重试。
            blocks_dropped_.fetch_add(1, std::memory_order_relaxed);
            break;
        }
        blocks_rendered_.fetch_add(1, std::memory_order_relaxed);
        pos += block_ticks_;
    }
    return pos;
}

ChqPreviewAudioMixer::ClipEntry* ChqPreviewAudioMixer::EnsureEntry(
    const std::shared_ptr<const ChqModelSnapshot>& snap, const ChqClip& clip) {
    auto it = entries_.find(clip.id);
    if (it != entries_.end()) {
        return &it->second;
    }
    ClipEntry e;
    e.clip_id = clip.id;
    e.asset_id = clip.source.asset_id;
    e.clip_start_tick = clip.start.value;
    e.source_in_tick = clip.source.source_in.value;
    ChqRationalTime end{0, 1};
    if (clip.End(end).IsOk()) {
        e.clip_end_tick = end.value;
    }

    // 素材路径拷贝进 entry：快照的 ChqMediaSource.path 指向表内字符串，
    // 跨发布版本无效（asset_registry.h 明示）。
    if (snap->assets != nullptr) {
        if (const ChqMediaSource* src = snap->assets->Find(clip.source.asset_id);
            src != nullptr && src->path != nullptr) {
            e.path.assign(src->path, src->path_len);
        }
    }
    if (!e.path.empty()) {
        ChqAudioReaderPtr reader;
        const ChqMediaSource src{e.path.c_str(), e.path.size()};
        const ChqStatus cs = readers_->Create(src, cfg_.spec, reader);
        if (!cs.IsOk()) {
            // 打开失败（文件丢失/不可解析）：静音 + 节流日志，不崩溃。
            CQ_LOG_WARN_WF(ChqWorkflow::kPreview, "预览音频：读取器打开失败 status=%d",
                           static_cast<int>(cs.code));
        } else {
            e.has_audio = reader->HasAudio();
            e.reader = std::move(reader);
        }
    } else {
        CQ_LOG_WARN_WF(ChqWorkflow::kPreview, "预览音频：素材表缺失 asset_id=%llu",
                       static_cast<unsigned long long>(clip.source.asset_id));
    }
    if (!e.has_audio) {
        e.eof = true;  // 无读取器/无音频流：直通静音，永不消费
    }
    auto ins = entries_.emplace(clip.id, std::move(e));
    return &ins.first->second;
}

void ChqPreviewAudioMixer::AnchorEntry(ClipEntry& e, int64_t timeline_tick) {
    if (e.reader == nullptr || !e.has_audio) {
        return;
    }
    // 时间线 → 源时间（1:1 恒速映射；MEDIA-013 TimeMap 落地前与视频预览同语义）。
    const int64_t src_tick = e.source_in_tick + (timeline_tick - e.clip_start_tick);
    const ChqStatus ss =
        e.reader->Seek(ChqRationalTime{src_tick, kProjectTimeScale}, stop_token_);
    if (stop_token_.IsCancelled()) {
        return;
    }
    if (!ss.IsOk()) {
        WarnThrottled("Seek 失败", e.warn_count, "（缺口静音）");
        e.eof = true;
        return;
    }
    e.needs_seek = false;
    e.eof = false;
    e.fifo.clear();
    e.fifo_start_tick = timeline_tick;
}

void ChqPreviewAudioMixer::FillFifo(ClipEntry& e, int64_t until_tick) {
    if (!e.has_audio || e.reader == nullptr || e.eof) {
        return;
    }
    const size_t ch = static_cast<size_t>(cfg_.spec.channels);
    while (true) {
        const int64_t have_frames =
            static_cast<int64_t>(e.fifo.size() / ch);
        if (e.fifo_start_tick + FramesToTicks(have_frames) >= until_tick) {
            return;
        }
        if (stop_token_.IsCancelled()) {
            return;
        }
        ChqPcmBuffer r;
        const ChqStatus rs = e.reader->ReadBlock(r, stop_token_);
        if (stop_token_.IsCancelled()) {
            return;
        }
        if (rs.code == ChqStatusCode::kIoNotFound) {
            e.eof = true;  // 素材音频比片段短：余下片段时长静音（诚实，不循环填充）
            return;
        }
        if (!rs.IsOk() || r.data == nullptr || r.frame_count == 0) {
            WarnThrottled("ReadBlock 失败", e.warn_count, "（缺口静音）");
            e.eof = true;
            return;
        }
        // 读取器产出的首样本时间线位置 = clip.start + (素材 pts - source_in)。
        int64_t t0 = e.clip_start_tick + (r.pts.value - e.source_in_tick);
        const int64_t expected = e.fifo_start_tick + FramesToTicks(have_frames);
        if (t0 > expected) {
            // 读取器侧出现空洞（seek 精度/边界舍入）：以静音补齐，保持时间轴连续。
            const size_t pad_frames = static_cast<size_t>(TicksToFrames(t0 - expected));
            e.fifo.insert(e.fifo.end(), pad_frames * ch, 0.0f);
        } else if (t0 < expected) {
            // 读取器给出的位置早于 FIFO 末端（不应发生；防御：丢弃重叠后继续）。
            const int64_t skip_frames = TicksToFrames(expected - t0);
            if (skip_frames >= static_cast<int64_t>(r.frame_count)) {
                continue;  // 整块都落在已消费区（异常读取器）：丢弃
            }
            t0 = expected;
        }
        // 交错规格恒定（创建时同一 spec）：直接按 float32 拷贝。
        const auto* samples = static_cast<const float*>(r.data);
        const size_t count = static_cast<size_t>(r.frame_count) * ch;
        e.fifo.insert(e.fifo.end(), samples, samples + count);
    }
}

void ChqPreviewAudioMixer::MixBlock(int64_t block_start_tick,
                                    const std::shared_ptr<const ChqModelSnapshot>& snap) {
    if (snap == nullptr || snap->timeline == nullptr) {
        return;
    }
    const int64_t block_end_tick = block_start_tick + block_ticks_;
    const size_t ch = static_cast<size_t>(cfg_.spec.channels);

    for (const ChqTrack& track : snap->timeline->Tracks()) {
        if (!track.enabled || track.muted) {
            continue;
        }
        for (const ChqClip& clip : track.clips) {
            // clips 按 start 升序维护（timeline.h）：起点已越过本块即全部越界。
            ChqRationalTime clip_end{0, 1};
            if (!clip.End(clip_end).IsOk()) {
                continue;
            }
            if (clip_end.value <= block_start_tick) {
                continue;
            }
            if (clip.start.value >= block_end_tick) {
                break;
            }
            const int64_t ov_s = std::max(block_start_tick, clip.start.value);
            const int64_t ov_e = std::min(block_end_tick, clip_end.value);
            if (ov_s >= ov_e) {
                continue;
            }

            ClipEntry* e = EnsureEntry(snap, clip);
            if (e == nullptr || !e->has_audio) {
                continue;
            }
            if (e->needs_seek) {
                AnchorEntry(*e, ov_s);
                if (e->needs_seek) {  // Seek 失败（e.eof 置位）：本块静音
                    continue;
                }
            } else if (e->fifo_start_tick < ov_s) {
                // FIFO 前沿早于消费起点（上一块的消费残差）：丢弃过期前缀。
                const size_t drop_samples = static_cast<size_t>(std::min<int64_t>(
                                                TicksToFrames(ov_s - e->fifo_start_tick),
                                                static_cast<int64_t>(e->fifo.size() / ch))) *
                                            ch;
                e->fifo.erase(e->fifo.begin(),
                              e->fifo.begin() + static_cast<std::ptrdiff_t>(drop_samples));
                e->fifo_start_tick = ov_s;
            }

            FillFifo(*e, ov_e);

            // 消费 [copy_from, ov_e) ∩ FIFO 可用区；FIFO 未覆盖到的头部（不应发生，
            // 防御）留静音。
            const int64_t copy_from = std::max(ov_s, e->fifo_start_tick);
            const int64_t want_frames = std::min(
                TicksToFrames(ov_e - copy_from),
                static_cast<int64_t>(e->fifo.size() / ch));
            if (want_frames > 0) {
                const int64_t dst_frame0 = TicksToFrames(copy_from - block_start_tick);
                // 块内空间防御（舍入边界可能出现 ±1 帧）：放不下的尾部不消费，
                // 留在 FIFO 里由下一块的「过期前缀丢弃」逻辑收掉。clamp 显式写在
                // 调用点，混音原语本身保持全有或全无（可单测，见 test_audio_mix）。
                const int64_t block_frames =
                    static_cast<int64_t>(cfg_.spec.frames_per_block);
                int64_t fit_frames = want_frames;
                if (dst_frame0 + fit_frames > block_frames) {
                    fit_frames = block_frames - dst_frame0;
                }
                if (fit_frames > 0) {
                    const ChqStatus ms = MixAccumulateRange(
                        acc_.data(), static_cast<size_t>(block_frames),
                        static_cast<uint32_t>(ch), e->fifo.data(), 0,
                        static_cast<size_t>(fit_frames),
                        static_cast<size_t>(dst_frame0), kTrackGainUnity);
                    if (ms.IsOk()) {
                        const size_t erase_samples = static_cast<size_t>(fit_frames) * ch;
                        e->fifo.erase(e->fifo.begin(),
                                      e->fifo.begin() +
                                          static_cast<std::ptrdiff_t>(erase_samples));
                        e->fifo_start_tick += FramesToTicks(fit_frames);
                    } else {
                        // 不可达防御：参数已在上面 clamp/校验。真到了这里 = 内部
                        // 不一致，Warn 留痕（Release 可见）且不推进消费位置。
                        WarnThrottled("混音累加被拒", e->warn_count, "内部不一致");
                    }
                }
            }
            if (ov_e >= e->clip_end_tick) {
                // 片段在本块内结束：残余（FillFifo 的整块超额部分）一并丢弃；
                // 标记待 Seek —— 该 clip 之后不应再被消费，防御未来任何错位复用。
                e->fifo.clear();
                e->fifo_start_tick = ov_e;
                e->needs_seek = true;
            }
        }
    }

    // 削波（求和可能超 [-1,1]；不做母带级限制器 —— 预览 MVP 语义，写明）。
    // 走 AUDIO-004 混音原语：硬削波到 [-1,1]，非有限值（解码异常/累加溢出的
    // 下游）按 0 处置，输出恒在 [-1,1]。
    (void)MixClipRange(acc_.data(), static_cast<size_t>(cfg_.spec.frames_per_block),
                       static_cast<uint32_t>(cfg_.spec.channels));
}

}  // namespace cq
