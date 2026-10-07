// ChuanqiCut — 分级日志与帧级 trace 实现（CORE-003）
//
// 设计要点见同目录头文件 log.h 的注释。要点重申：
//   * 全局最低级别过滤 + 可注入 sink（FileLogSink 默认落 stderr）。
//   * 帧级 trace 用 RationalTime pts 作帧标识，前缀 [stage][pts=...]。
//   * 日志写入由 Logger 统一加锁串行化，避免多线程交错打乱行。
//   * Trace 在 Release 下的编译期剔除由 CQ_LOG_TRACE / CQ_LOG_FRAME 宏负责，
//     本文件中的 LogImpl / LogFrameImpl 在 Release 仍被编译（外部链接、可被测试
//     或平台代码直接调用），但宏层不会把调用点编进去。

#include <cctype>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

#include "cq/base/logging.h"

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

const char* WorkflowName(Workflow wf) {
    switch (wf) {
        case Workflow::kCore:        return "core";
        case Workflow::kModel:       return "model";
        case Workflow::kImport:      return "import";
        case Workflow::kDemux:       return "demux";
        case Workflow::kDecode:      return "decode";
        case Workflow::kFrameCache:  return "framecache";
        case Workflow::kPreview:     return "preview";
        case Workflow::kRender:      return "render";
        case Workflow::kExport:      return "export";
        case Workflow::kCamera:      return "camera";
        case Workflow::kGfx:         return "gfx";
        case Workflow::kPerf:        return "perf";
        case Workflow::kMem:         return "mem";
        case Workflow::kAi:          return "ai";
        case Workflow::kCount:       break;  // 哨兵，不是可用链路
    }
    return "?";
}

// 按名字反查（ConfigureLogFromEnv 用）。查不到返回 false。大小写敏感，
// 名字与 WorkflowName 保持一致（全小写），避免解析与展示两套写法漂移。
// 注：保持内部链接——本 TU 之外不使用（将来若要在 C ABI 暴露解析能力，再挪进头文件）。
static bool WorkflowFromName(const char* name, Workflow* out) {
    if (name == nullptr || out == nullptr) return false;
    const int n = static_cast<int>(Workflow::kCount);
    for (int i = 0; i < n; ++i) {
        Workflow wf = static_cast<Workflow>(i);
        if (std::strcmp(name, WorkflowName(wf)) == 0) {
            *out = wf;
            return true;
        }
    }
    return false;
}

Workflow WorkflowForStage(PipelineStage stage) {
    switch (stage) {
        case PipelineStage::kDemux:   return Workflow::kDemux;
        case PipelineStage::kDecode:  return Workflow::kDecode;
        case PipelineStage::kRender:  return Workflow::kRender;
        case PipelineStage::kEncode:  return Workflow::kExport;
    }
    return Workflow::kCore;  // 兜底，不应发生（枚举扩展漏改时一眼可辨）
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

// Workflow 级别表的「未设置」哨兵值（-1）。
// 用 int32_t 而非 LogLevel 存储，是因为需要一个「无效值」来表达「回落到全局」。
constexpr int32_t kWorkflowLevelUnset = -1;

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

    // ---- Workflow 维度 ----
    void SetWorkflowFilter(WorkflowMask mask) {
        wf_mask_.store(mask, std::memory_order_relaxed);
    }

    WorkflowMask WorkflowMaskValue() const {
        return wf_mask_.load(std::memory_order_relaxed);
    }

    void SetWorkflowLevel(Workflow wf, LogLevel level) {
        if (!ValidWorkflow(wf)) return;  // 越界静默忽略（日志设施本身不得抛/崩）
        wf_level_[Index(wf)].store(static_cast<int32_t>(level), std::memory_order_relaxed);
    }

    void ClearWorkflowLevel(Workflow wf) {
        if (!ValidWorkflow(wf)) return;
        wf_level_[Index(wf)].store(kWorkflowLevelUnset, std::memory_order_relaxed);
    }

    // 生效最低级别：该 workflow 单独提过级就用它的值，否则回落到全局。
    LogLevel EffectiveLevel(Workflow wf) const {
        if (!ValidWorkflow(wf)) return MinLevel();
        int32_t v = wf_level_[Index(wf)].load(std::memory_order_relaxed);
        if (v == kWorkflowLevelUnset) return MinLevel();
        return static_cast<LogLevel>(v);
    }

    // 是否放行。放在格式化**之前**调用——这是热路径的关键：
    // 被过滤的日志不该付出 vsnprintf 的成本。
    bool ShouldEmit(Workflow wf, LogLevel level) const {
        if (!ValidWorkflow(wf)) return false;
        const uint32_t mask = wf_mask_.load(std::memory_order_relaxed);
        if ((mask & WorkflowBit(wf)) == 0u) return false;
        return static_cast<int32_t>(level) >= static_cast<int32_t>(EffectiveLevel(wf));
    }

    static bool ValidWorkflow(Workflow wf) {
        const int32_t i = static_cast<int32_t>(wf);
        return i >= 0 && i < static_cast<int32_t>(Workflow::kCount);
    }

    static int Index(Workflow wf) { return static_cast<int>(wf); }

private:
    Logger() : sink_(&default_sink_), min_level_(LogLevel::kInfo) {
        // 默认 sink 指向 stderr；调用方可用 SetLogSink 注入平台实现，
        // 或用 FileLogSink::SetFile 指向磁盘文件落盘。
        default_sink_.SetFile(stderr);
        // 默认：所有 workflow 开放 + 级别回落到全局。
        for (auto& lv : wf_level_) {
            lv.store(kWorkflowLevelUnset, std::memory_order_relaxed);
        }
    }

    std::mutex mu_;                 // 保护 sink_ 指针切换 + 写入串行化
    ILogSink* sink_ = nullptr;      // 不接管所有权
    std::atomic<LogLevel> min_level_;
    std::atomic<WorkflowMask> wf_mask_{kWorkflowMaskAll};  // workflow 白名单，默认全开
    std::atomic<int32_t> wf_level_[static_cast<int>(Workflow::kCount)];  // -1 = 回落全局
    FileLogSink default_sink_;      // 默认 stderr 后端
};

// 格式化辅助：把变参格式化进定长缓冲，返回截断后的 C 串。
// 返回指向 buf 的指针（调用方不应长期持有）。
// 用全局 ::va_list（<cstdarg> 保证）；旧版 AppleClang 的 libc++ 不提供 std::va_list。
const char* FormatVa(char* buf, std::size_t buf_size, const char* fmt, va_list ap) {
    int n = std::vsnprintf(buf, buf_size, fmt, ap);
    (void)n;  // 超长部分被 vsnprintf 截断，不视为错误。
    return buf;
}

// ---- 带 workflow 的实际发射（va_list 版本）----
//
// 之所以要这一层：**C/C++ 的 `...` 是不能转发的**。LogFrameImpl 要复用
// LogFrameWorkflowImpl 的逻辑，唯一的办法是抽一个收 va_list 的函数。
// （曾写成 `LogFrameWorkflowImpl(stage, pts, file, line, fmt)` 直接转发，
//   那样 fmt 之后的所有实参都会丢掉，是编译能过但结果错的坑。）
void EmitWorkflowVa(Workflow wf, LogLevel level, const char* file, int line, const char* fmt,
                    va_list ap) {
    char buf[1024];
    const char* user = FormatVa(buf, sizeof(buf), fmt, ap);
    // 前缀 [wf:<name>]：既是给人看的，也是 grep 的锚点。
    char tagged[1024 + 32];
    int n = std::snprintf(tagged, sizeof(tagged), "[wf:%s] %s", WorkflowName(wf), user);
    (void)n;
    Logger::Instance().Emit(level, file, line, tagged);
}

void EmitFrameWorkflowVa(Workflow wf, PipelineStage stage, const RationalTime& pts,
                         const char* file, int line, const char* fmt, va_list ap) {
    Logger& logger = Logger::Instance();
    // 帧级 trace 固定为 Trace 级别：受该 workflow 的生效级别过滤；
    // 另外 Trace 调用点在 Release 下会被宏层编译期剔除（见 log.h）。
    if (!logger.ShouldEmit(wf, LogLevel::kTrace)) {
        return;
    }
    char msg[1024];
    const char* user = FormatVa(msg, sizeof(msg), fmt, ap);
    // 前缀：[wf:<name>][stage][pts=value/timescale]，帧标识用有理数（秒仅辅助阅读）。
    char tagged[1024 + 96];
    int n = std::snprintf(tagged, sizeof(tagged),
                          "[wf:%s][%s][pts=%lld/%d(%.4fs)] %s",
                          WorkflowName(wf), PipelineStageName(stage),
                          static_cast<long long>(pts.value),
                          static_cast<int>(pts.timescale),
                          pts.ToSeconds(), user);
    (void)n;
    logger.Emit(LogLevel::kTrace, file, line, tagged);
}

}  // namespace

// ---------------------------------------------------------------------------
// 全局控制函数
// ---------------------------------------------------------------------------
void SetLogLevel(LogLevel level) { Logger::Instance().SetMinLevel(level); }

LogLevel GetLogLevel() { return Logger::Instance().MinLevel(); }

void SetLogSink(ILogSink* sink) { Logger::Instance().SetSink(sink); }

// ---------------------------------------------------------------------------
// Workflow 筛选与独立提级
// ---------------------------------------------------------------------------
void SetWorkflowFilter(WorkflowMask mask) { Logger::Instance().SetWorkflowFilter(mask); }

WorkflowMask GetWorkflowFilter() { return Logger::Instance().WorkflowMaskValue(); }

void SetWorkflowLevel(Workflow wf, LogLevel level) {
    Logger::Instance().SetWorkflowLevel(wf, level);
}

void ClearWorkflowLevel(Workflow wf) { Logger::Instance().ClearWorkflowLevel(wf); }

LogLevel EffectiveLogLevel(Workflow wf) { return Logger::Instance().EffectiveLevel(wf); }

// ---------------------------------------------------------------------------
// 环境变量配置
//
// 真机排查时重编译成本极高，所以这一层是刚需而不是糖。注意：这里**只用
// std::getenv**（标准 C++），不引入任何平台 API —— PAL 将来要做各自的
// 配置源（iOS 的 UserDefaults / Android 的 system property）另行叠加，
// 不得把平台代码塞进 core。
// ---------------------------------------------------------------------------
namespace {

// 大小写无关比较（只用于解析 ASCII 配置键）。
// **刻意不用 strcasecmp**：它是 POSIX 而非标准 C++，会把平台约束带进 base 层。
// 自己写 12 行换跨平台一致性，值。
bool EqualsIgnoreCase(const char* a, const char* b) {
    if (a == nullptr || b == nullptr) return false;
    for (; *a != '\0' && *b != '\0'; ++a, ++b) {
        // 先转 unsigned char 再喂给 tolower：char 为负时直接传 int 是 UB。
        const int ca = std::tolower(static_cast<unsigned char>(*a));
        const int cb = std::tolower(static_cast<unsigned char>(*b));
        if (ca != cb) return false;
    }
    return *a == '\0' && *b == '\0';
}

// 级别字符串 → LogLevel。大小写不敏感（"Debug"/"debug"/"DEBUG" 都行）。
// 非法值返回 false，调用方忽略该配置（不 fallback 到某个"看起来合理"的级别——
// 静默替代会把用户的排查意图改掉）。
bool ParseLogLevel(const char* s, LogLevel* out) {
    if (s == nullptr || out == nullptr || *s == '\0') return false;
    if (EqualsIgnoreCase(s, "trace")) { *out = LogLevel::kTrace; return true; }
    if (EqualsIgnoreCase(s, "debug")) { *out = LogLevel::kDebug; return true; }
    if (EqualsIgnoreCase(s, "info"))  { *out = LogLevel::kInfo;  return true; }
    if (EqualsIgnoreCase(s, "warn"))  { *out = LogLevel::kWarn;  return true; }
    if (EqualsIgnoreCase(s, "error")) { *out = LogLevel::kError; return true; }
    return false;
}

// 去掉首尾空白与可选的单/双引号（环境变量常见脏数据）。
// 返回指向 sv 内部的指针 + 长度（就地裁剪，不分配内存）。
const char* TrimToken(const char* s, std::size_t* len) {
    while (*s == ' ' || *s == '\t' || *s == '\'' || *s == '\"') ++s;
    const char* end = s + std::strlen(s);
    while (end > s) {
        const char c = *(end - 1);
        if (c == ' ' || c == '\t' || c == '\'' || c == '\"' || c == '\r' || c == '\n') {
            --end;
        } else {
            break;
        }
    }
    *len = static_cast<std::size_t>(end - s);
    return s;
}

// 把 "a,b,c" 按逗号切开并对每段回调。空段跳过（"a,,b" 与 "a,b" 等价）。
// func 返回 false 表示该段无法识别（调用方决定是否记一条警告）。
void ForEachToken(const char* s, bool (*func)(const char* token, std::size_t len, void* ctx),
                  void* ctx) {
    if (s == nullptr) return;
    const char* p = s;
    while (*p != '\0') {
        const char* comma = std::strchr(p, ',');
        std::size_t seg_len = (comma != nullptr)
                                  ? static_cast<std::size_t>(comma - p)
                                  : std::strlen(p);
        // 就地裁剪需要一段连续可写存储：复制到定长缓冲（环境变量不会很长）。
        char token[64];
        if (seg_len >= sizeof(token)) seg_len = sizeof(token) - 1;
        std::memcpy(token, p, seg_len);
        token[seg_len] = '\0';

        std::size_t len = 0;
        const char* trimmed = TrimToken(token, &len);
        std::memmove(token, trimmed, len);
        token[len] = '\0';

        if (len > 0) {
            if (!func(token, len, ctx)) {
                // 无法识别的段：跳过，不中断整轮解析。
                LogWorkflowImpl(Workflow::kCore, LogLevel::kWarn, __FILE__, __LINE__,
                                "忽略无法识别的日志配置项：'%s'", token);
            }
        }
        if (comma == nullptr) break;
        p = comma + 1;
    }
}

bool WorkflowTokenFn(const char* token, std::size_t /*len*/, void* ctx) {
    Workflow wf = Workflow::kCore;
    if (!WorkflowFromName(token, &wf)) return false;
    *static_cast<WorkflowMask*>(ctx) |= WorkflowBit(wf);
    return true;
}

bool WfLevelTokenFn(const char* token, std::size_t /*len*/, void* /*ctx*/) {
    const char* eq = std::strchr(token, '=');
    if (eq == nullptr) return false;
    // 拆成 name / level 两段后各自 trim，容忍 " decode = trace " 这类写法。
    char name[64];
    std::size_t name_len = static_cast<std::size_t>(eq - token);
    if (name_len >= sizeof(name)) name_len = sizeof(name) - 1;
    std::memcpy(name, token, name_len);
    name[name_len] = '\0';

    char lvl[32];
    const char* lvl_src = eq + 1;
    std::size_t lvl_len = std::strlen(lvl_src);
    if (lvl_len >= sizeof(lvl)) lvl_len = sizeof(lvl) - 1;
    std::memcpy(lvl, lvl_src, lvl_len);
    lvl[lvl_len] = '\0';

    std::size_t n = 0;
    const char* n00 = TrimToken(name, &n);
    std::memmove(name, n00, n);
    name[n] = '\0';

    std::size_t m = 0;
    const char* m00 = TrimToken(lvl, &m);
    std::memmove(lvl, m00, m);
    lvl[m] = '\0';

    Workflow wf = Workflow::kCore;
    LogLevel level = LogLevel::kInfo;
    if (!WorkflowFromName(name, &wf)) return false;
    if (!ParseLogLevel(lvl, &level)) return false;
    Logger::Instance().SetWorkflowLevel(wf, level);
    return true;
}

}  // namespace

void ConfigureLogFromEnv() {
    // 1) 全局兜底级别
    LogLevel lvl = LogLevel::kInfo;
    if (ParseLogLevel(std::getenv("CQ_LOG_LEVEL"), &lvl)) {
        SetLogLevel(lvl);
    }

    // 2) workflow 白名单（不设 = 全开，保持既有行为）
    const char* wf_env = std::getenv("CQ_LOG_WORKFLOW");
    if (wf_env != nullptr && *wf_env != '\0') {
        WorkflowMask mask = 0u;
        ForEachToken(wf_env, &WorkflowTokenFn, &mask);
        // 全 0 意味着用户配了但一段都没识别出来 —— 那等于把所有日志关掉，
        // 这是最容易误伤的配置错误，故**拒绝**该次设置并回落到全开。
        if (mask != 0u) {
            SetWorkflowFilter(mask);
        } else {
            LogWorkflowImpl(Workflow::kCore, LogLevel::kWarn, __FILE__, __LINE__,
                            "CQ_LOG_WORKFLOW 无有效链路名，按全开处理（避免误关全部日志）");
        }
    }

    // 3) per-workflow 提级
    const char* wfl_env = std::getenv("CQ_LOG_WF_LEVEL");
    if (wfl_env != nullptr && *wfl_env != '\0') {
        ForEachToken(wfl_env, &WfLevelTokenFn, nullptr);
    }
}

// ---------------------------------------------------------------------------
// 核心日志函数
// ---------------------------------------------------------------------------
void LogImpl(LogLevel level, const char* file, int line, const char* fmt, ...) {
    Logger& logger = Logger::Instance();
    // 运行时最低级别过滤（Trace 的编译期剔除另由宏负责）。
    if (static_cast<int32_t>(level) < static_cast<int32_t>(logger.MinLevel())) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    char buf[1024];
    const char* msg = FormatVa(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    logger.Emit(level, file, line, msg);
}

void LogFrameImpl(PipelineStage stage, const RationalTime& pts, const char* file, int line,
                  const char* fmt, ...) {
    // 帧级 trace 自动继承环节的 workflow 归属，调用方无需重复指定。
    va_list ap;
    va_start(ap, fmt);
    EmitFrameWorkflowVa(WorkflowForStage(stage), stage, pts, file, line, fmt, ap);
    va_end(ap);
}

// ---- 带 workflow 的发射 ----
//
// 过滤顺序刻意如此：**先查白名单与级别，通过后才格式化**。
// 逐帧日志每天走几十万次，多一次 vsnprintf 是真金白银的成本。
void LogWorkflowImpl(Workflow wf, LogLevel level, const char* file, int line, const char* fmt,
                     ...) {
    Logger& logger = Logger::Instance();
    if (!logger.ShouldEmit(wf, level)) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    EmitWorkflowVa(wf, level, file, line, fmt, ap);
    va_end(ap);
}

void LogFrameWorkflowImpl(Workflow wf, PipelineStage stage, const RationalTime& pts,
                          const char* file, int line, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    EmitFrameWorkflowVa(wf, stage, pts, file, line, fmt, ap);
    va_end(ap);
}

}  // namespace cq
