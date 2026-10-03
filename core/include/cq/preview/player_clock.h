// ChuanqiCut — 播放时钟（UIA-010）
//
// 职责：回答「现在播放到时间线的哪一刻」，**不负责取帧与渲染**（那是
// PreviewRenderer 的事，两者靠调用方串起来）。
//
// 为什么时间要由内核算，而不是 UI 拿 Timer 累加：
//   * **累加必然漂移**。定时器回调间隔有抖动（负载、系统休眠、渲染超时），
//     每帧 +1/30 秒的写法播 10 分钟能偏出好几帧。这里把时刻定义成
//     **墙钟的函数**：`t = anchor + (now - anchor_wall)`，误差不累积。
//   * 帧率是有理数（29.97 = 30000/1001），浮点秒表达不了 —— 时刻量化到
//     帧网格，全程整数（红线 #4）。
//   * 业务逻辑下沉（红线 #1）：播放状态机不该写在 Swift 里。
//
// 线程：可跨线程读（内部 mutex，持锁 = 几个整数运算）。典型用法 ——
//   UI/播放线程按帧调用 `Tick()` 推进边界，`CurrentTime()` 供渲染取时间。
//
// 语义（刻意定死，便于断言）：
//   * kStopped 时 CurrentTime() **恒为 0**（初始、Stop()、播完自然结束都回到 0）。
//     播完停在末帧是另一种语义，本期不做 —— 语义必须单一。
//   * 边界由 `Tick()` 判定，不在 CurrentTime() 里偷偷改状态（const 方法不改状态）。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常（错误一律 Status）。

#ifndef CQ_PREVIEW_PLAYER_CLOCK_H_
#define CQ_PREVIEW_PLAYER_CLOCK_H_

#include <chrono>
#include <cstdint>
#include <mutex>

#include "cq/base/status.h"
#include "cq/base/time.h"

namespace cq {

enum class PlayerState : int32_t {
    kStopped = 0,  // 未播放（CurrentTime 恒 0）
    kPlaying = 1,  // 播放中（时刻随墙钟推进）
    kPaused = 2,   // 暂停（时刻冻结在当前值）
};

class PlayerClock {
public:
    // frame_duration：一帧的时长（有理数）。29.97fps = {1001, 30000}。
    explicit PlayerClock(const RationalTime& frame_duration);

    // 播放边界（时间线总时长）。未设置 = 无边界（一直播，靠调用方停）。
    // 内部重定标到帧网格的 timescale（向下取整）—— 跨 timescale 必须有显式
    // 舍入方向（time.h 的约束，静默默认会导致边界差一帧）。
    Status SetDuration(const RationalTime& duration);

    void SetLoop(bool loop);

    // 从当前时刻开始播放（Stopped 时即从 0 开始）。重锚墙钟 —— 暂停多久都不影响。
    Status Play();
    // 冻结在当前时刻。
    void Pause();
    // 停止并回到 0。
    void Stop();
    // 定位到 t（播放中重锚；非播放状态只改时刻）。量化到帧网格（向下）。
    Status Seek(const RationalTime& t);

    PlayerState State() const;
    bool IsPlaying() const;

    // 当前播放时刻（帧网格量化）。Playing 时按墙钟推算 —— 与调用频率无关。
    RationalTime CurrentTime() const;

    // 边界处理：到达 duration 时 —— loop 开：回绕到 0 继续；否则：停止回 0。
    // 未到边界或不在播放中：no-op 返回 kOk。**由调用方按帧调用**（它决定
    // "什么时候算到头了"，时钟自己不跑线程 —— 不替上层做线程决策）。
    Status Tick();

private:
    // 当前 tick 的**无锁版本**：调用方必须已持有 mtx_（mutex 非递归，
    // CurrentTime() 不可从持锁路径重入 —— Pause() 踩过一次）。
    int64_t CurrentTicksLocked() const;
    // 把时刻钉到 value（帧网格 tick）并重锚墙钟。
    void Rebase(int64_t value);
    int64_t NowNs() const;
    int64_t ElapsedTicks(int64_t ns) const;

    mutable std::mutex mtx_;

    RationalTime frame_{1001, 30000};  // 帧时长；timescale 即内部时间网格
    int64_t frame_ticks_ = 1001;       // 帧时长（本网格下的 tick 数，用于量化）
    int64_t duration_ticks_ = INT64_MAX;  // 边界；INT64_MAX = 未设置
    bool loop_ = false;

    PlayerState state_ = PlayerState::kStopped;
    int64_t value_ = 0;        // 锚定时刻（已量化到帧网格）
    int64_t anchor_ns_ = 0;    // 锚定时的墙钟（steady_clock，纳秒）
};

}  // namespace cq

#endif  // CQ_PREVIEW_PLAYER_CLOCK_H_
