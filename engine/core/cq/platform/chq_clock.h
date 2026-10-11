// ChuanqiCut — Platform 单调时钟接口（CORE-006）
//
// 职责：提供跨平台单调时钟，并与 ChqRationalTime 同构。
//
// 与 ChqRationalTime 的关系（关键设计取舍）：时钟刻度以「纳秒」表达，
// 即 ChqRationalTime{ value_ns, 1'000'000'000 }。整数有理数，零浮点，可直接与项目
// 时间轴（timescale=120000）做 Rescale 对齐——A/V 同步（MEDIA-030 的 audio master
// clock）无需浮点。NowTicks() 作为热路径轻量出口，但不进入计算语义。
//
// 红线：零平台类型、零 FFmpeg 类型、时间一律 ChqRationalTime。

#ifndef CQ_CORE_PLATFORM_CHQ_CLOCK_H_
#define CQ_CORE_PLATFORM_CHQ_CLOCK_H_

#include "cq/base/chq_status.h"
#include "cq/base/chq_rational_time.h"  // ChqRationalTime
#include "cq/platform/chq_common.h"

namespace cq {

// 单调时钟刻度 = 纳秒，对应 ChqRationalTime 的 timescale。
constexpr int32_t kMonotonicTimeScale = 1'000'000'000;

class ChqIMonotonicClock : public ChqIPlatformResource {
public:
    // 当前单调时间，以纳秒为 timescale 的 ChqRationalTime（value=纳秒）。
    virtual ChqRationalTime Now() = 0;

    // 原始纳秒整数（热路径轻量出口，不进入计算语义；同步计算一律走 Now()）。
    virtual int64_t NowTicks() = 0;
};

// 工厂（由 Platform 平台实现）。返回 ChqPlatformPtr。
ChqStatus CreateMonotonicClock(ChqPlatformPtr<ChqIMonotonicClock>& out_clock);

}  // namespace cq

#endif  // CQ_CORE_PLATFORM_CHQ_CLOCK_H_
