// ChuanqiCut — RationalTime 实现（CORE-001）
//
// 全程整数运算，无任何浮点中间值。溢出通过 Status 返回（内核禁用异常）。
// 详见同名头文件的设计约束与红线。

#include "cq/base/rational_time.h"

#include <cstdint>

namespace cq {

namespace {

// 有符号最大公约数（Euclidean）。
int64_t Gcd(int64_t a, int64_t b) {
    if (a < 0) a = -a;
    if (b < 0) b = -b;
    while (b != 0) {
        int64_t t = a % b;
        a = b;
        b = t;
    }
    return a;
}

// 检查 x*y 是否落在 int64 范围内；安全则返回 true 并写入 out。
bool MulFits(int64_t x, int64_t y, int64_t& out) {
    __int128 r = static_cast<__int128>(x) * static_cast<__int128>(y);
    if (r < INT64_MIN || r > INT64_MAX) return false;
    out = static_cast<int64_t>(r);
    return true;
}

// 计算两个 timescale 的最小公倍数（int64），并校验能放进 int32。
bool LcmFits(int32_t a, int32_t b, int32_t& out_lcm) {
    int64_t g = Gcd(static_cast<int64_t>(a), static_cast<int64_t>(b));
    int64_t lcm64 = (static_cast<int64_t>(a) / g) * static_cast<int64_t>(b);
    if (lcm64 <= 0 || lcm64 > INT32_MAX) return false;
    out_lcm = static_cast<int32_t>(lcm64);
    return true;
}

}  // namespace

Status AddRational(const RationalTime& a, const RationalTime& b, RationalTime& out) {
    if (!a.IsValid() || !b.IsValid()) return Status(StatusCode::kInvalidArgument);

    int32_t lcm = 0;
    if (!LcmFits(a.timescale, b.timescale, lcm)) return Status(StatusCode::kOverflow);

    const int64_t lcm64 = static_cast<int64_t>(lcm);
    int64_t fa = lcm64 / static_cast<int64_t>(a.timescale);
    int64_t fb = lcm64 / static_cast<int64_t>(b.timescale);

    int64_t av = 0, bv = 0;
    if (!MulFits(a.value, fa, av)) return Status(StatusCode::kOverflow);
    if (!MulFits(b.value, fb, bv)) return Status(StatusCode::kOverflow);

    int64_t sum = 0;
    if (__builtin_add_overflow(av, bv, &sum)) return Status(StatusCode::kOverflow);

    // 结果 timescale = 公共 timescale（不约到最简分数，避免漂移）。
    out = RationalTime(sum, lcm);
    return Status::Ok();
}

Status SubRational(const RationalTime& a, const RationalTime& b, RationalTime& out) {
    if (!a.IsValid() || !b.IsValid()) return Status(StatusCode::kInvalidArgument);

    int32_t lcm = 0;
    if (!LcmFits(a.timescale, b.timescale, lcm)) return Status(StatusCode::kOverflow);

    const int64_t lcm64 = static_cast<int64_t>(lcm);
    int64_t fa = lcm64 / static_cast<int64_t>(a.timescale);
    int64_t fb = lcm64 / static_cast<int64_t>(b.timescale);

    int64_t av = 0, bv = 0;
    if (!MulFits(a.value, fa, av)) return Status(StatusCode::kOverflow);
    if (!MulFits(b.value, fb, bv)) return Status(StatusCode::kOverflow);

    int64_t diff = 0;
    if (__builtin_sub_overflow(av, bv, &diff)) return Status(StatusCode::kOverflow);

    out = RationalTime(diff, lcm);
    return Status::Ok();
}

Status ScaleRational(const RationalTime& t, int64_t num, int64_t den, RationalTime& out) {
    if (!t.IsValid()) return Status(StatusCode::kInvalidArgument);
    if (den == 0) return Status(StatusCode::kInvalidArgument);

    // 把符号归一到 num，使 timescale 恒为正。
    if (den < 0) {
        num = -num;
        den = -den;
    }

    int64_t nv = 0;
    if (!MulFits(t.value, num, nv)) return Status(StatusCode::kOverflow);

    int64_t nts = static_cast<int64_t>(t.timescale) * static_cast<int64_t>(den);
    if (nts <= 0 || nts > INT32_MAX) return Status(StatusCode::kOverflow);

    // value' = value*num, timescale' = timescale*den（保留公共 timescale，不约分）。
    out = RationalTime(nv, static_cast<int32_t>(nts));
    return Status::Ok();
}

Status ModRational(const RationalTime& t, const RationalTime& base, RationalTime& out) {
    if (!t.IsValid() || !base.IsValid()) return Status(StatusCode::kInvalidArgument);
    if (base.value == 0) return Status(StatusCode::kInvalidArgument);

    int32_t lcm = 0;
    if (!LcmFits(t.timescale, base.timescale, lcm)) return Status(StatusCode::kOverflow);

    const int64_t lcm64 = static_cast<int64_t>(lcm);
    int64_t fa = lcm64 / static_cast<int64_t>(t.timescale);
    int64_t fb = lcm64 / static_cast<int64_t>(base.timescale);

    int64_t tv = 0, bv = 0;
    if (!MulFits(t.value, fa, tv)) return Status(StatusCode::kOverflow);
    if (!MulFits(base.value, fb, bv)) return Status(StatusCode::kOverflow);

    // 欧几里得模：余数落在 [0, |base|)。
    int64_t d = bv;
    if (d < 0) d = -d;
    int64_t r = tv % d;
    if (r < 0) r += d;

    out = RationalTime(r, lcm);
    return Status::Ok();
}

Status Rescale(const RationalTime& t, int32_t target_ts, RoundMode mode, RationalTime& out) {
    if (!t.IsValid()) return Status(StatusCode::kInvalidArgument);
    if (target_ts <= 0) return Status(StatusCode::kInvalidArgument);

    if (t.timescale == target_ts) {
        out = t;
        return Status::Ok();
    }

    int64_t num = 0;
    if (!MulFits(t.value, static_cast<int64_t>(target_ts), num)) {
        return Status(StatusCode::kOverflow);
    }

    const int64_t ts = static_cast<int64_t>(t.timescale);
    int64_t q = num / ts;  // 向零截断
    int64_t r = num % ts;  // 符号与 num（即 value）一致

    int64_t result = q;
    bool value_negative = (t.value < 0);
    switch (mode) {
        case RoundMode::kFloor:
            if (r != 0 && value_negative) result = q - 1;
            break;
        case RoundMode::kCeil:
            if (r != 0 && !value_negative) result = q + 1;
            break;
        case RoundMode::kRound: {
            int64_t r_abs = (r < 0) ? -r : r;
            // 最近取整，平局远离零（2*|r| >= ts）。
            bool round_away = (2 * r_abs >= ts);
            if (round_away) {
                result = value_negative ? (q - 1) : (q + 1);
            }
            break;
        }
    }

    out = RationalTime(result, target_ts);
    return Status::Ok();
}

int CompareRational(const RationalTime& a, const RationalTime& b) {
    // 整数交叉相乘，用 __int128 避免乘积溢出 int64（value*timescale 量级可达 ~1e28）。
    __int128 la = static_cast<__int128>(a.value) * static_cast<__int128>(b.timescale);
    __int128 lb = static_cast<__int128>(b.value) * static_cast<__int128>(a.timescale);
    if (la < lb) return -1;
    if (la > lb) return 1;
    return 0;
}

}  // namespace cq
