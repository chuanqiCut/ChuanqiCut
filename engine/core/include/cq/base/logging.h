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
#include <cstdio>  // FILE / stderr：本头文件自洽所需（不能指望调用方替我们 include）

#include "cq/base/status.h"
#include "cq/base/rational_time.h"

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

// ---- Workflow（流程维度）：日志可按「端到端链路」单独筛选 ----
//
// 为什么在 Level（级别）与 PipelineStage（环节）之外还要这一维：
//   级别过滤回答「多详细」，环节回答「帧走到了哪一步」，但**都不回答
//   「我在排查哪条链路」**。典型场景：真机上播放卡死，只想看取帧/解码链路，
//   不想被渲染、模型、命令栈的日志淹没。腾讯视频播放器 SDK 一类的做法就是给
//   每条日志打流程标，用一个开关单独开关某条链路。
//
// 三者正交：一条日志可以同时是「Trace 级别 / decode 环节 / preview 链路」。
//   级别 → 详细程度（纵向）
//   环节 → 帧生命周期位置（纵向，只用于带 pts 的帧级 trace）
//   workflow → 端到端业务链路（横向，用于人肉筛选与单独提级）
//
// 输出格式（便于 grep）：`LEVEL [wf:preview] [file:line] message`
//   筛一条链路：grep '\[wf:decode\]'
//   只看某链路的告警：grep '\[wf:decode\]' | grep WARN
enum class Workflow : int32_t {
    kCore = 0,       // 框架：生命周期、session、C ABI 边界
    kModel,          // 时间线模型、Command、撤销栈
    kImport,         // 素材导入、探测、时长/封面
    kDemux,          // 解封装、seek、读包
    kDecode,         // 解码（VT/MediaCodec 等平台解码器）
    kFrameCache,     // 帧缓存、复用命中、持有与释放
    kPreview,        // 预览泵调度、取帧请求的合并与时效
    kRender,         // 渲染、纹理上传、shader
    kExport,         // 导出：编码与封装
    kCamera,         // 相机采集与特效
    kGfx,            // 图形资源、RenderGraph、设备能力
    kPerf,           // 性能剖面、慢调用告警、Watchdog
    kMem,            // 内存观测：footprint、队列/缓存上界
    kAi,             // 智能成片：EditPlan、特征提取
    kCount,          // **不是可用 workflow**，仅作数量哨兵（不得用于 WorkflowBit）
};

using WorkflowMask = uint32_t;

// 全开掩码（默认）。
constexpr WorkflowMask kWorkflowMaskAll = 0xFFFFFFFFu;

// 单个 workflow 的位。wf 必须 < kCount（越界是调用方错误，未定义行为）。
constexpr WorkflowMask WorkflowBit(Workflow wf) {
    return static_cast<WorkflowMask>(1u) << static_cast<uint32_t>(wf);
}

// 返回 workflow 的可读名（静态存储，调用方无需释放）。仅用于日志展示。
const char* WorkflowName(Workflow wf);

// 环节 → workflow 的默认归属：让现有帧级 trace（LogFrameImpl）在不改签名的前提下
// 自动继承 workflow 标签。显式传 workflow 的场景请用 CQ_LOG_FRAME_WF。
Workflow WorkflowForStage(PipelineStage stage);

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

// ---- Workflow 筛选与独立提级 ----
//
// 语义（重要）：
//   * **mask = 白名单**。默认 kWorkflowMaskAll（全开）。只想看某几条链路时设
//     `SetWorkflowFilter(WorkflowBit(kDecode) | WorkflowBit(kPreview))`。
//   * **每条日志通过的条件** = ①workflow 在 mask 里，②level >= 该 workflow 的生效最低级别。
//   * **生效最低级别** = 若该 workflow 调过 SetWorkflowLevel 则用它的值，
//     否则回落到全局 GetLogLevel()。也就是**per-workflow 覆盖优先，全局作兜底**。
//     这样可以把一条链路单独提到 Trace 排查，其余保持 Info，避免日志洪水。
void SetWorkflowFilter(WorkflowMask mask);
WorkflowMask GetWorkflowFilter();
bool WorkflowEnabled(Workflow wf);

void SetWorkflowLevel(Workflow wf, LogLevel level);
void ClearWorkflowLevel(Workflow wf);  // 回落全局（= 取消单独提级）
LogLevel EffectiveLogLevel(Workflow wf);

// ---- 从环境变量一次性配置（跨平台，只用 std::getenv）----
//
// 为什么要有这一层：真机/现场排查时重编译一次的成本极高，而「把某条链路提到
// Trace」是最常见的诉求。Xcode Scheme / Android 的 run config / 命令行都能直接
// 加环境变量，无需改代码。
//
//   CQ_LOG_LEVEL    = trace|debug|info|warn|error        （全局兜底级别，非法值忽略）
//   CQ_LOG_WORKFLOW = preview,decode,mem                  （白名单，非法段忽略；不设=全开）
//   CQ_LOG_WF_LEVEL = decode=trace,preview=debug          （per-workflow 提级）
//
// 幂等：可重复调用。线程安全建议在日志开始前调用（与其他 Set* 一致）。
void ConfigureLogFromEnv();

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

// 带 workflow 的日志：在级别之外再打一个链路标，输出前缀为 `[wf:<name>] `。
// 这是「按流程筛选」的基础设施，业务代码请用下方的 CQ_LOG_*_WF 宏。
void LogWorkflowImpl(Workflow wf, LogLevel level, const char* file, int line, const char* fmt, ...);

// 帧级 trace + 显式 workflow（CQ_LOG_FRAME 会自动按环节的归属补 workflow）。
void LogFrameWorkflowImpl(Workflow wf, PipelineStage stage, const RationalTime& pts,
                          const char* file, int line, const char* fmt, ...);

}  // namespace cq

// ============================================================================
// 便捷宏（推荐业务代码使用）
//   * Trace / 帧级 trace（含各自的 _WF 版本）在 Release（NDEBUG）下**编译期剔除**，
//     发布产物零开销。
//   * 其余级别 Debug/Info/Warn/Error **在所有构建下保留**：发布产物不该刷调试细节，
//     但告警与错误必须留下——否则线上出问题无从查起。运行时仍受级别开关控制。
//   * file/line 由编译器自动填入，无需手传。
// ============================================================================
#ifdef NDEBUG
// Release：Trace 与帧级 trace 完全编译掉（连格式化参数都不求值）。
//
// ⚠️ 注意这里**必须显式把参数转成 void 再丢弃**，不能写成 `do {} while (0)`。
//    否则调用点里「只为这个宏而准备的变量」在 Release 下会变成未使用变量，
//    在 -Werror（-Wunused-variable）下**直接把 Release 构建打断**——
//    2026-09-26 实测：test_log.cpp 的 pts/pts2 就因此让 Release 编不过。
//    （Release 是发布必经路径，红了等于发布路径是坏的，且平时 Debug 看不出来。）
//
// ⚠️ 变参部分（__VA_ARGS__）无法逐个 void 掉，这是既有 CQ_LOG_TRACE 就有的限制：
//    若某个变量**只为 Trace 日志而计算**，Release 下它会变成未使用变量。
//    迁移 fprintf 时逐帧日志务必走这条分支，不要临时改用 Debug 绕开。
#define CQ_LOG_TRACE(...)   do { (void)0; } while (0)
#define CQ_LOG_FRAME(stage, pts, ...) \
    do { (void)(stage); (void)(pts); } while (0)
#define CQ_LOG_TRACE_WF(wf, ...)  do { (void)(wf); (void)0; } while (0)
#define CQ_LOG_FRAME_WF(wf, stage, pts, ...) \
    do { (void)(wf); (void)(stage); (void)(pts); } while (0)
#else
#define CQ_LOG_TRACE(...) \
    ::cq::LogImpl(::cq::LogLevel::kTrace, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_FRAME(stage, pts, ...) \
    ::cq::LogFrameImpl(stage, pts, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_TRACE_WF(wf, ...) \
    ::cq::LogWorkflowImpl((wf), ::cq::LogLevel::kTrace, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_FRAME_WF(wf, stage, pts, ...) \
    ::cq::LogFrameWorkflowImpl((wf), (stage), (pts), __FILE__, __LINE__, __VA_ARGS__)
#endif

// ---- 非 Trace 级别：所有构建下保留 ----
// _WF 版本带 workflow 标，优先用它（可按链路筛选）。
//
// 级别选用约定（迁移 fprintf / 新增日志时照此分级）：
//   Trace  → 逐帧、每包、每次进出的高频细节（Release 剔除）。
//   Debug  → 阶段切换、Open/Close、一次性配置结果。
//   Info   → 生命周期里用户可感知的节点（默认级别，默认可见）。
//   Warn   → **降级发生过**：缺Hard解→软解、命中队列/追帧上界、显示序缺口重锚。
//            这类必须留到 Release —— 排查价值最高，且说明「本帧已经不完整」。
//   Error  → 失败但流程可继续。
#define CQ_LOG_ERROR(...) \
    ::cq::LogImpl(::cq::LogLevel::kError, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_WARN(...) \
    ::cq::LogImpl(::cq::LogLevel::kWarn, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_INFO(...) \
    ::cq::LogImpl(::cq::LogLevel::kInfo, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_DEBUG(...) \
    ::cq::LogImpl(::cq::LogLevel::kDebug, __FILE__, __LINE__, __VA_ARGS__)

#define CQ_LOG_DEBUG_WF(wf, ...) \
    ::cq::LogWorkflowImpl((wf), ::cq::LogLevel::kDebug, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_INFO_WF(wf, ...) \
    ::cq::LogWorkflowImpl((wf), ::cq::LogLevel::kInfo, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_WARN_WF(wf, ...) \
    ::cq::LogWorkflowImpl((wf), ::cq::LogLevel::kWarn, __FILE__, __LINE__, __VA_ARGS__)
#define CQ_LOG_ERROR_WF(wf, ...) \
    ::cq::LogWorkflowImpl((wf), ::cq::LogLevel::kError, __FILE__, __LINE__, __VA_ARGS__)

#endif  // CQ_BASE_LOG_H_
