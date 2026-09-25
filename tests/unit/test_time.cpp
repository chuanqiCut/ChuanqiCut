// ChuanqiCut — RationalTime 单测（CORE-001）
//
// 编译期红线守卫：RationalTime 不得隐式转 double（见 TASK-CORE-001 risk 段）。
// 若有人加了 operator double，下面这条 static_assert 会直接编译失败。
#include <cstdint>
#include <cstdio>
#include <string>
#include <type_traits>

#include "cq/base/status.h"
#include "cq/base/time.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (!cond) {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

// 编译期断言：禁止 RationalTime -> double 隐式转换。
static_assert(!std::is_convertible_v<cq::RationalTime, double>,
              "RationalTime must NOT be implicitly convertible to double (CORE-001 red line)");

// 八种帧率：(名称, timescale, 每帧 tick)
struct FrameRate {
    const char* name;
    int32_t ts;
    int64_t frame_ticks;
};

const FrameRate kRates[] = {
    {"24fps",      60000, 2500},   // 60000/24 = 2500，精确
    {"25fps",      60000, 2400},   // 60000/25 = 2400，精确
    {"30fps",      60000, 2000},   // 60000/30 = 2000，精确
    {"50fps",      60000, 1200},   // 60000/50 = 1200，精确
    {"60fps",      60000, 1000},   // 60000/60 = 1000，精确
    {"23.976fps",  24000, 1001},   // NTSC：原生 24000/1001（60000 不整除，见报告）
    {"29.97fps",   30000, 1001},   // NTSC：原生 30000/1001（同任务卡）
    {"59.94fps",   60000, 1001},   // NTSC：60000/1001
};

void TestEightRatesZeroDrift() {
    std::printf("[test] 八种帧率 × 10000 次步进零漂移\n");
    constexpr int kSteps = 10000;

    for (const auto& r : kRates) {
        cq::RationalTime frame(r.frame_ticks, r.ts);
        cq::RationalTime acc(0, r.ts);

        bool all_ok = true;
        for (int i = 0; i < kSteps; ++i) {
            cq::RationalTime tmp;
            cq::Status s = cq::AddRational(acc, frame, tmp);
            if (!s.IsOk()) { all_ok = false; break; }
            acc = tmp;
        }

        // 理论值：fp * 10000，落在原生 timescale。
        cq::RationalTime expected(r.frame_ticks * kSteps, r.ts);
        int64_t drift = acc.value - expected.value;
        bool ts_stable = (acc.timescale == r.ts);

        std::printf("  %-10s ts=%-6d acc.value=%-12lld expected=%-12lld drift=%lld ts_stable=%d\n",
                    r.name, static_cast<int>(r.ts),
                    static_cast<long long>(acc.value),
                    static_cast<long long>(expected.value),
                    static_cast<long long>(drift),
                    static_cast<int>(ts_stable));

        Check(all_ok, "AddRational 在步进过程中未全部成功");
        Check(drift == 0, "八帧率步进漂移必须为 0 tick");
        Check(ts_stable, "步进过程中 timescale 应保持在公共 timescale，不漂移");
        Check(acc == expected, "累加结果与理论值相等");
    }
}

void TestComparisonExact() {
    std::printf("[test] 跨 timescale 比较精确（无浮点）\n");
    // 1/2 与 2/4 应相等；1/3 与 1/2 应不等。
    cq::RationalTime a(1, 2);
    cq::RationalTime b(2, 4);
    cq::RationalTime c(1, 3);
    cq::RationalTime d(1, 2);
    Check(a == b, "1/2 == 2/4");
    Check(a != c, "1/2 != 1/3");
    Check(c < d, "1/3 < 1/2");
    Check(a <= b, "1/2 <= 2/4");
    Check(d >= a, "1/2 >= 1/2");
}

void TestSubtractAndScale() {
    std::printf("[test] 减法与缩放（retime）\n");
    cq::RationalTime x(1000, 60000);
    cq::RationalTime y(250, 60000);
    cq::RationalTime diff;
    cq::Status s = cq::SubRational(x, y, diff);
    Check(s.IsOk() && diff.value == 750 && diff.timescale == 60000, "1000/60000 - 250/60000 = 750/60000");

    // 2x 变速：t * (2/1)
    cq::RationalTime scaled;
    s = cq::ScaleRational(x, 2, 1, scaled);
    Check(s.IsOk() && scaled.value == 2000 && scaled.timescale == 60000, "scale 2x -> 2000/60000");

    // 倒放：t * (-1/1) 应使 value 变负、timescale 仍为正
    cq::RationalTime reversed;
    s = cq::ScaleRational(x, -1, 1, reversed);
    Check(s.IsOk() && reversed.value == -1000 && reversed.timescale == 60000, "reverse -> -1000/60000");

    // 0.5x 慢放：t * (1/2)
    cq::RationalTime slow;
    s = cq::ScaleRational(x, 1, 2, slow);
    Check(s.IsOk() && slow.value == 1000 && slow.timescale == 120000, "scale 0.5x -> 1000/120000");
}

void TestModulo() {
    std::printf("[test] 取模（欧几里得，落在 [0, base)）\n");
    // 1500/60000 mod 1000/60000 = 500/60000
    cq::RationalTime t(1500, 60000);
    cq::RationalTime base(1000, 60000);
    cq::RationalTime rem;
    cq::Status s = cq::ModRational(t, base, rem);
    Check(s.IsOk() && rem.value == 500 && rem.timescale == 60000, "1500 mod 1000 = 500");

    // 负值取模结果非负：(-1500) mod 1000 = 500
    cq::RationalTime neg(-1500, 60000);
    cq::RationalTime rem2;
    s = cq::ModRational(neg, base, rem2);
    Check(s.IsOk() && rem2.value == 500 && rem2.timescale == 60000, "(-1500) mod 1000 = 500 (非负)");
}

void TestRescaleRounding() {
    std::printf("[test] 跨 timescale 舍入方向（23.976 帧周期 1001/24000 -> 60000）\n");
    // 1001/24000 秒 = 2502.5 tick @60000（非整除，必须显式舍入）
    cq::RationalTime period(1001, 24000);

    cq::RationalTime floor_v, ceil_v, round_v;
    cq::Status sf = cq::Rescale(period, 60000, cq::RoundMode::kFloor, floor_v);
    cq::Status sc = cq::Rescale(period, 60000, cq::RoundMode::kCeil, ceil_v);
    cq::Status sr = cq::Rescale(period, 60000, cq::RoundMode::kRound, round_v);
    Check(sf.IsOk() && floor_v.value == 2502, "Floor(2502.5) = 2502");
    Check(sc.IsOk() && ceil_v.value == 2503, "Ceil(2502.5) = 2503");
    Check(sr.IsOk() && round_v.value == 2503, "Round(2502.5 平局远离零) = 2503");

    // 负数 Floor/Ceil 方向正确性：(-1001)/24000 -> 60000 = -2502.5
    cq::RationalTime neg_period(-1001, 24000);
    cq::RationalTime nf, nc;
    cq::Rescale(neg_period, 60000, cq::RoundMode::kFloor, nf);
    cq::Rescale(neg_period, 60000, cq::RoundMode::kCeil, nc);
    Check(nf.value == -2503, "Floor(-2502.5) = -2503");
    Check(nc.value == -2502, "Ceil(-2502.5) = -2502");

    // 若项目 timescale 改用 120000，23.976 可**精确**表示（无舍入）：
    cq::RationalTime exact120k;
    cq::Status se = cq::Rescale(period, 120000, cq::RoundMode::kRound, exact120k);
    Check(se.IsOk() && exact120k.value == 5005,
          "23.976 @120000 精确 = 5005（支持 ADR 修正建议）");
}

// ADR-0009：项目 timescale 由 ADR-0006 的 60000 修正为 120000。
// 本测试同时固化两件事：① 旧网格 60000 确实不精确（历史缺口，勿回退）；
// ② 新网格 120000 对整个 NTSC 家族 + 常见整数帧率全部整数（覆盖度验证）。
void TestProjectTimescaleCoversAllFrameRates() {
    std::printf("[test] ADR-0009：项目 timescale %d 覆盖度验证\n", cq::kProjectTimeScale);

    // ① 历史缺口：60000 不能被 24000 整除 → 23.976 单帧 2502.5 tick，非整数。
    cq::RationalTime period(1001, 24000);
    cq::RationalTime to60k;
    cq::Status s = cq::Rescale(period, 60000, cq::RoundMode::kRound, to60k);
    Check(s.IsOk() && to60k.value == 2503,
          "60000 下 23.976 帧周期只能近似(2503)——证实 ADR-0006 缺口");

    // ② 新网格：120000 = lcm(60000,24000)，下列帧率的单帧周期应全为整数 tick。
    //    {分子, 分母}：周期 = 分母/分子 秒
    struct Rate { const char* name; int64_t num; int64_t den; int64_t expect; };
    const Rate rates[] = {
        {"23.976",  24000, 1001,  5005},   // 120000*1001/24000 = 5*1001
        {"29.97",   30000, 1001,  4004},   // 4*1001
        {"59.94",   60000, 1001,  2002},   // 2*1001
        {"119.88", 120000, 1001,  1001},   // 1*1001
        {"24",         24,    1,  5000},
        {"25",         25,    1,  4800},
        {"30",         30,    1,  4000},
        {"50",         50,    1,  2400},
        {"60",         60,    1,  2000},
        {"120",       120,    1,  1000},
    };
    const int32_t ts = cq::kProjectTimeScale;
    for (const Rate& r : rates) {
        cq::RationalTime p(r.den, static_cast<int32_t>(r.num));
        cq::RationalTime out;
        cq::Status st = cq::Rescale(p, ts, cq::RoundMode::kRound, out);
        // 精确性判据：四舍五入与向下取整结果相同 → 说明本来就是整数，无需舍入
        cq::RationalTime out_floor;
        cq::Status st2 = cq::Rescale(p, ts, cq::RoundMode::kFloor, out_floor);
        std::string msg = std::string(r.name) + "fps 单帧在 " + std::to_string(ts) +
                          " 下为整数 tick (" + std::to_string(r.expect) + ")";
        Check(st.IsOk() && st2.IsOk() && out.value == r.expect && out_floor.value == r.expect,
              msg.c_str());
    }

    // ③ 项目 timescale 必须是 120000（ADR-0009），防止被无意改回 60000。
    Check(cq::kProjectTimeScale == 120000, "项目 timescale == 120000（ADR-0009）");
}

void TestOverflowBoundary() {
    std::printf("[test] 溢出边界核算\n");
    // 理论边界（见 .ai/memory/baselines.md）：
    //   INT64_MAX = 9223372036854775807
    //   项目 timescale = 60000 时，可表示最大时长 = INT64_MAX/60000 秒
    //     ≈ 1.5372e14 s ≈ 4.87e6 年（远超任何项目的 >24h 需求）。
    //   24h 项目 @60000：value = 86400*60000 = 5184000000，远小于 INT64_MAX。
    //   1 年项目 @60000：value = 31536000*60000 = 1892160000000，仍安全。
    constexpr int64_t kDayValue = 86400LL * 60000LL;      // 24h @60000
    constexpr int64_t kYearValue = 31536000LL * 60000LL;  // 1y @60000
    static_assert(kDayValue < INT64_MAX, "24h 项目不应溢出");
    static_assert(kYearValue < INT64_MAX, "1 年项目不应溢出");
    std::printf("  24h @60000 value=%lld, 1y @60000 value=%lld, INT64_MAX=%lld\n",
                static_cast<long long>(kDayValue),
                static_cast<long long>(kYearValue),
                static_cast<long long>(INT64_MAX));

    // 实际溢出检测：INT64_MAX + 1 越过 INT64，必须返回 kOverflow。
    cq::RationalTime big(INT64_MAX, 1);
    cq::RationalTime one(1, 1);
    cq::RationalTime sum;
    cq::Status s = cq::AddRational(big, one, sum);
    Check(s.code == cq::StatusCode::kOverflow, "a+b 越过 INT64 应返回 kOverflow");

    // Rescale 溢出：INT64_MAX * 2 越过 INT64。
    cq::RationalTime huge(INT64_MAX, 1);
    cq::RationalTime rescaled;
    cq::Status s2 = cq::Rescale(huge, 2, cq::RoundMode::kFloor, rescaled);
    Check(s2.code == cq::StatusCode::kOverflow, "value*target_ts 越过 INT64 应返回 kOverflow");

    // 合法大值仍精确：1 年项目 @60000 加 1 天应精确。
    cq::RationalTime y(kYearValue, 60000);
    cq::RationalTime d(kDayValue, 60000);
    cq::RationalTime yd;
    cq::Status s3 = cq::AddRational(y, d, yd);
    Check(s3.IsOk() && yd.value == (kYearValue + kDayValue) && yd.timescale == 60000,
          "1年+1天 @60000 精确相加不溢出");
}

}  // namespace

int main() {
    std::printf("== ChuanqiCut core_time 单测 ==\n");
    TestEightRatesZeroDrift();
    TestComparisonExact();
    TestSubtractAndScale();
    TestModulo();
    TestRescaleRounding();
    TestProjectTimescaleCoversAllFrameRates();
    TestOverflowBoundary();

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
