// ChuanqiCut — 预览取帧泵实现（UIA-010 子步骤 5）
//
// 契约与不变量见 preview_pump.h 的类注释，这里只写实现层面的取舍。
//
// 硬约束：内核禁用异常（ARCH-001），且 CocoaPods 侧的 Pods target 是显式
//   -fno-exceptions（实测：`cannot use 'try' with exceptions disabled`）。故这里
//   **不能**用 try/catch 包 std::thread 的构造 —— 与既有 TaskRunner 一致：
//   线程创建失败在禁异常构建下会 terminate，不做（也做不了）降级。

#include "cq/preview/preview_pump.h"

#include <algorithm>
#include <chrono>
#include <new>
#include <utility>
#include <vector>

#include "cq/base/log.h"   // CQ_LOG_*_WF：带 workflow 的分级日志（CORE-010）
#include "cq/base/perf.h"  // CQ_SLOW_CALL_WF

namespace cq {

// 慢调用告警统一走 core/base 的 CQ_SLOW_CALL_WF（CORE-010）。旧版是本文件自抄的
// Debug-only 结构体，阈值还与其它文件不一致（这里 1000ms、别处 500ms）——
// 同一个工程里两套阈值本身就是排障噪音源，现已统一到 perf.h 的 500ms。

PreviewPump::PreviewPump(IPreviewFrameSource* source) : source_(source) {}

PreviewPump::~PreviewPump() { Stop(); }

Status PreviewPump::Start() {
    std::lock_guard<std::mutex> lk(mtx_);
    if (running_) return Status::Ok();
    if (source_ == nullptr) return Status(StatusCode::kInvalidArgument);
    stop_ = false;
    // ⚠️ 不用 try/catch（禁异常构建下连 try 都编译不过，见文件头）。
    //    创建失败在禁异常构建里会 terminate —— 与 TaskRunner 同策略，不假装能降级。
    worker_ = std::thread([this] { Loop(); });
    if (!worker_.joinable()) return Status(StatusCode::kResourceExhausted);
    running_ = true;
#ifndef NDEBUG
    watchdog_ = std::thread([this] { WatchdogLoop(); });
#endif
    return Status::Ok();
}

void PreviewPump::Stop() {
    {
        std::lock_guard<std::mutex> lk(mtx_);
        if (!running_) return;
        stop_ = true;
        running_ = false;
    }
    cv_.notify_one();
    if (worker_.joinable()) worker_.join();
    worker_ = std::thread();
#ifndef NDEBUG
    if (watchdog_.joinable()) watchdog_.join();
    watchdog_ = std::thread();
#endif
}

bool PreviewPump::IsRunning() const {
    std::lock_guard<std::mutex> lk(mtx_);
    return running_;
}

void PreviewPump::Request(const RationalTime& pts) {
    {
        std::lock_guard<std::mutex> lk(mtx_);
        // 上一个请求还没被泵取走就被覆盖 = 那一帧永不渲染（丢帧）。
        if (has_request_) coalesced_.fetch_add(1, std::memory_order_relaxed);
        requested_pts_ = pts;
        has_request_ = true;
    }
    requested_.fetch_add(1, std::memory_order_relaxed);
    cv_.notify_one();
}

Status PreviewPump::RequestResize(uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) return Status(StatusCode::kInvalidArgument);
    {
        std::lock_guard<std::mutex> lk(mtx_);
        if (!running_) return Status(StatusCode::kInvalidArgument);
        resize_pending_ = true;
        resize_w_ = width;
        resize_h_ = height;
    }
    cv_.notify_one();
    return Status::Ok();
}

void PreviewPump::Lock() { mtx_.lock(); }

void PreviewPump::Unlock() { mtx_.unlock(); }

const PreviewPump::Frame& PreviewPump::LatestLocked() const { return published_; }

PreviewPump::Stats PreviewPump::GetStats() const {
    Stats s;
    s.requested = requested_.load(std::memory_order_relaxed);
    s.rendered = rendered_.load(std::memory_order_relaxed);
    s.coalesced = coalesced_.load(std::memory_order_relaxed);
    s.non_ok = non_ok_.load(std::memory_order_relaxed);
    return s;
}

void PreviewPump::Loop() {
    CQ_LOG_DEBUG_WF(Workflow::kPreview, "loop start");
    for (;;) {
        bool do_render = false;
        bool do_resize = false;
        RationalTime pts{0, 1};
        uint32_t w = 0;
        uint32_t h = 0;
        {
            std::unique_lock<std::mutex> lk(mtx_);
            cv_.wait(lk, [this] { return stop_ || has_request_ || resize_pending_; });
            if (stop_) return;
            if (resize_pending_) {
                do_resize = true;
                w = resize_w_;
                h = resize_h_;
                resize_pending_ = false;
            }
            if (has_request_) {
                do_render = true;
                pts = requested_pts_;
                has_request_ = false;
            }
        }

        // Resize 必须持锁执行：它会销毁旧 RT，而消费者可能正拿着旧句柄。
        if (do_resize) {
            std::lock_guard<std::mutex> lk(mtx_);
            const Status rs = source_->Resize(w, h);
            // 句柄失效要如实告知消费者：清空 frame 并推进 seq（seq 前进 = 旧句柄作废）。
            published_ = Frame{};
            published_.seq = ++seq_;
            if (!rs.IsOk()) non_ok_.fetch_add(1, std::memory_order_relaxed);
        }

        if (!do_render) continue;

        // ---- 唯一触碰解码会话 / 纹理缓存的地方（其余线程不得再调 RenderFrame）----
        TextureHandle tex = nullptr;
        CancelToken token;
        // CORE-010：Release 可见。总警报覆盖无分段警报的静默阻塞
        // （draw 的 GPU 等待 / gap 清屏 / 快照加载等）。阈值统一为 500ms，
        // 与旧版本文件自抄的 1000ms 不同——同一个工程两套阈值本身就是排障噪音。
        CQ_SLOW_CALL_WF(Workflow::kPreview, "pump RenderFrame(total)");
        const Status s = source_->RenderFrame(pts, tex, token);
        if (!s.IsOk()) non_ok_.fetch_add(1, std::memory_order_relaxed);
#ifndef NDEBUG
        // MEDIA-023 排障仪器（Debug only）：每完成 60 帧打印一次分段耗时直方图
        // （acquire=取帧+解码 / import=Metal 导入 / draw=离屏渲染），每 20 帧一报。
        if (const auto* t = source_->DebugLastTimings()) {
            stage_samples_.push_back(*t);
            if (stage_samples_.size() % 20 == 0) {
                auto report = [&](const char* name, auto get) {
                    std::vector<double> v;
                    v.reserve(stage_samples_.size());
                    for (const auto& st : stage_samples_) {
                        v.push_back(static_cast<double>(get(st)) / 1e6);
                    }
                    std::sort(v.begin(), v.end());
                    CQ_LOG_DEBUG_WF(Workflow::kPerf,
                                    "%s (n=%zu) min=%.1fms p50=%.1fms p95=%.1fms max=%.1fms",
                                    name, v.size(), v.front(), v[v.size() / 2],
                                    v[v.size() * 95 / 100], v.back());
                };
                report("acquire", [](const auto& t) { return t.acquire_ns; });
                report("import ", [](const auto& t) { return t.import_ns; });
                report("draw   ", [](const auto& t) { return t.draw_ns; });
                report("total  ", [](const auto& t) { return t.total_ns; });
            }
        }
#endif

        {
            std::lock_guard<std::mutex> lk(mtx_);
            published_.pts = pts;
            published_.texture = tex;
            published_.code = static_cast<int32_t>(s.code);
            published_.seq = ++seq_;
        }
        rendered_.fetch_add(1, std::memory_order_relaxed);
    }
}

void PreviewPump::WatchdogLoop() {
    // 每 500ms 检查渲染器的当前阶段；同一阶段 >1s = 渲染卡死，打印段名与耗时
    // （析构式警报对"永不返回"的调用失明——本线程就是为它存在的）。
    const char* last_stage = "";
    int repeats = 0;
    while (!stop_) {
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        if (stop_) return;
        const char* stage = source_->DebugStage();
        const int64_t since = source_->DebugStageSinceNanos();
        if (stage == nullptr || stage[0] == '\0') {
            last_stage = "";
            repeats = 0;
            continue;
        }
        const auto elapsed_ms =
            (std::chrono::steady_clock::now().time_since_epoch().count() - since) /
            1'000'000;
        if (elapsed_ms >= 1000) {
            // Warn **且 Release 可见**：这是「确定了系统在变慢/变卡」的告警，不是
            // 调试细节。MEDIA-026/027 两次冻结都是靠这一行指认卡点在哪一段
            // （'provider+acquire'），而旧版它被 #ifndef NDEBUG 挡着——
            // 真机 Release 包里一条不留。
            CQ_LOG_WARN_WF(Workflow::kPerf, "RenderFrame 卡在 '%s' 已 %lldms", stage,
                           static_cast<long long>(elapsed_ms));
        }
        (void)last_stage;
        (void)repeats;
    }
}

}  // namespace cq
