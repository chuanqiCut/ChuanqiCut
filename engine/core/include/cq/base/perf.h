// ChuanqiCut — 性能埋点基础设施（TRACE/PERF 层，与 Log 分离）
//
// 为什么单独建一层，而不是直接用 CQ_LOG_TRACE：
//   1. **Release 必须可用**：真机实测跑的就是 Release 构建，埋点若随 NDEBUG 剔除，
//      到真机上就什么都看不到——那正是埋点存在的唯一场景。
//      （对比：日志 Trace 在 Release 下剔除是刻意的，见 log.h。两者取舍不同。）
//   2. 结构化而非文本：埋点要能被聚合统计（P50/P95/最大值），不是给人逐行看的日志。
//   3. 开销可控：默认关闭；开启后仍可采样（每 N 次记录一次）。
//
// 设计要点：
//   - 关闭时**零开销**：CQ_PERF_SCOPE 先检查开关，关闭时不取时钟、不构造记录。
//   - 帧可追溯：每条记录带 RationalTime pts（项目统一 timescale=120000，ADR-0009），
//     可与帧级日志、golden 比对对齐到同一帧。
//   - sink 可注入：与 Log 一样，平台侧可实现自己的上报（os_signpost / ATrace / 文件）。
//
// 用法：
//   CQ_PERF_SCOPE(cq::PerfStage::kDecode, pts);          // 函数作用域内计时
//   CQ_PERF_SCOPE_NAMED("vt_decode", pts).SetBytes(n);   // 带附加量
//
// 注：本文件属 base 层（跨平台），禁止出现平台类型。

#ifndef CQ_BASE_PERF_H_
#define CQ_BASE_PERF_H_

#include <cstdint>

#include "cq/base/logging.h"
#include "cq/base/rational_time.h"

namespace cq {

// 埋点环节。新增环节请追加在末尾（不要重排，便于跨版本对照）。
enum class PerfStage : int32_t {
    kUnknown = 0,
    kDemux,        // 解封装（读压缩包）
    kDecode,       // 解码（压缩包 → 像素）
    kImport,       // 外部图像导入（零拷贝 / CPU 回退）
    kRender,       // 渲染（含提交与等待）
    kEncode,       // 编码
    kMux,          // 封装写入
    kCacheLookup,  // 帧缓存查询
    kQueuePush,    // 入队（背压等待）
    kQueuePop,     // 出队（等待可取）
    kCustom = 1000 // 自定义（配合 CQ_PERF_SCOPE_NAMED 的 name 字段）
};

// 一条埋点记录。布局保持 POD，便于批量落盘与聚合。
struct PerfRecord {
    PerfStage stage = PerfStage::kUnknown;
    const char* name = nullptr;   // kCustom 时的名字（静态字符串，不拥有）
    RationalTime pts{};           // 帧标识（无帧语义时填 {}）
    int64_t begin_ns = 0;         // 单调时钟起点
    int64_t duration_ns = 0;      // 耗时
    int64_t bytes = 0;            // 附加量：字节数（纹理/样本）
    int32_t queue_depth = -1;     // 附加量：队列深度（-1 = 未采集）
    uint32_t thread_id = 0;
};

// 埋点上报端。实现由调用方注入（默认实现写 stderr，见 perf.cpp）。
//
// 注意：Record 可能在任意线程被调用，实现需自行保证线程安全
// （默认实现内部加锁，参考 log.cpp 的做法）。
class IPerfSink {
public:
    virtual ~IPerfSink() = default;
    virtual void Record(const PerfRecord& rec) = 0;
    virtual void Flush() = 0;
};

// ---- 开关与 sink 管理 ----
// 默认**关闭**。真机实测前显式 SetPerfEnabled(true) 打开。
void SetPerfEnabled(bool enabled);
bool PerfEnabled();

// 采样：每 N 次才记录一次（N<=1 表示每次都记）。用于降低高频路径的开销。
void SetPerfSampleRate(uint32_t every_n);
uint32_t PerfSampleRate();

// sink 注入（不接管所有权；nullptr = 静默丢弃）
void SetPerfSink(IPerfSink* sink);
IPerfSink* PerfSink();

// 单调时钟（ns）。埋点用单调时钟，避免受系统时间调整影响。
int64_t PerfNowNs();

// ---- RAII 计时器 ----
// 只在 PerfEnabled() 为真时取时钟；关闭时构造/析构都近乎零成本。
class PerfScope {
public:
    PerfScope(PerfStage stage, const RationalTime& pts);
    PerfScope(PerfStage stage, const RationalTime& pts, const char* name);
    ~PerfScope();

    PerfScope(const PerfScope&) = delete;
    PerfScope& operator=(const PerfScope&) = delete;

    // 附加量（在析构前设置才生效）
    void SetBytes(int64_t bytes);
    void SetQueueDepth(int32_t depth);

private:
    void Init(PerfStage stage, const RationalTime& pts, const char* name);

    bool active_ = false;
    PerfRecord rec_{};
};

// ---- 慢调用告警（RAII）----
//
// 背景（MEDIA-027 的血泪）：真机上「某个平台调用突然变成永久阻塞」是本项目最
// 难查的一类故障——它不崩、不报错，表现为帧率归零。当时的定位完全依赖
// `[SlowCall] xxx took 8226ms` 这一行；而那一版 SlowCallAlarm 是 `#ifndef NDEBUG`
// 的、**且在四个文件里各抄了一份**，Release 包里什么都不留。
//
// 因此这一版的两点要求：
//   1. **Release 必须可用**。它不是调试细节，是「系统正在变得不可用」的告警，
//      属于 Warn 级别。只有 Release 能看到的现场才正是要它的地方。
//   2. **带 workflow**。默认情况下 perf 链路的告警不能盖住其它链路的日志。
//
// 用法：
//   void Foo() {
//       CQ_SLOW_CALL_WF(cq::Workflow::kDecode, "VTDecompressionSessionDecodeFrame");
//       ...
//   }   // 超过阈值则打一行 WARN [wf:decode] 慢调用 ... took Nms
//
// 开销：构造一次 steady_clock::now()，析构再一次。不是热路径零成本设施，
// 因此**只套在可能真的阻塞几百毫秒的调用**上（平台解解码/解封装/ Seek / 同步等待），
// 不要套在逐帧函数里。
class SlowCallAlarm {
public:
    SlowCallAlarm(Workflow wf, const char* name, int64_t threshold_ms = kDefaultThresholdMs);
    ~SlowCallAlarm();

    SlowCallAlarm(const SlowCallAlarm&) = delete;
    SlowCallAlarm& operator=(const SlowCallAlarm&) = delete;

    // 默认阈值：500ms。人眼可感知的卡顿量级；再小会把正常抖动也算进来。
    static constexpr int64_t kDefaultThresholdMs = 500;

private:
    Workflow wf_ = Workflow::kCore;
    const char* name_ = nullptr;
    int64_t threshold_ms_ = kDefaultThresholdMs;
    int64_t begin_ns_ = 0;
};

}  // namespace cq

// 便捷宏。变量名带行号，允许同一作用域套多个。
#define CQ_SLOW_CALL_WF(wf, name) \
    ::cq::SlowCallAlarm cq_slow_call_##__LINE__((wf), (name))
#define CQ_SLOW_CALL_THRESHOLD_WF(wf, name, ms) \
    ::cq::SlowCallAlarm cq_slow_call_##__LINE__((wf), (name), (ms))

// 便捷宏。关闭时展开为一条空语句，**不取时钟、不构造对象**。
#define CQ_PERF_SCOPE(stage, pts) \
    ::cq::PerfScope cq_perf_scope_##__LINE__((stage), (pts))
#define CQ_PERF_SCOPE_NAMED(stage, pts, name) \
    ::cq::PerfScope cq_perf_scope_##__LINE__((stage), (pts), (name))

#endif  // CQ_BASE_PERF_H_
