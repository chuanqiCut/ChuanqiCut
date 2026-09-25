// ChuanqiCut — 分级日志与帧级 trace 实现（CORE-003）
//
// 设计要点见同目录头文件 log.h 的注释。要点重申：
//   * 全局最低级别过滤 + 可注入 sink（FileLogSink 默认落 stderr）。
//   * 帧级 trace 用 RationalTime pts 作帧标识，前缀 [stage][pts=...]。
//   * 日志写入由 Logger 统一加锁串行化，避免多线程交错打乱行。
//   * Trace 在 Release 下的编译期剔除由 CQ_LOG_TRACE / CQ_LOG_FRAME 宏负责，
//     本文件中的 LogImpl / LogFrameImpl 在 Release 仍被编译（外部链接、可被测试
//     或平台代码直接调用），但宏层不会把调用点编进去。

#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

#include "cq/base/log.h"

namespace cq {

const char* PipelineStageName(PipelineStage stage) {
    switch (stage) {
        case PipelineStage::kDemux:  return "demux";
        case PipelineStage::kDecode:  return "decode";
        case PipelineStage::kRender:  return "render";
        case PipelineStage::kEncode:  return "encode";
    }
    return "?";
}

const char* LogLevelName(LogLevel level) {
    switch (level) {
        case LogLevel::kTrace:  return "TRACE";
        case LogLevel::kDebug:  return "DEBUG";
        case LogLevel::kInfo:   return "INFO";
        case LogLevel::kWarn:   return "WARN";
        case LogLevel::kError:  return "ERROR";
    }
    return "?";
}

// ---------------------------------------------------------------------------
// FileLogSink：默认 FILE* 后端（可落盘，不接管文件所有权）
// ---------------------------------------------------------------------------
FileLogSink::FileLogSink(FILE* out) : out_(out) {}

FileLogSink::~FileLogSink() = default;

void FileLogSink::SetFile(FILE* out) { out_.store(out, std::memory_order_relaxed); }

void FileLogSink::Emit(LogLevel level, const char* file, int line, const char* message) {
    FILE* out = out_.load(std::memory_order_relaxed);
    if (out == nullptr) return;
    // 单行格式：LEVEL [file:line] message\n
    // file 可能为 nullptr（发布构建裁掉调用点时仍可能传入，这里兜底）。
    if (file != nullptr && line > 0) {
        std::fprintf(out, "%s [%s:%d] %s\n",
                     LogLevelName(level), file, static_cast<int>(line), message);
    } else {
        std::fprintf(out, "%s %s\n", LogLevelName(level), message);
    }
    // 落盘场景（FILE 是普通文件而非 stderr）需要刷盘才不丢日志；
    // 这里仅对 stderr 之外的目标 fflush，避免每帧强制刷 stderr 影响性能。
    if (out != stderr) {
        std::fflush(out);
    }
}

// ---------------------------------------------------------------------------
// Logger：进程内单例。最低级别 + sink 指针 + 串行化写入。
// ---------------------------------------------------------------------------
namespace {

class Logger {
public:
    static Logger& Instance() {
        static Logger l;
        return l;
    }

    void SetMinLevel(LogLevel level) {
        min_level_.store(level, std::memory_order_relaxed);
    }

    LogLevel MinLevel() const {
        return min_level_.load(std::memory_order_relaxed);
    }

    void SetSink(ILogSink* sink) {
        std::lock_guard<std::mutex> g(mu_);
        sink_ = sink;
    }

    void Emit(LogLevel level, const char* file, int line, const char* message) {
        std::lock_guard<std::mutex> g(mu_);
        if (sink_ != nullptr) {
            sink_->Emit(level, file, line, message);
        }
    }

private:
    Logger() : sink_(&default_sink_), min_level_(LogLevel::kInfo) {
        // 默认 sink 指向 stderr；调用方可用 SetLogSink 注入平台实现，
        // 或用 FileLogSink::SetFile 指向磁盘文件落盘。
        default_sink_.SetFile(stderr);
    }

    std::mutex mu_;                 // 保护 sink_ 指针切换 + 写入串行化
    ILogSink* sink_ = nullptr;      // 不接管所有权
    std::atomic<LogLevel> min_level_;
    FileLogSink default_sink_;      // 默认 stderr 后端
};

// 格式化辅助：把变参格式化进定长缓冲，返回截断后的 C 串。
// 返回指向 buf 的指针（调用方不应长期持有）。
const char* FormatVa(char* buf, std::size_t buf_size, const char* fmt, std::va_list ap) {
    int n = std::vsnprintf(buf, buf_size, fmt, ap);
    (void)n;  // 超长部分被 vsnprintf 截断，不视为错误。
    return buf;
}

}  // namespace

// ---------------------------------------------------------------------------
// 全局控制函数
// ---------------------------------------------------------------------------
void SetLogLevel(LogLevel level) { Logger::Instance().SetMinLevel(level); }

LogLevel GetLogLevel() { return Logger::Instance().MinLevel(); }

void SetLogSink(ILogSink* sink) { Logger::Instance().SetSink(sink); }

// ---------------------------------------------------------------------------
// 核心日志函数
// ---------------------------------------------------------------------------
void LogImpl(LogLevel level, const char* file, int line, const char* fmt, ...) {
    Logger& logger = Logger::Instance();
    // 运行时最低级别过滤（Trace 的编译期剔除另由宏负责）。
    if (static_cast<int32_t>(level) < static_cast<int32_t>(logger.MinLevel())) {
        return;
    }
    std::va_list ap;
    va_start(ap, fmt);
    char buf[1024];
    const char* msg = FormatVa(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    logger.Emit(level, file, line, msg);
}

void LogFrameImpl(PipelineStage stage, const RationalTime& pts, const char* file, int line,
                  const char* fmt, ...) {
    Logger& logger = Logger::Instance();
    // 帧级 trace 固定为 Trace 级别：受最低级别过滤 + Release 编译剔除双重控制。
    if (static_cast<int32_t>(LogLevel::kTrace) < static_cast<int32_t>(logger.MinLevel())) {
        return;
    }
    std::va_list ap;
    va_start(ap, fmt);
    char msg[1024];
    const char* user = FormatVa(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    // 前缀：[stage][pts=value/timescale(秒)]，帧标识用有理数（显示秒仅辅助）。
    char framed[1024 + 64];
    int n = std::snprintf(framed, sizeof(framed),
                          "[%s][pts=%lld/%d(%.4fs)] %s",
                          PipelineStageName(stage),
                          static_cast<long long>(pts.value),
                          static_cast<int>(pts.timescale),
                          pts.ToSeconds(),
                          user);
    (void)n;
    logger.Emit(LogLevel::kTrace, file, line, framed);
}

}  // namespace cq
