// ChuanqiCut — 日志与帧级 trace 单测（CORE-003）
//
// 覆盖：级别过滤、sink 注入、帧级 trace 用 RationalTime pts 标识、默认 sink 不崩。

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "cq/base/log.h"
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

// 捕获型 sink：把每次 Emit 的内容记录下来，供断言。
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

// 计数型 sink：只数各级别条数，用于验证过滤。
class CountingSink : public cq::ILogSink {
public:
    void Emit(cq::LogLevel level, const char* /*file*/, int /*line*/,
              const char* /*message*/) override {
        counts[static_cast<int>(level)]++;
    }
    int counts[5] = {0, 0, 0, 0, 0};  // 对应 kTrace..kError
};

// 恢复全局状态，避免用例互相影响。
void ResetGlobal() {
    cq::SetLogSink(nullptr);
    cq::SetLogLevel(cq::LogLevel::kInfo);
}

void TestLevelFiltering() {
    std::printf("[test] 级别过滤（低于最低级别被丢弃）\n");
    ResetGlobal();
    CountingSink sink;
    cq::SetLogSink(&sink);
    cq::SetLogLevel(cq::LogLevel::kWarn);  // 只保留 Warn / Error

    CQ_LOG_TRACE("t");
    CQ_LOG_DEBUG("d");
    CQ_LOG_INFO("i");
    CQ_LOG_WARN("w");
    CQ_LOG_ERROR("e");

    Check(sink.counts[static_cast<int>(cq::LogLevel::kTrace)] == 0, "Trace 被过滤");
    Check(sink.counts[static_cast<int>(cq::LogLevel::kDebug)] == 0, "Debug 被过滤");
    Check(sink.counts[static_cast<int>(cq::LogLevel::kInfo)] == 0, "Info 被过滤");
    Check(sink.counts[static_cast<int>(cq::LogLevel::kWarn)] == 1, "Warn 透传");
    Check(sink.counts[static_cast<int>(cq::LogLevel::kError)] == 1, "Error 透传");

    // 提高到 Trace，全部应透传。
    // ⚠️ 同 TestFrameTrace：Release（NDEBUG）下 CQ_LOG_TRACE 由宏层编译期剔除，
    //    Trace 计数恒为 0，故按构建类型分别断言。
    cq::SetLogLevel(cq::LogLevel::kTrace);
    CQ_LOG_TRACE("t2");
    CQ_LOG_DEBUG("d2");
    CQ_LOG_INFO("i2");
#ifdef NDEBUG
    Check(sink.counts[static_cast<int>(cq::LogLevel::kTrace)] == 0,
          "Release 下 Trace 被编译期剔除（零开销）");
#else
    Check(sink.counts[static_cast<int>(cq::LogLevel::kTrace)] == 1, "Trace 在最低级别=kTrace 时透传");
#endif
    Check(sink.counts[static_cast<int>(cq::LogLevel::kDebug)] == 1, "Debug 透传");
    Check(sink.counts[static_cast<int>(cq::LogLevel::kInfo)] == 1, "Info 透传");
    ResetGlobal();
}

void TestSinkInjection() {
    std::printf("[test] Sink 可注入（不直接写 stdout/stderr）\n");
    ResetGlobal();
    CapturingSink sink;
    cq::SetLogSink(&sink);
    cq::SetLogLevel(cq::LogLevel::kTrace);

    CQ_LOG_INFO("hello %d", 42);
    Check(sink.records.size() == 1, "捕获到 1 条");
    if (!sink.records.empty()) {
        Check(sink.records[0].level == cq::LogLevel::kInfo, "级别为 Info");
        Check(std::strcmp(sink.records[0].message.c_str(), "hello 42") == 0, "消息内容正确");
    }

    // nullptr sink = 静默，不崩、不抛。
    cq::SetLogSink(nullptr);
    CQ_LOG_ERROR("discarded");
    Check(sink.records.size() == 1, "静默后无新记录");
    ResetGlobal();
}

void TestFrameTrace() {
    std::printf("[test] 帧级 trace：用 RationalTime pts 标识帧\n");
    ResetGlobal();
    CapturingSink sink;
    cq::SetLogSink(&sink);
    cq::SetLogLevel(cq::LogLevel::kTrace);

    // 第 100 帧，timescale 取项目统一值（ADR-0009：120000）。
    cq::RationalTime pts(100 * 1000, cq::kProjectTimeScale);
    CQ_LOG_FRAME(cq::PipelineStage::kDecode, pts, "got frame, size=%d", 1920 * 1080);

// ⚠️ Release（NDEBUG）下 CQ_LOG_FRAME 由宏层编译期剔除（CORE-003 设计意图：
//    发布产物零开销）。因此这里**不能无条件断言"捕获到 N 条"**——records 会是空的，
//    而下面若继续访问 records[1]/records[2] 就是越界访问 → SEGFAULT。
//    2026-09-26 实测：Release 构建下 core_log 因此崩溃，而 Debug 完全看不出来。
//    故按构建类型分别断言：Debug 验"有记录且内容正确"，
//    Release 验"零开销（无记录）"——后者同样是在验证设计意图，不是跳过测试。
#ifdef NDEBUG
    Check(sink.records.empty(), "Release 下帧级 trace 被编译期剔除（零开销）");
#else
    Check(sink.records.size() == 1, "捕获到 1 条帧 trace");
    if (!sink.records.empty()) {
        Check(sink.records[0].level == cq::LogLevel::kTrace, "帧 trace 级别为 Trace");
        const std::string& m = sink.records[0].message;
        // 前缀应含阶段名 decode 与 pts 有理数 value/timescale。
        // 期望串随 kProjectTimeScale 生成，避免常量再次变更时断言硬编码失效
        // （ADR-0006 的 60000 → ADR-0009 的 120000 就踩过一次）。
        const std::string want_pts =
            "pts=100000/" + std::to_string(cq::kProjectTimeScale);
        Check(m.find("[decode]") != std::string::npos, "含阶段 decode");
        Check(m.find(want_pts) != std::string::npos,
              ("含 pts 有理数标识(" + want_pts + ")").c_str());
        Check(m.find("got frame, size=2073600") != std::string::npos, "含用户消息与参数");
    }
#endif

    // demux 与 encode 不同阶段应能区分。
    cq::RationalTime pts2(50000, cq::kProjectTimeScale);
    CQ_LOG_FRAME(cq::PipelineStage::kDemux, pts2, "packet in");
    CQ_LOG_FRAME(cq::PipelineStage::kEncode, pts2, "packet out");
#ifdef NDEBUG
    Check(sink.records.empty(), "Release 下仍无记录（零开销）");
#else
    Check(sink.records.size() == 3, "共 3 条帧 trace");
    Check(sink.records[1].message.find("[demux]") != std::string::npos, "第二帧为 demux");
    Check(sink.records[2].message.find("[encode]") != std::string::npos, "第三帧为 encode");
#endif
    ResetGlobal();
}

// 验证 LogFrameImpl 直接用 RationalTime（非 int64/double），编译期已保证类型正确。
void TestFrameTagIsRationalTime() {
    std::printf("[test] 帧标识类型为 RationalTime（非裸 int64/double）\n");
    // 若有人想改成 int64 帧号或 double 秒，下面函数签名不匹配会编译失败——
    // 此处仅确保可调用，证明接口以 RationalTime 为帧标识。
    CapturingSink sink;
    cq::SetLogSink(&sink);
    cq::SetLogLevel(cq::LogLevel::kTrace);
    cq::RationalTime pts(12345, 60000);
    CQ_LOG_FRAME(cq::PipelineStage::kRender, pts, "render ok");
#ifdef NDEBUG
    Check(sink.records.empty(), "Release 下剔除（零开销），调用仍合法");
#else
    Check(sink.records.size() == 1, "RationalTime 帧标识可正常调用");
#endif
    ResetGlobal();
}

void TestNames() {
    std::printf("[test] 级别/阶段名可读\n");
    Check(std::strcmp(cq::LogLevelName(cq::LogLevel::kError), "ERROR") == 0, "Error 名");
    Check(std::strcmp(cq::LogLevelName(cq::LogLevel::kTrace), "TRACE") == 0, "Trace 名");
    Check(std::strcmp(cq::PipelineStageName(cq::PipelineStage::kDecode), "decode") == 0, "decode 名");
    Check(std::strcmp(cq::PipelineStageName(cq::PipelineStage::kEncode), "encode") == 0, "encode 名");
}

}  // namespace

int main() {
    std::printf("== ChuanqiCut core_log 单测 ==\n");
    TestLevelFiltering();
    TestSinkInjection();
    TestFrameTrace();
    TestFrameTagIsRationalTime();
    TestNames();

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
