// ChuanqiCut — 空间 / 层级 / 变速 / 关键帧数据槽实现（MODEL-004）
//
// 契约见 chq_transform.h。指纹混合原语在本内核里有多份匿名 namespace 副本
// （render_graph / graph_assembler / editor_model_state / property），口径一致、
// 纯函数、无语义可漂移 —— 沿用同一先例，不在这批顺手收敛成公共头（写集纪律，
// 缘由见 chq_property.cpp 文件头）。

#include "cq/model/chq_transform.h"

#include <cmath>
#include <cstring>

namespace cq {
namespace {

constexpr uint64_t kFnvOffset = 14695981039346656037ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

inline void Mix(uint64_t& h, uint64_t v) {
    for (int i = 0; i < 8; ++i) {
        h ^= (v >> (i * 8)) & 0xFFu;
        h *= kFnvPrime;
    }
}

// float → 位模式（memcpy，不做类型双关 —— 那在 -Werror 下是 strict-aliasing 坑）。
// 指纹只读位、不做浮点算术：换编译器浮点开关不该改变 digest。
inline void MixFloat(uint64_t& h, float v) {
    uint32_t bits = 0;
    std::memcpy(&bits, &v, sizeof(bits));
    Mix(h, static_cast<uint64_t>(bits));
}

// 有符号整数进指纹要把符号位单独混进去：`(uint64_t)-1` 与 `(uint64_t)0xFFFFFFFF`
// 混出来的值不同会让同一份数据在两个调用点算出不同 digest（layer 允许为负的历史
// 包袱一旦种下就没人能清）。
inline void MixI64(uint64_t& h, int64_t v) {
    Mix(h, static_cast<uint64_t>(v));
    Mix(h, v < 0 ? 1u : 0u);
}

bool in_range(float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; }

}  // namespace

// ===========================================================================
// ChqTransform
// ===========================================================================

bool ChqTransform::IsIdentity() const {
    // 与默认构造逐字段对照。用 == 而不是 epsilon：恒等是**写入的默认值**，
    // 不是算出来的近似值 —— 允许 epsilon 会让"差一点点"的变换悄悄被当成恒等，
    // 而 RENDER-010 的恒等回归比对正是靠这个判定当安全带。
    return translate_x == 0.0f && translate_y == 0.0f && scale_x == 1.0f && scale_y == 1.0f &&
           rotation_degrees == 0.0f && mirror == ChqMirrorKind::kNone && relative_width == 1.0f &&
           relative_height == 1.0f && opacity == 1.0f;
}

ChqStatus ChqTransform::Validate() const {
    // 缩放/相对尺寸：必须为正且有限。0 会让图层退化成一条线，负值与 mirror 语义重复。
    if (!std::isfinite(scale_x) || !std::isfinite(scale_y) || scale_x <= 0.0f || scale_y <= 0.0f) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    if (!std::isfinite(relative_width) || !std::isfinite(relative_height) ||
        relative_width <= 0.0f || relative_height <= 0.0f) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    // 位移允许任意有限值（可以整体推出画布外，那是"看不见"而不是"非法"），
    // 但不允许 NaN/Inf —— 它们会污染 MVP 矩阵且无法在 UI 上回填。
    if (!std::isfinite(translate_x) || !std::isfinite(translate_y)) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    // 旋转收在 [-360, 360]：超出这个范围的角等价于范围内某个角，存下来只会让
    // "同一画面两种写法"进指纹（720° 与 0° 画面相同但 digest 不同 → 假变化）。
    if (!in_range(rotation_degrees, -360.0f, 360.0f)) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    if (!in_range(opacity, 0.0f, 1.0f)) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    switch (mirror) {
        case ChqMirrorKind::kNone:
        case ChqMirrorKind::kHorizontal:
        case ChqMirrorKind::kVertical:
            break;
        default:
            return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    return ChqStatus::Ok();
}

uint64_t ChqTransform::Fingerprint() const {
    uint64_t h = kFnvOffset;
    MixFloat(h, translate_x);
    MixFloat(h, translate_y);
    MixFloat(h, scale_x);
    MixFloat(h, scale_y);
    MixFloat(h, rotation_degrees);
    Mix(h, static_cast<uint64_t>(mirror));
    MixFloat(h, relative_width);
    MixFloat(h, relative_height);
    MixFloat(h, opacity);
    return h;
}

ChqStatus ChqTransform::RescaleRelativeTo(int32_t old_width, int32_t old_height, int32_t new_width,
                                          int32_t new_height) {
    if (old_width <= 0 || old_height <= 0 || new_width <= 0 || new_height <= 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    if (old_width == new_width && old_height == new_height) return ChqStatus::Ok();

    // 保持像素宽高不变 ⇒ 相对占比按新旧画布尺寸反比缩放。
    // 这里允许浮点：relative_* 是非时间量（同 chq_property.h 的口径），
    // 且修正的是"占比"而不是"时刻"，不参与任何 seek。
    const float w_ratio = static_cast<float>(old_width) / static_cast<float>(new_width);
    const float h_ratio = static_cast<float>(old_height) / static_cast<float>(new_height);
    ChqTransform next = *this;
    next.relative_width *= w_ratio;
    next.relative_height *= h_ratio;
    if (!next.Validate().IsOk()) return ChqStatus(ChqStatusCode::kOverflow);  // 极端口比：结果不可表示
    *this = next;
    return ChqStatus::Ok();
}

// ===========================================================================
// ChqSpeed
// ===========================================================================

ChqStatus ChqSpeed::Validate() const {
    if (numerator <= 0 || denominator <= 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);  // acceptance：speed <= 0 一律拒绝
    }
    return ChqStatus::Ok();
}

ChqStatus ChqSpeed::ApplyTo(const ChqRationalTime& source_duration, ChqRationalTime& out) const {
    ChqStatus s = Validate();
    if (!s.IsOk()) return s;
    if (!source_duration.IsValid() || source_duration.value <= 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    // 时间线占时 = 源时长 / 倍速 = 源时长 * (den / num)。ScaleRational 内部检溢出。
    return ScaleRational(source_duration, denominator, numerator, out);
}

uint64_t ChqSpeed::Fingerprint() const {
    uint64_t h = kFnvOffset;
    MixI64(h, numerator);
    MixI64(h, denominator);
    return h;
}

// ===========================================================================
// ChqKeyframe / ChqKeyframeList
// ===========================================================================

uint64_t ChqKeyframe::Fingerprint() const {
    uint64_t h = kFnvOffset;
    MixI64(h, time.value);
    MixI64(h, time.timescale);
    Mix(h, values.Fingerprint());
    return h;
}

ChqStatus ChqKeyframeList::Set(const ChqRationalTime& time, const ChqPropertyBag& values) {
    // 局部时间里负时刻永远采不到（片段还没开始）—— 留着只是假数据，直接拒。
    if (!time.IsValid() || time.value < 0) return ChqStatus(ChqStatusCode::kInvalidArgument);
    if (values.Size() == 0) {
        // 空袋 = 这一帧什么都不说。留着它既不能展示也不能插值，还会让
        // "这条通道有没有关键帧"变成含糊问题 —— 宁可直接拒绝。
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    for (ChqKeyframe& f : frames_) {
        if (f.time == time) {
            f.values = values;  // 同刻覆盖写（fingerprint 随之变化）
            return ChqStatus::Ok();
        }
    }
    // 升序不变量：插在第一个时刻晚于它的帧之前（属性袋不参与排序，排序只看时刻）。
    auto pos = frames_.begin();
    while (pos != frames_.end() && CompareRational(pos->time, time) < 0) ++pos;
    frames_.insert(pos, ChqKeyframe{time, values});
    return ChqStatus::Ok();
}

ChqStatus ChqKeyframeList::Erase(const ChqRationalTime& time) {
    if (!time.IsValid()) return ChqStatus(ChqStatusCode::kInvalidArgument);
    for (auto it = frames_.begin(); it != frames_.end(); ++it) {
        if (it->time == time) {
            frames_.erase(it);
            return ChqStatus::Ok();
        }
    }
    return ChqStatus(ChqStatusCode::kIoNotFound);  // 如实："没这一帧"不是"参数不对"
}

const ChqKeyframe* ChqKeyframeList::Find(const ChqRationalTime& time) const {
    for (const ChqKeyframe& f : frames_) {
        if (f.time == time) return &f;
    }
    return nullptr;
}

uint64_t ChqKeyframeList::Fingerprint() const {
    uint64_t h = kFnvOffset;
    Mix(h, static_cast<uint64_t>(frames_.size()));
    for (const ChqKeyframe& f : frames_) Mix(h, f.Fingerprint());
    return h;
}

}  // namespace cq
