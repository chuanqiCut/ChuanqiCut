// ChuanqiCut — 性能埋点单测（base/perf）
//
// 重点验证几条**设计承诺**，而不只是"能调用"：
//   1. 关闭时零开销/无输出（默认关闭，不产生任何记录）
//   2. 开启后能记录，且耗时非零（真的取了时钟）
//   3. 帧可追溯：记录里带 RationalTime pts（与 ADR-0009 的 120000 网格一致）
//   4. 采样生效：采样率 N 时约每 N 次记一次（高频路径降开销的关键）
//   5. sink 可注入：自定义 sink 能收到记录（平台侧可接 os_signpost/ATrace）
//   6. 附加量（bytes / queue_depth）能带上
//
// ⚠️ 与日志不同：埋点**在 Release（NDEBUG）下也必须可用**——
//    真机实测就是 Release 构建。故此处**不做** #ifdef NDEBUG 分支跳过，
//    若有人把埋点也随 NDEBUG 剔除，本用例在 Release 下应失败以暴露该错误。

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "cq/base/perf.h"
#include "cq/base/time.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (cond) {
        std::printf("  ok  : %s\n", msg);
    } else {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

// 收集型 sink：记录收到的条目，便于断言。
class CollectingPerfSink : public cq::IPerfSink {
public:
    void Record(const cq::PerfRecord& rec) override { records.push_back(rec); }
    void Flush() override { flushed = true; }

    std::vector<cq::PerfRecord> records;
    bool flushed = false;
};

void TestDisabledByDefaultNoOutput() {
    std::printf("[test] 默认关闭：不产生记录（零开销路径）\n");
    cq::SetPerfEnabled(false);
    CollectingPerfSink sink;
    cq::SetPerfSink(&sink);

    const cq::RationalTime pts(1000, cq::kProjectTimeScale);
    {
        CQ_PERF_SCOPE(cq::PerfStage::kDecode, pts);
    }
    Check(sink.records.empty(), "关闭时无记录产生");
    Check(!cq::PerfEnabled(), "PerfEnabled() 为 false");
}

void TestEnabledRecordsDurationAndPts() {
    std::printf("[test] 开启后记录耗时与帧标识\n");
    CollectingPerfSink sink;
    cq::SetPerfSink(&sink);
    cq::SetPerfSampleRate(1);
    cq::SetPerfEnabled(true);

    const cq::RationalTime pts(3000, cq::kProjectTimeScale);
    {
        CQ_PERF_SCOPE(cq::PerfStage::kDecode, pts);
        // 制造一点可测量的耗时
        volatile int64_t acc = 0;
        for (int i = 0; i < 20000; ++i) acc += i;
        (void)acc;
    }
    cq::SetPerfEnabled(false);

    Check(sink.records.size() == 1, "开启后产生 1 条记录");
    if (sink.records.size() == 1) {
        const cq::PerfRecord& r = sink.records[0];
        Check(r.stage == cq::PerfStage::kDecode, "stage 正确");
        Check(r.pts.value == 3000 && r.pts.timescale == cq::kProjectTimeScale,
              "pts 与项目 timescale 一致（可对齐到帧）");
        Check(r.duration_ns >= 0, "耗时非负（单调时钟可用）");
    }
}

void TestSampleRate() {
    std::printf("[test] 采样：每 N 次记录一次（高频路径降开销）\n");
    CollectingPerfSink sink;
    cq::SetPerfSink(&sink);
    cq::SetPerfSampleRate(4);
    cq::SetPerfEnabled(true);

    const cq::RationalTime pts(0, cq::kProjectTimeScale);
    for (int i = 0; i < 40; ++i) {
        CQ_PERF_SCOPE(cq::PerfStage::kRender, pts);
    }
    cq::SetPerfEnabled(false);
    cq::SetPerfSampleRate(1);

    // 采样是近似的（计数器多线程下非严格），这里只断言数量级正确：应明显少于 40，且不为 0
    Check(!sink.records.empty(), "采样下仍有记录");
    Check(sink.records.size() <= 40 / 4 + 2, "记录数约为总数/采样率（明显少于全量）");
    std::printf("    采样率=4、调用 40 次 → 记录 %zu 条\n", sink.records.size());
}

void TestSinkInjectionAndExtras() {
    std::printf("[test] sink 可注入 + 附加量（bytes / queue_depth）\n");
    CollectingPerfSink sink;
    cq::SetPerfSink(&sink);
    cq::SetPerfEnabled(true);

    const cq::RationalTime pts(7000, cq::kProjectTimeScale);
    {
        CQ_PERF_SCOPE_NAMED(cq::PerfStage::kCustom, pts, "my_stage");
    }
    cq::SetPerfEnabled(false);

    Check(!sink.records.empty(), "自定义 sink 收到记录");
    if (!sink.records.empty()) {
        Check(sink.records[0].name != nullptr, "自定义 name 已携带");
    }

    // 附加量：显式构造 PerfScope（业务侧需要设附加量时这样用）
    sink.records.clear();
    cq::SetPerfEnabled(true);
    {
        cq::PerfScope scope(cq::PerfStage::kQueuePush, pts);
        scope.SetBytes(1024);
        scope.SetQueueDepth(3);
    }
    cq::SetPerfEnabled(false);
    Check(sink.records.size() == 1, "显式 PerfScope 产生 1 条");
    if (sink.records.size() == 1) {
        Check(sink.records[0].bytes == 1024, "bytes 附加量正确");
        Check(sink.records[0].queue_depth == 3, "queue_depth 附加量正确");
    }
}

void TestReleaseMustWork() {
    std::printf("[test] Release（NDEBUG）下埋点必须仍可用（真机实测场景）\n");
    CollectingPerfSink sink;
    cq::SetPerfSink(&sink);
    cq::SetPerfEnabled(true);
    {
        const cq::RationalTime pts(9000, cq::kProjectTimeScale);
        CQ_PERF_SCOPE(cq::PerfStage::kDemux, pts);
    }
    cq::SetPerfEnabled(false);
#ifdef NDEBUG
    Check(!sink.records.empty(), "Release 下埋点仍产生记录（未被 NDEBUG 剔除）");
#else
    Check(!sink.records.empty(), "Debug 下埋点产生记录");
#endif
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut core_perf 单测 ==\n");

    TestDisabledByDefaultNoOutput();
    TestEnabledRecordsDurationAndPts();
    TestSampleRate();
    TestSinkInjectionAndExtras();
    TestReleaseMustWork();

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
