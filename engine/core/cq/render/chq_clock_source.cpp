// ChuanqiCut — 渲染时钟源实现（RENDER-001 / B0）

#include "cq/render/chq_clock_source.h"

namespace cq {

ChqSteppedClock::ChqSteppedClock(const ChqRationalTime& start, const ChqRationalTime& frame_duration,
                                 const ChqRationalTime& end)
    : start_(start), frame_duration_(frame_duration), end_(end) {}

ChqStatus ChqSteppedClock::Now(ChqRationalTime& out) const {
    out = ChqRationalTime{0, 1};
    if (frame_duration_.IsInvalid() || start_.IsInvalid()) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    // ⚠️ 每次从 start 重新算，**不做逐帧累加**：累加会把「第 n 帧」变成 n 次运算
    // 的累积结果，而重算是单次运算 —— 长视频导出时差别就是漂不漂帧。
    // frame_duration 必须为正（零时长 = 除零语义，非法）。
    if (frame_duration_.value <= 0) return ChqStatus(ChqStatusCode::kInvalidArgument);

    ChqRationalTime offset{0, 1};
    ChqStatus s = ScaleRational(frame_duration_, static_cast<int64_t>(frame_index_), 1, offset);
    if (!s.IsOk()) return s;
    ChqRationalTime t{0, 1};
    s = AddRational(start_, offset, t);
    if (!s.IsOk()) return s;
    out = t;
    return ChqStatus::Ok();
}

ChqStatus ChqSteppedClock::Advance() {
    ChqRationalTime cur{0, 1};
    ChqStatus s = Now(cur);
    if (!s.IsOk()) return s;
    ++frame_index_;
    return ChqStatus::Ok();
}

bool ChqSteppedClock::Exhausted() const {
    ChqRationalTime cur{0, 1};
    if (!Now(cur).IsOk()) return true;
    if (end_.IsInvalid()) return false;  // 无终点（无限序列）
    return CompareRational(cur, end_) >= 0;
}

}  // namespace cq
