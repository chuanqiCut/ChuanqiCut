// ChuanqiCut — 播放时钟单测（UIA-010）
//
// 验收核心：**时刻是墙钟的函数，不是帧数累加**。
//   * 播放推进量与真实流逝时间一致（sleep 120ms → 推进 ≈120ms，不是"每帧 +33ms"）
//   * 时刻恒为**整帧**（帧网格量化）—— 否则"播到第几帧"没有意义
//   * 暂停冻结、定位重锚、边界与循环语义单一（Stopped 时刻恒 0）

#include <chrono>
#include <cstdio>
#include <thread>

#include "cq/base/rational_time.h"
#include "cq/preview/player_clock.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (cond) {
        printf("  ok  : %s\n", msg);
    } else {
        ++g_failures;
        printf("  FAIL: %s\n", msg);
    }
}

// 29.97fps：一帧 = 1001/30000 秒
constexpr int64_t kFrameTicks = 1001;
constexpr int32_t kTs = 30000;

double Seconds(const cq::RationalTime& t) { return t.ToSeconds(); }

}  // namespace

int main() {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("== ChuanqiCut 播放时钟验收（UIA-010）==\n");

    using cq::PlayerClock;
    using cq::PlayerState;
    using cq::RationalTime;
    using cq::Status;

    PlayerClock clock(RationalTime{kFrameTicks, kTs});

    // ---- 初始状态 ----
    Check(clock.State() == PlayerState::kStopped, "初始状态 Stopped");
    Check(clock.CurrentTime() == RationalTime(0, kTs), "Stopped 时时刻恒 0");
    Check(!clock.IsPlaying(), "初始不在播放");

    // ---- 播放：推进量跟真实时间走（墙钟驱动，非帧数累加）----
    Check(clock.Play().IsOk(), "Play");
    Check(clock.IsPlaying(), "Play 后 IsPlaying");
    std::this_thread::sleep_for(std::chrono::milliseconds(120));
    const double after120 = Seconds(clock.CurrentTime());
    Check(after120 >= 0.08 && after120 < 0.5, "sleep 120ms → 推进 ≈120ms（墙钟驱动）");
    Check(clock.CurrentTime().value % kFrameTicks == 0, "时刻恒为整帧（帧网格量化）");

    // ---- 暂停：冻结 ----
    clock.Pause();
    Check(clock.State() == PlayerState::kPaused, "Pause 后状态 Paused");
    const cq::RationalTime frozen = clock.CurrentTime();
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    Check(clock.CurrentTime() == frozen, "暂停后时刻冻结（不随墙钟走）");

    // ---- 恢复：从冻结处继续 ----
    Check(clock.Play().IsOk(), "Play 恢复");
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    const double resumed = Seconds(clock.CurrentTime());
    Check(resumed >= Seconds(frozen) && resumed - Seconds(frozen) < 0.3,
          "恢复后从冻结处继续（不跳回 0）");

    // ---- 定位：重锚 ----
    Check(clock.Seek(RationalTime{15000, kTs}).IsOk(), "Seek 到 0.5s");
    const cq::RationalTime seeked = clock.CurrentTime();
    // 15000 / 1001 = 14.98 → floor 14 → 14 * 1001 = 14014（量化向下，不越帧）
    Check(seeked.value == 14 * kFrameTicks, "Seek 量化到整帧（向下）");
    Check(seeked.value % kFrameTicks == 0, "Seek 后仍是整帧");

    clock.Pause();
    Check(clock.Seek(RationalTime{0, kTs}).IsOk(), "暂停态 Seek 到 0");
    Check(clock.CurrentTime() == RationalTime(0, kTs), "Seek 到 0 生效");

    // ---- 边界：播完自然结束 = Stopped 且回 0 ----
    PlayerClock bounded(RationalTime{kFrameTicks, kTs});
    Check(bounded.SetDuration(RationalTime{6000, kTs}).IsOk(), "设置时长 0.2s");
    bounded.Play();
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    Check(Seconds(bounded.CurrentTime()) <= 0.2 + 1e-9, "超过边界后时刻被 clamp 到时长");
    Check(bounded.Tick().IsOk(), "Tick 到边界");
    Check(bounded.State() == PlayerState::kStopped, "播完自然结束 → Stopped");
    Check(bounded.CurrentTime() == RationalTime(0, kTs), "结束回到 0（语义单一）");

    // ---- 循环 ----
    PlayerClock looped(RationalTime{kFrameTicks, kTs});
    looped.SetDuration(RationalTime{6000, kTs});
    looped.SetLoop(true);
    looped.Play();
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    looped.Tick();
    Check(looped.State() == PlayerState::kPlaying, "loop 模式：到边界后仍在播放");
    Check(Seconds(looped.CurrentTime()) < 0.2, "loop 模式：回绕到接近 0");

    // ---- 停止 ----
    looped.Stop();
    Check(looped.State() == PlayerState::kStopped, "Stop 后 Stopped");
    Check(looped.CurrentTime() == RationalTime(0, kTs), "Stop 后时刻归 0");
    Check(looped.Tick().IsOk(), "非播放态 Tick 是 no-op");

    // ---- 参数校验 ----
    PlayerClock c2(RationalTime{kFrameTicks, kTs});
    Check(c2.SetDuration(RationalTime{1, 0}).IsError(), "非法 timescale 拒绝");
    Check(c2.Seek(RationalTime{1, 0}).IsError(), "Seek 非法 timescale 拒绝");
    // 未设边界时 Tick 不误停
    c2.Play();
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    Check(c2.Tick().IsOk() && c2.IsPlaying(), "未设边界：Tick 不停止");

    printf("== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
