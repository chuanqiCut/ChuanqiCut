// ChuanqiCut — 有理数时间（CORE-001）
//
// 设计目标：彻底消除浮点秒带来的帧率漂移（NTSC 帧率 23.976 / 29.97 / 59.94
// 无法被二进制浮点精确表示，长项目累积后掉帧/音画不同步）。
//
// 红线（来自 AGENTS.root.md #4 / ADR-0006）：
//   * 时间一律用 `RationalTime{value, timescale}`，禁止浮点秒。
//   * 项目统一 timescale = 60000（见 `kProjectTimeScale`），可被 24/25/30/60
//     等整除；NTSC 帧率的原生 timescale（如 24000 / 30000）由各素材保留，
//     转换只在边界发生一次（ADR-0006 §1）。
//   * 运算全程有理数（整数），中间不落浮点。
//
// 关键约束（来自 TASK-CORE-001）：
//   * 禁止 `operator double`。唯一的浮点出口是显式 `ToSeconds()`，且**只能用于
//     日志与 UI 展示**，严禁进入任何计算路径（seek / 时长 / 导出）。原因见任务卡
//     risk 段：一旦「为了打印方便」引入隐式 double，三个月后它会渗进导出时长计算。
//   * 加减、比较、取模、缩放（retime 用）全部以有理数完成。
//   * 跨 timescale 运算：以最小公倍数对齐（公共 timescale），**不**静默转换；
//     `Rescale` 非整除时**必须**显式指定舍入方向（Floor / Ceil / Round），
//     不允许默认行为——这对 seek 语义关键。
//   * 约分要约到「公共 timescale」（对齐后的 LCM），**不**要约到最简分数，
//     否则 timescale 可能漂移到 1 之类的奇怪值（如 120000/60000 被约成 2/1）。
//
// 溢出保护：所有运算检测 int64 / int32 溢出，溢出通过 `Status` 返回
// （内核禁用异常，见 ARCH-001；`kOverflow` 码由 CORE-002 定义）。
// `value` 用 int64 是为了支持 >24h 的长项目（溢出边界实测见单测与 baselines.md）。

#ifndef CQ_BASE_TIME_H_
#define CQ_BASE_TIME_H_

#include <cstdint>

#include "cq/base/status.h"

namespace cq {

// 项目统一 timescale = **120000**（ADR-0009，修订 ADR-0006 原定的 60000）。
//
// 为什么不是 60000：60000 不能被 24000 整除（= 2.5），23.976fps（24000/1001）
// 的单帧周期 1001/24000 秒在 60000 网格下为 **2502.5 tick**，非整数，逐帧必须舍入。
// 119.88fps 同理（500.5 tick）。120000 = lcm(60000, 24000)，对 15000 / 24000 /
// 30000 / 60000 / 120000 全部整除，整个 NTSC 家族与常见整数帧率都能用整数 tick 表达。
//
// 注意：这不排斥「素材保留原生 timescale」（ADR-0006 第 33 行仍有效）。
// 改的是**项目时间轴网格**，RationalTime 本身仍可携带任意 timescale。
//
// int64 上限：INT64_MAX / 120000 ≈ 7.69e13 秒 ≈ 243 万年，远超实际需求。
constexpr int32_t kProjectTimeScale = 120000;

// 舍入方向（仅 `Rescale` 跨 timescale 且非整除时需要）。
enum class RoundMode {
    kFloor,  // 向 -∞ 取整（seek 往前对齐常用）
    kCeil,   // 向 +∞ 取整
    kRound,  // 最近取整，平局远离零
};

struct RationalTime {
    int64_t value = 0;       // 以 timescale 为单位的整数刻度数（可为负，表示偏移）
    int32_t timescale = 1;   // 每秒刻度数，必须 > 0

    constexpr RationalTime() = default;
    constexpr RationalTime(int64_t v, int32_t ts) : value(v), timescale(ts) {}

    // timescale > 0 才合法；默认构造 timescale=1 视为合法。
    constexpr bool IsValid() const { return timescale > 0; }

    // 非法哨兵：timescale <= 0 表示运算失败/未初始化。
    constexpr bool IsInvalid() const { return timescale <= 0; }

    // 显式浮点出口：**仅限日志与 UI 展示**。严禁进入计算路径。
    // 内部全程有理数，此函数不参与任何 seek/时长/导出运算。
    double ToSeconds() const {
        if (timescale <= 0) return 0.0;
        return static_cast<double>(value) / static_cast<double>(timescale);
    }
};

// ---- 有理数运算（中间不落浮点，溢出返回 Status）----

// 加法：a + b。结果 timescale = lcm(a.timescale, b.timescale)（公共 timescale）。
Status AddRational(const RationalTime& a, const RationalTime& b, RationalTime& out);

// 减法：a - b。结果 timescale = lcm(a.timescale, b.timescale)。
Status SubRational(const RationalTime& a, const RationalTime& b, RationalTime& out);

// 缩放（retime 用）：t * (num / den)。结果保持有理数：
//   value' = t.value * num，timescale' = t.timescale * den（不约分，保留公共 timescale）。
// num / den 可为负，用于倒放 / 变速曲线。
Status ScaleRational(const RationalTime& t, int64_t num, int64_t den, RationalTime& out);

// 取模：t mod base，返回落在 [0, base) 内的非负余数（欧几里得模）。
// 内部先对齐到公共 timescale，再按整数除法取余。
Status ModRational(const RationalTime& t, const RationalTime& base, RationalTime& out);

// 跨 timescale 重定标：将 t 表示到 target_ts。整除时精确；非整除时**必须**显式
// 指定 `mode`（Floor / Ceil / Round），否则返回 kInvalidArgument。
// 这是 seek 对齐的关键操作——静默默认舍入会导致 seek 偏帧。
Status Rescale(const RationalTime& t, int32_t target_ts, RoundMode mode, RationalTime& out);

// ---- 比较（整数交叉相乘，用 __int128 避免溢出；无任何浮点）----

// 返回：<0 表示 a < b；0 表示 a == b；>0 表示 a > b。
// 要求 a、b 均合法；非法输入视为相等之外——这里对非法直接按值比较（timescale<=0
// 不参与实际管线，仅单测边界使用）。
int CompareRational(const RationalTime& a, const RationalTime& b);

inline bool operator==(const RationalTime& a, const RationalTime& b) {
    return CompareRational(a, b) == 0;
}
inline bool operator!=(const RationalTime& a, const RationalTime& b) {
    return CompareRational(a, b) != 0;
}
inline bool operator<(const RationalTime& a, const RationalTime& b) {
    return CompareRational(a, b) < 0;
}
inline bool operator<=(const RationalTime& a, const RationalTime& b) {
    return CompareRational(a, b) <= 0;
}
inline bool operator>(const RationalTime& a, const RationalTime& b) {
    return CompareRational(a, b) > 0;
}
inline bool operator>=(const RationalTime& a, const RationalTime& b) {
    return CompareRational(a, b) >= 0;
}

}  // namespace cq

#endif  // CQ_BASE_TIME_H_
