// ChuanqiCut — 分级日志与帧级 trace（CORE-003）
//
// 设计目标：
//   1. 分级日志：Error / Warn / Info / Debug / Trace。
//      Trace 是「最详细」级别，在 Release（NDEBUG）构建下由宏层**编译期完全剔除**，
//      发布产物零开销、零代码（见文件末尾 CQ_LOG_TRACE / CQ_LOG_FRAME 宏）。
//   2. 帧级 trace（本项目核心能力，不是普通日志）：媒体管线必须能按
//      「哪一帧（pts，用 RationalTime 表示，禁止裸 int64 / double 秒）、哪个环节
//      （demux / decode / render / encode）」追溯。帧标识一律走已冻结的
//      `RationalTime`（CORE-001），与项目「时间一律有理数」红线一致。
//   3. 输出路径可注入（sink 抽象）：绝不直接写 stdout/stderr。PAL 层（CORE-006）
//      将来提供平台实现（iOS -> os_log、Android -> logcat）。本模块只定义
//      `ILogSink` 接口 + 一个默认 `FileLogSink`（写入 FILE*，可指向磁盘文件落盘）。
//      **不实现任何平台特后端**。
//
// 红线（AGENTS.root.md）：
//   * 头文件零平台类型：本文件只使用 C/C++ 基础类型、std::atomic、const char*，
//     绝不出现 Apple/Android/鸿蒙类型或 os_log/logcat API。
//   * 时间用 RationalTime；帧标识不得用 double 秒。
//
// 线程与阻塞约定（非缺陷，是设计边界，见 ARCH-001 §6）：
//   * 日志账本（最低级别、sink 指针）的查询/设置是线程安全的。
//   * `Emit` 内部会做格式化与写入，可能短暂阻塞——因此**媒体/音频实时线程
//     （音频线程要求无锁、无分配）不应在热路径调用日志**。日志用于管线阶段、
//     生命周期、错误等可容忍延迟的点。本期不要求异步日志实现。

#ifndef CQ_BASE_LOG_H_
#define CQ_BASE_LOG_H_

#include <atomic>
#include <cstdint>

#include "cq/base/status.h"
#include "cq/base/time.h"

namespace cq {

// 日志级别。数值越小越详细（kTrace 最详细）。
enum class LogLevel : int32_t {
    kTrace = 0,  // 最详细：帧级 trace、内部循环、逐帧事件
    kDebug = 1,  // 调试：管线阶段切换、关键分支、状态机迁移
    kInfo = 2,   // 信息：生命周期、用户可见事件、初始化完成
    kWarn = 3,   // 警告：可恢复的异常、降级发生
    kError = 4,  // 错误：失败，但流程可继续推进
};

// 媒体管线阶段（帧级 trace 的「哪个环节」维度）。
enum class PipelineStage : int32_t {
    kDemux = 0,   // 解封装
    kDecode = 1,  // 解码
    kRender = 2,  // 渲染
    kEncode = 3,  // 编码
};

// 返回阶段的可读名（静态存储，调用方无需释放）。仅用于日志展示。
const char* PipelineStageName(PipelineStage stage);

// 返回级别的可读名（静态存储，调用方无需释放）。仅用于日志展示。
const char* LogLevelName(LogLevel level);

// ---- Sink 抽象（输出路径可注入）----
// 一条已经格式化好的消息通过 Emit 交给具体后端。PAL 层将来实现此接口
// （os_log / logcat），本模块只提供默认 FILE* 实现。
class ILogSink {
public:
    virtual ~ILogSink() = default;

    // level：消息级别；file/line：调用点（发布构建可能裁掉，可为 nullptr/0）；
    // message：已格式化好的 UTF-8 文本（不含末尾换行，由后端决定）。
    virtual void Emit(LogLevel level, const char* file, int line, const char* message) = 0;
};

// 默认 sink：写入一个 FILE*（默认 stderr）。可通过 SetFile 指向磁盘文件以落盘。
// 注意：**不接管 FILE* 的所有权**——调用方负责打开与关闭文件；典型用法是在进程
// 启动时 SetFile(fopen(...))，进程退出前 fclose。
//
// 线程安全：out_ 用 std::atomic<FILE*> 保护，Emit 期间读取稳定；SetFile 在日志
// 开始前调用即可。写入本身的串行化由 Logger（log.cpp）的互斥锁统一完成，因此本
// sink 内部无需再加锁。
class FileLogSink : public ILogSink {
public:
    explicit FileLogSink(FILE* out = stderr);
    ~FileLogSink() override;

    void Emit(LogLevel level, const char* file, int line, const char* message) override;

    // 指向磁盘文件以落盘（不接管所有权）。建议在日志启动前调用一次。
    void SetFile(FILE* out);

private:
    std::atomic<FILE*> out_;
};

// ---- 全局日志控制（线程安全）----
void SetLogLevel(LogLevel level);
LogLevel GetLogLevel();

// 设置全局 sink（注入点）。传 nullptr 表示全部丢弃（静默模式）。
// 不接管 sink 所有权；调用方负责其生命周期，且在其析构前应先 SetLogSink(nullptr)。
void SetLogSink(ILogSink* sink);

// ---- 核心日志函数（供宏与程序调用）----
// 低于全局最低级别的日志会被运行时丢弃；Trace 在 Release 下的编译期剔除由宏负责。
// fmt 为 printf 风格格式串；其余为可变参数。内部用 vsnprintf 格式化到定长缓冲，
// 超长部分截断（不分配堆内存，保证热路径安全）。
void LogImpl(LogLevel level, const char* file, int line, const char* fmt, ...);

// 帧级 trace：按「阶段 + pts（RationalTime）」追溯媒体管线。这是本项目核心能力。
// pts 用有理数时间标识帧；message 前缀会自动加上 [stage][pts=value/timescale(秒)]。
// 在 Release（NDEBUG）下由 CQ_LOG_FRAME 宏编译期剔除。
void LogFrameImpl(PipelineStage stage, const RationalTime& pts, const char* file, int line,
                  const char* fmt, ...);

}  // namespace cq

// ============================================================================
// 便捷宏（推荐业务代码使用）
//   * CQ_LOG_TRACE / CQ_LOG_FRAME 在 Release（NDEBUG）下编译为空，发布产物零开销。
//   * 其余级别始终可用（运行时按最低级别过滤）。
//   * file/line 由编译器自动填入，无需手传。
// ============================================================================
#ifdef NDEBUG
// Release：Trace 与帧级 trace 完全编译掉（连格式化参数都不求值）。
#define CQ_LOG_TRACE(...)   do {} while (0)
#define CQ_LOG_FRAME(...)   do {} while (0)
#else
#define CQ_LOG_TRACE(...) \
    ::cq::LogImpl(::cq::LogLevel::kTrace, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_FRAME(stage, pts, ...) \
    ::cq::LogFrameImpl(stage, pts, __FILE__, __LINE__, __VA_ARGS__)
#endif

#define CQ_LOG_ERROR(...) \
    ::cq::LogImpl(::cq::LogLevel::kError, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_WARN(...) \
    ::cq::LogImpl(::cq::LogLevel::kWarn, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_INFO(...) \
    ::cq::LogImpl(::cq::LogLevel::kInfo, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_DEBUG(...) \
    ::cq::LogImpl(::cq::LogLevel::kDebug, __FILE__, __LINE__, __VA_ARGS__)

#endif  // CQ_BASE_LOG_H_
