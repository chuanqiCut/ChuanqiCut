// ChuanqiCut — 播放时钟实现（UIA-010）
//
// 契约见 player_clock.h。核心只有一条：**时刻 = 墙钟的函数**，不是帧数累加。

#include "cq/preview/player_clock.h"

#include <limits>

namespace cq {
namespace {

constexpr int64_t kNsPerSecond = 1000000000LL;

// ns * timescale / 1e9，拆成「秒部分 + 纳秒部分」两段算，避免中间值溢出。
//   sec 部分：sec * ts          （播放 1 小时 * 30000 = 1.08e8，安全）
//   rem 部分：rem * ts / 1e9    （rem < 1e9，* 30000 = 3e13，安全）
int64_t NsToTicks(int64_t ns, int32_t timescale) {
    const int64_t sec = ns / kNsPerSecond;
    const int64_t rem = ns % kNsPerSecond;
    return sec * static_cast<int64_t>(timescale)
           + (rem * static_cast<int64_t>(timescale)) / kNsPerSecond;
}

}  // namespace

PlayerClock::PlayerClock(const RationalTime& frame_duration) {
    if (frame_duration.IsValid() && frame_duration.value > 0) {
        frame_ = frame_duration;
        frame_ticks_ = frame_duration.value;
    }
    // 非法输入（timescale<=0 或 value<=0）→ 保持默认 1001/30000，不崩、不猜。
}

Status PlayerClock::SetDuration(const RationalTime& duration) {
    if (duration.IsInvalid()) return Status{StatusCode::kInvalidArgument};
    std::lock_guard<std::mutex> lk(mtx_);
    if (duration.timescale == frame_.timescale) {
        duration_ticks_ = duration.value;
        return Status::Ok();
    }
    // 跨 timescale：显式 Floor（边界宁可短一帧，不越界一帧）。
    RationalTime scaled{0, 1};
    Status s = Rescale(duration, frame_.timescale, RoundMode::kFloor, scaled);
    if (!s.IsOk()) return s;
    duration_ticks_ = scaled.value;
    return Status::Ok();
}

void PlayerClock::SetLoop(bool loop) {
    std::lock_guard<std::mutex> lk(mtx_);
    loop_ = loop;
}

Status PlayerClock::Play() {
    std::lock_guard<std::mutex> lk(mtx_);
    // 从当前锚定时刻起播（Stopped 时 value_ 恒为 0 → 从头播）。
    Rebase(value_);
    state_ = PlayerState::kPlaying;
    return Status::Ok();
}

void PlayerClock::Pause() {
    std::lock_guard<std::mutex> lk(mtx_);
    // ⚠️ 用无锁版本：CurrentTime() 自己也加锁，mutex 非递归 —— 这里直接调会死锁。
    if (state_ == PlayerState::kPlaying) {
        value_ = CurrentTicksLocked();  // 冻结在"此刻"
    }
    state_ = PlayerState::kPaused;
}

void PlayerClock::Stop() {
    std::lock_guard<std::mutex> lk(mtx_);
    state_ = PlayerState::kStopped;
    value_ = 0;
}

Status PlayerClock::Seek(const RationalTime& t) {
    if (t.IsInvalid()) return Status{StatusCode::kInvalidArgument};
    RationalTime scaled{0, 1};
    Status s = Rescale(t, frame_.timescale, RoundMode::kFloor, scaled);
    if (!s.IsOk()) return s;

    std::lock_guard<std::mutex> lk(mtx_);
    // 量化到帧网格（向下）：时刻必须是整帧，否则"播到第几帧"没有意义。
    const int64_t q = (scaled.value / frame_ticks_) * frame_ticks_;
    if (state_ == PlayerState::kPlaying) {
        Rebase(q);  // 播放中定位：重锚，之前的流逝时间作废
    } else {
        value_ = q;
    }
    return Status::Ok();
}

PlayerState PlayerClock::State() const {
    std::lock_guard<std::mutex> lk(mtx_);
    return state_;
}

bool PlayerClock::IsPlaying() const {
    std::lock_guard<std::mutex> lk(mtx_);
    return state_ == PlayerState::kPlaying;
}

RationalTime PlayerClock::CurrentTime() const {
    std::lock_guard<std::mutex> lk(mtx_);
    return RationalTime{CurrentTicksLocked(), frame_.timescale};
}

int64_t PlayerClock::CurrentTicksLocked() const {
    // 无锁版本：**调用方必须已持有 mtx_**（mutex 非递归，CurrentTime 不可重入）。
    if (state_ == PlayerState::kStopped) return 0;
    int64_t ticks = value_;
    if (state_ == PlayerState::kPlaying) {
        ticks += ElapsedTicks(NowNs() - anchor_ns_);
        // 量化到帧网格：播放时刻必须是整帧。
        ticks = (ticks / frame_ticks_) * frame_ticks_;
    }
    if (ticks < 0) ticks = 0;
    if (duration_ticks_ != std::numeric_limits<int64_t>::max() && ticks > duration_ticks_) {
        ticks = duration_ticks_;
    }
    return ticks;
}

Status PlayerClock::Tick() {
    std::lock_guard<std::mutex> lk(mtx_);
    if (state_ != PlayerState::kPlaying) return Status::Ok();
    if (duration_ticks_ == std::numeric_limits<int64_t>::max()) return Status::Ok();

    int64_t ticks = value_ + ElapsedTicks(NowNs() - anchor_ns_);
    if (ticks < duration_ticks_) return Status::Ok();

    if (loop_) {
        Rebase(0);  // 回绕到 0 继续播（丢弃超出部分，不做取模补偿 —— MVP 语义）
        return Status::Ok();
    }
    // 自然结束：停止并回到 0（语义见头文件：kStopped 时时刻恒 0）。
    state_ = PlayerState::kStopped;
    value_ = 0;
    return Status::Ok();
}

void PlayerClock::Rebase(int64_t value) {
    value_ = (value / frame_ticks_) * frame_ticks_;
    anchor_ns_ = NowNs();
}

int64_t PlayerClock::NowNs() const {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

int64_t PlayerClock::ElapsedTicks(int64_t ns) const {
    if (ns <= 0) return 0;
    return NsToTicks(ns, frame_.timescale);
}

}  // namespace cq
