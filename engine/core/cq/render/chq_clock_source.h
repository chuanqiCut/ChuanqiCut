// ChuanqiCut — 渲染时钟源（RENDER-001 / B0 渲染地基）
//
// 为什么要有这一层（RESEARCH-014 §5「时钟源接口」，不是顺手抽象）：
//   同一张 RenderGraph 有两种完全不同的驱动方式，混用会导致「预览对了导出错了」：
//     * 预览 —— **实时（Pull）**：UI/泵请求「现在这一刻」的画面，时钟 = 墙钟的函数。
//       漏掉一帧没关系（下一帧就是新的现在），**绝不能**为了补齐而重渲染历史时刻。
//     * 导出 —— **步进（Push）**：按固定帧时长逐帧推进，一帧都不能漏；时钟是计数器，
//       与墙钟无关（否则导出时长会随机器负载漂移）。
//   把「现在是什么时刻」从渲染器里抽出来，装配器与执行器才能对两种用途**共用同一份
//   图装配代码** —— 这正是红线 #9（预览与导出走同一张 RenderGraph）的可执行形式。
//
// 红线 4：时刻一律 ChqRationalTime，**绝不**出现浮点秒；帧时长由 timescale 网格整除
//   （项目 timescale = 120000，见 ADR-0009）。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常（错误一律 ChqStatus）。

#ifndef CQ_CORE_RENDER_CHQ_CLOCK_SOURCE_H_
#define CQ_CORE_RENDER_CHQ_CLOCK_SOURCE_H_

#include <cstdint>

#include "cq/base/chq_rational_time.h"
#include "cq/base/chq_status.h"

namespace cq {

enum class ChqClockKind : int32_t {
    kRealtime = 0,  // 墙钟驱动（预览）：Now() = 墙钟的函数，Advance() 无意义
    kStepped = 1,   // 步进驱动（导出）：Now() = start + n * frame_duration
};

class ChqIClockSource {
public:
    virtual ~ChqIClockSource() = default;

    virtual ChqClockKind Kind() const = 0;

    // 当前时刻。实时时钟取调用瞬间的墙钟；步进时钟取计数器当前值。
    virtual ChqStatus Now(ChqRationalTime& out) const = 0;

    // 步进时钟推进一帧。实时时钟调用返回 kInvalidArgument ——
    // 这不是调用方写错了参数，而是「语义不匹配」：实时时钟没有「下一帧」的概念。
    // 返回错误而不是静默成功，是为了让「导出误用实时时钟」在第一次调用就炸出来。
    virtual ChqStatus Advance() = 0;

    // 步进时钟是否已走完区间（Now() >= end）。实时时钟恒 false（没有终点）。
    virtual bool Exhausted() const = 0;

    // 已推进的帧数（步进时钟语义；实时时钟返回 0）。
    virtual uint64_t FrameIndex() const = 0;
};

// 步进时钟（导出用途）：固定帧时长从 start 推进到 end。
//
// 为什么单独成类而不是让调用方自己算：
//   导出的「第 n 帧时刻」必须是**整数网格上的精确值**，逐次累加浮点会在长视频上漂移；
//   这里用 start + n * frame_duration 的有理数运算（每次从 start 重新算，不累加），
//   保证第 10000 帧与第 1 帧同精度。
class ChqSteppedClock final : public ChqIClockSource {
public:
    ChqSteppedClock() = default;
    ChqSteppedClock(const ChqRationalTime& start, const ChqRationalTime& frame_duration,
                    const ChqRationalTime& end);

    ChqClockKind Kind() const override { return ChqClockKind::kStepped; }
    ChqStatus Now(ChqRationalTime& out) const override;
    ChqStatus Advance() override;
    bool Exhausted() const override;
    uint64_t FrameIndex() const override { return frame_index_; }

private:
    ChqRationalTime start_{0, 1};
    ChqRationalTime frame_duration_{0, 1};
    ChqRationalTime end_{0, 1};
    uint64_t frame_index_ = 0;
};

}  // namespace cq

#endif  // CQ_CORE_RENDER_CHQ_CLOCK_SOURCE_H_
