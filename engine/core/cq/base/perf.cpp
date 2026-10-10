// ChuanqiCut — 性能埋点实现
//
// 关闭时零开销由宏层保证（见 perf.h 的 CQ_PERF_SCOPE）；本文件只负责开启后的行为：
//   - 默认 sink 写 stderr（结构化、便于重定向到文件后聚合统计）
//   - 线程安全：sink 指针与开关用原子量；默认 sink 内部加锁（与 log.cpp 一致）
//   - 单调时钟：mach_absolute_time（Apple）/ steady_clock（通用）

#include "cq/base/perf.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <thread>

#if defined(__APPLE__)
#include <mach/mach_time.h>
#endif

namespace cq {
namespace {

std::atomic<bool> g_enabled{false};
std::atomic<uint32_t> g_sample_rate{1};
std::atomic<IPerfSink*> g_sink{nullptr};
std::atomic<uint64_t> g_call_counter{0};  // 用于采样判定

// 默认 sink：写 stderr。格式固定、便于脚本解析。
//
// ⚠️ 这是全仓库**唯一允许直写 stderr 的地方**（CORE-010 之后）—— sink 实现的本职就是
//    输出，它下面是没有更底层的路可走了。业务代码一律用 CQ_LOG_*_WF / IPerfSink，
//    不要把这里的写法当成范例抄走。
class StderrPerfSink : public IPerfSink {
public:
    void Record(const PerfRecord& rec) override {
        std::lock_guard<std::mutex> lk(mu_);
        std::fprintf(stderr,
                     "PERF stage=%d name=%s pts=%lld/%d dur_ns=%lld bytes=%lld qdepth=%d tid=%u\n",
                     static_cast<int>(rec.stage),
                     rec.name != nullptr ? rec.name : "-",
                     static_cast<long long>(rec.pts.value), static_cast<int>(rec.pts.timescale),
                     static_cast<long long>(rec.duration_ns),
                     static_cast<long long>(rec.bytes),
                     static_cast<int>(rec.queue_depth),
                     rec.thread_id);
    }
    void Flush() override {
        std::lock_guard<std::mutex> lk(mu_);
        std::fflush(stderr);
    }

private:
    std::mutex mu_;
};

StderrPerfSink g_default_sink;

}  // namespace

int64_t PerfNowNs() {
#if defined(__APPLE__)
    // mach_absolute_time 是单调的；用 timebase 转成 ns（只算一次）。
    static mach_timebase_info_data_t tb = [] {
        mach_timebase_info_data_t t{};
        (void)mach_timebase_info(&t);
        return t;
    }();
    const uint64_t t = mach_absolute_time();
    return static_cast<int64_t>(t * static_cast<uint64_t>(tb.numer) /
                                static_cast<uint64_t>(tb.denom));
#else
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::nanoseconds>(now).count();
#endif
}

void SetPerfEnabled(bool enabled) { g_enabled.store(enabled, std::memory_order_release); }
bool PerfEnabled() { return g_enabled.load(std::memory_order_acquire); }

void SetPerfSampleRate(uint32_t every_n) {
    g_sample_rate.store(every_n <= 1 ? 1 : every_n, std::memory_order_release);
}
uint32_t PerfSampleRate() { return g_sample_rate.load(std::memory_order_acquire); }

void SetPerfSink(IPerfSink* sink) { g_sink.store(sink, std::memory_order_release); }
IPerfSink* PerfSink() { return g_sink.load(std::memory_order_acquire); }

PerfScope::PerfScope(PerfStage stage, const RationalTime& pts) { Init(stage, pts, nullptr); }

PerfScope::PerfScope(PerfStage stage, const RationalTime& pts, const char* name) {
    Init(stage, pts, name);
}

void PerfScope::Init(PerfStage stage, const RationalTime& pts, const char* name) {
    if (!PerfEnabled()) {
        return;  // 关闭：不取时钟、不记录
    }
    // 采样：每 N 次构造才真正记录一次。counter 自增是原子的，多线程下是近似采样即可。
    const uint64_t n = g_call_counter.fetch_add(1, std::memory_order_relaxed);
    const uint32_t rate = PerfSampleRate();
    if (rate > 1 && (n % rate) != 0) {
        return;
    }
    active_ = true;
    rec_.stage = stage;
    rec_.name = name;
    rec_.pts = pts;
    rec_.begin_ns = PerfNowNs();
    // 真实线程标识（用于把同一线程上的记录串起来）。截断到 32 位仅供区分，不保证全局唯一。
    rec_.thread_id = static_cast<uint32_t>(
        std::hash<std::thread::id>{}(std::this_thread::get_id()) & 0xFFFFFFFFu);
}

PerfScope::~PerfScope() {
    if (!active_) {
        return;
    }
    rec_.duration_ns = PerfNowNs() - rec_.begin_ns;

    IPerfSink* sink = PerfSink();
    if (sink == nullptr) {
        sink = &g_default_sink;  // 未注入时用默认 stderr 实现
    }
    sink->Record(rec_);
}

void PerfScope::SetBytes(int64_t bytes) {
    if (active_) rec_.bytes = bytes;
}
void PerfScope::SetQueueDepth(int32_t depth) {
    if (active_) rec_.queue_depth = depth;
}

// ---------------------------------------------------------------------------
// 慢调用告警
// ---------------------------------------------------------------------------
SlowCallAlarm::SlowCallAlarm(Workflow wf, const char* name, int64_t threshold_ms)
    : wf_(wf), name_(name != nullptr ? name : "(unnamed)"), threshold_ms_(threshold_ms) {
    begin_ns_ = PerfNowNs();  // 单调时钟：不受系统时间调整影响
}

SlowCallAlarm::~SlowCallAlarm() {
    const int64_t elapsed_ns = PerfNowNs() - begin_ns_;
    if (threshold_ms_ <= 0) {
        return;
    }
    const int64_t elapsed_ms = elapsed_ns / 1000000;
    if (elapsed_ms < threshold_ms_) {
        return;
    }
    // Warn 级别 + workflow 标：Release 可见，且能按链路筛选。
    //
    // 这里刻意把「谁的锅」说清楚：只打印耗时而不带函数名+workflow，现场就只能
    // 对着一行 `took 8226ms` 干瞪眼（MEDIA-027 排查时走过这段弯路）。
    CQ_LOG_WARN_WF(wf_, "慢调用 %s took %lldms（阈值 %lldms）", name_,
                   static_cast<long long>(elapsed_ms), static_cast<long long>(threshold_ms_));
}

}  // namespace cq
