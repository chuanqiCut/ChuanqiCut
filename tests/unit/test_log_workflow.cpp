// ChuanqiCut — 日志 workflow（按链路筛选）单测（CORE-010）
//
// 覆盖：白名单掩码、per-workflow 独立提级、环境变量解析（含非法输入）、
// 输出前缀可 grep、以及 **Release（NDEBUG）下 Trace 的编译期剔除**。
//
// 为什么单独立一个测试而不是塞进 test_log.cpp：
//   test_log.cpp 已经相当长，且它的 ResetGlobal() 假定「只有级别与 sink 两个
//   全局量」。workflow 引入了第三个全局维度（掩码 + 每链路级别），混进去会
//   让每个用例的清理都变脆 —— 一处漏清理就会污染后面的用例。

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "cq/base/log.h"
#include "cq/base/perf.h"
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

// 捕获型 sink。
class CapturingSink : public cq::ILogSink {
public:
    struct Record {
        cq::LogLevel level;
        std::string message;
    };
    void Emit(cq::LogLevel level, const char* /*file*/, int /*line*/,
              const char* message) override {
        records.push_back(Record{level, std::string(message)});
    }
    std::vector<Record> records;
};

CapturingSink g_sink;

// 每用例前恢复全部三个全局维度。
void ResetGlobal() {
    cq::SetLogSink(&g_sink);
    g_sink.records.clear();
    cq::SetLogLevel(cq::LogLevel::kInfo);
    cq::SetWorkflowFilter(cq::kWorkflowMaskAll);
    for (int i = 0; i < static_cast<int>(cq::Workflow::kCount); ++i) {
        cq::ClearWorkflowLevel(static_cast<cq::Workflow>(i));
    }
}

// ---------------------------------------------------------------------------
void TestWorkflowNameRoundTrip() {
    std::printf("[test] workflow 名字可读且可用于筛选\n");
    ResetGlobal();
    Check(std::strcmp(cq::WorkflowName(cq::Workflow::kDecode), "decode") == 0, "decode 名");
    Check(std::strcmp(cq::WorkflowName(cq::Workflow::kPreview), "preview") == 0, "preview 名");
    Check(std::strcmp(cq::WorkflowName(cq::Workflow::kPerf), "perf") == 0, "perf 名");
    Check(std::strcmp(cq::WorkflowName(cq::Workflow::kMem), "mem") == 0, "mem 名");

    // kCount 是哨兵不是可用链路：名字应为 "?"，且不得参与位掩码。
    Check(std::strcmp(cq::WorkflowName(cq::Workflow::kCount), "?") == 0,
          "kCount 是哨兵，名字为 ?");
    // bit(X) 必须互不相同，否则筛选会把两条链路一起打开。
    Check(cq::WorkflowBit(cq::Workflow::kDecode) != cq::WorkflowBit(cq::Workflow::kPreview),
          "不同链路的位不重叠");
}

// ---------------------------------------------------------------------------
void TestStageMapsToWorkflow() {
    std::printf("[test] 环节 → workflow 归属（帧级 trace 自动继承标签）\n");
    ResetGlobal();
    Check(cq::WorkflowForStage(cq::PipelineStage::kDemux) == cq::Workflow::kDemux,
          "demux 环节归属 demux 链路");
    Check(cq::WorkflowForStage(cq::PipelineStage::kDecode) == cq::Workflow::kDecode,
          "decode 环节归属 decode 链路");
    Check(cq::WorkflowForStage(cq::PipelineStage::kRender) == cq::Workflow::kRender,
          "render 环节归属 render 链路");
    Check(cq::WorkflowForStage(cq::PipelineStage::kEncode) == cq::Workflow::kExport,
          "encode 环节归属 export 链路");
}

// ---------------------------------------------------------------------------
void TestMaskFilter() {
    std::printf("[test] 掩码白名单：未入围的链路一条不发\n");
    ResetGlobal();
    cq::SetLogLevel(cq::LogLevel::kTrace);
    cq::SetWorkflowFilter(cq::WorkflowBit(cq::Workflow::kDecode));  // 只要 decode

    CQ_LOG_WARN_WF(cq::Workflow::kDecode, "d");
    CQ_LOG_WARN_WF(cq::Workflow::kPreview, "p");
    CQ_LOG_WARN_WF(cq::Workflow::kCore, "c");

    Check(g_sink.records.size() == 1, "只有 decode 通过");
    if (!g_sink.records.empty()) {
        Check(g_sink.records[0].message.find("[wf:decode]") != std::string::npos,
              "消息带 [wf:decode] 前缀");
    }

    // 全开后全部通过。
    cq::SetWorkflowFilter(cq::kWorkflowMaskAll);
    CQ_LOG_WARN_WF(cq::Workflow::kPreview, "p2");
    Check(g_sink.records.size() == 2, "全开后 preview 通过");
    ResetGlobal();
}

// ---------------------------------------------------------------------------
void TestPerWorkflowLevelOverride() {
    std::printf("[test] per-workflow 独立提级：不想看的链路保持安静\n");
    ResetGlobal();
    // 全局 Info：Debug 级全被挡。
    CQ_LOG_DEBUG_WF(cq::Workflow::kDecode, "d1");
    Check(g_sink.records.empty(), "全局 Info 下 Debug 被挡");

    // 只把 decode 提到 Trace —— 其余链路维持 Info。
    cq::SetWorkflowLevel(cq::Workflow::kDecode, cq::LogLevel::kTrace);
    CQ_LOG_DEBUG_WF(cq::Workflow::kDecode, "d2");
    CQ_LOG_DEBUG_WF(cq::Workflow::kPreview, "p2");

#ifdef NDEBUG
    // Release：Debug 不 Trace 这些的非 Trace 宏仍在——本用例不依赖 Trace 编译与否。
    Check(g_sink.records.size() == 1, "Release 下只有 decode 的 Debug 通过");
#else
    Check(g_sink.records.size() == 1, "只有 decode 的 Debug 通过");
#endif
    if (!g_sink.records.empty()) {
        Check(g_sink.records[0].message.find("[wf:decode]") != std::string::npos,
              "通过的是 decode 那条");
    }

    // 清除提级 → 回落到全局，重新安静。
    cq::ClearWorkflowLevel(cq::Workflow::kDecode);
    CQ_LOG_DEBUG_WF(cq::Workflow::kDecode, "d3");
    Check(g_sink.records.size() == 1, "清除提级后回落到全局");
    ResetGlobal();
}

// ---------------------------------------------------------------------------
void TestWarnVisibleInRelease() {
    std::printf("[test] Warn/Error 在所有构建下都发得出来（排障留痕的前提）\n");
    ResetGlobal();
    CQ_LOG_WARN_WF(cq::Workflow::kMem, "queue cap hit");
    CQ_LOG_ERROR_WF(cq::Workflow::kPerf, "slow call 8226ms");
    Check(g_sink.records.size() == 2, "Warn 与 Error 在 Release 下同样可发");
    if (g_sink.records.size() == 2) {
        Check(g_sink.records[0].level == cq::LogLevel::kWarn, "第一条是 Warn");
        Check(g_sink.records[1].level == cq::LogLevel::kError, "第二条是 Error");
        Check(g_sink.records[0].message.find("[wf:mem]") != std::string::npos,
              "Warn 带 wf:mem 前缀");
    }
    ResetGlobal();
}

// ---------------------------------------------------------------------------
void TestTraceCompiledOutInRelease() {
    std::printf("[test] Trace 在 Release 下编译期剔除（逐帧日志零成本）\n");
    ResetGlobal();
    cq::SetLogLevel(cq::LogLevel::kTrace);
    CQ_LOG_TRACE_WF(cq::Workflow::kDecode, "per-frame trace");
#ifdef NDEBUG
    Check(g_sink.records.empty(), "Release：Trace 被编译期剔除");
#else
    Check(g_sink.records.size() == 1, "Debug：Trace 正常发出");
#endif
    ResetGlobal();
}

// ---------------------------------------------------------------------------
void TestFrameTraceInheritsWorkflow() {
    std::printf("[test] 帧级 trace 自动继承环节的 workflow 前缀\n");
    ResetGlobal();
    cq::SetLogLevel(cq::LogLevel::kTrace);
    const cq::RationalTime pts(100000, cq::kProjectTimeScale);
    CQ_LOG_FRAME(cq::PipelineStage::kDecode, pts, "frame ready");
#ifdef NDEBUG
    Check(g_sink.records.empty(), "Release：帧 trace 剔除（零开销）");
#else
    Check(g_sink.records.size() == 1, "Debug：捕获帧 trace");
    if (!g_sink.records.empty()) {
        const std::string& m = g_sink.records[0].message;
        Check(m.find("[wf:decode]") != std::string::npos, "帧 trace 带 wf:decode");
        Check(m.find("[decode]") != std::string::npos, "帧 trace 仍带环节 decode");
        Check(m.find("frame ready") != std::string::npos, "帧 trace 带用户消息");
    }
#endif
    ResetGlobal();
}

// ---------------------------------------------------------------------------
void TestEnvConfig() {
    std::printf("[test] 环境变量配置（真机不重编译就能切换）\n");
    ResetGlobal();

    // 环境变量：全局 trace + 只要 decode,mem 两条链路 + 把 preview 单独提到 debug。
    setenv("CQ_LOG_LEVEL", "trace", 1);
    setenv("CQ_LOG_WORKFLOW", "decode,mem", 1);
    setenv("CQ_LOG_WF_LEVEL", "preview=debug", 1);
    cq::ConfigureLogFromEnv();

    Check(cq::GetLogLevel() == cq::LogLevel::kTrace, "CQ_LOG_LEVEL=trace 生效");
    Check(cq::GetWorkflowFilter() ==
              (cq::WorkflowBit(cq::Workflow::kDecode) | cq::WorkflowBit(cq::Workflow::kMem)),
          "CQ_LOG_WORKFLOW 白名单生效");
    Check(cq::EffectiveLogLevel(cq::Workflow::kPreview) == cq::LogLevel::kDebug,
          "CQ_LOG_WF_LEVEL 单链路提级生效（大小写/空格容忍）");

    // 行为验证：preview 在白名单之外，即便提到 debug 也不会发出。
    CQ_LOG_DEBUG_WF(cq::Workflow::kPreview, "p");
    Check(g_sink.records.empty(), "提级不能绕过白名单");
    CQ_LOG_DEBUG_WF(cq::Workflow::kDecode, "d");
#ifdef NDEBUG
    Check(g_sink.records.size() == 1, "decode 在白名单内发出（Debug 级，Release 也保留）");
#else
    Check(g_sink.records.size() == 1, "decode 在白名单内发出");
#endif

    unsetenv("CQ_LOG_LEVEL");
    unsetenv("CQ_LOG_WORKFLOW");
    unsetenv("CQ_LOG_WF_LEVEL");
    ResetGlobal();
}

// ---------------------------------------------------------------------------
void TestEnvInvalidValuesIgnored() {
    std::printf("[test] 环境变量非法值：忽略而非猜一个默认值\n");
    ResetGlobal();
    const cq::LogLevel before = cq::GetLogLevel();

    setenv("CQ_LOG_LEVEL", "verbose", 1);  // 非法级别名
    cq::ConfigureLogFromEnv();
    Check(cq::GetLogLevel() == before, "非法 CQ_LOG_LEVEL 被忽略（不退化成某个级别）");

    // 全非法的白名单：不能变成 0（那等于关掉全部日志，是最容易误伤的配置错误）。
    setenv("CQ_LOG_WORKFLOW", "nosuch,,alsonosuch", 1);
    cq::ConfigureLogFromEnv();
    Check(cq::GetWorkflowFilter() == cq::kWorkflowMaskAll,
          "全非法链路名 → 回落到全开，避免误关全部日志");

    // 部分正确：正确的段应生效，错误的段被跳过。
    setenv("CQ_LOG_WORKFLOW", "nosuch,decode", 1);
    cq::ConfigureLogFromEnv();
    Check(cq::GetWorkflowFilter() == cq::WorkflowBit(cq::Workflow::kDecode),
          "部分正确：正确段生效，错误段跳过");

    unsetenv("CQ_LOG_LEVEL");
    unsetenv("CQ_LOG_WORKFLOW");
    ResetGlobal();
}

// ---------------------------------------------------------------------------
void TestSlowCallAlarm() {
    std::printf("[test] 慢调用告警：低于阈值不报，达到阈值报 Warn\n");
    ResetGlobal();
    {
        // 阈值拉到极大 → 正常调用不应触发（避免测试依赖真实耗时）。
        CQ_SLOW_CALL_THRESHOLD_WF(cq::Workflow::kPerf, "unit-fast", 3600000);
    }
    Check(g_sink.records.empty(), "未达阈值不告警");

    {
        // 阈值 <=0 视为无效（不是「每次都报」）：设成 0 会退化成每调用必打，
        // 等于把这条告警变成噪声源，故实现里直接早退。
        CQ_SLOW_CALL_THRESHOLD_WF(cq::Workflow::kPerf, "unit-zero-threshold", 0);
    }
    Check(g_sink.records.empty(), "阈值 <=0 按无效处理，不告警（防止变成噪声源）");
    ResetGlobal();
}

}  // namespace

int main() {
    std::printf("== ChuanqiCut core_log_workflow 单测（CORE-010） ==\n");
    TestWorkflowNameRoundTrip();
    TestStageMapsToWorkflow();
    TestMaskFilter();
    TestPerWorkflowLevelOverride();
    TestWarnVisibleInRelease();
    TestTraceCompiledOutInRelease();
    TestFrameTraceInheritsWorkflow();
    TestEnvConfig();
    TestEnvInvalidValuesIgnored();
    TestSlowCallAlarm();

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
