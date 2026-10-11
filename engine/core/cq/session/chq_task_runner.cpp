// ChuanqiCut — 串行任务执行器实现（CORE-008）

#include "cq/session/chq_task_runner.h"

#include <utility>

namespace cq {

ChqTaskRunner::ChqTaskRunner(Config cfg)
    : cfg_(cfg),
      queue_(cfg.queue_capacity),
      cancel_(),
      running_(false),
      executed_(0) {}

ChqTaskRunner::~ChqTaskRunner() {
    // D4：std::thread 在 joinable 状态析构会 std::terminate。
    // 无条件收尾，避免"忘记停就销毁"直接崩进程。
    Shutdown();
}

ChqStatus ChqTaskRunner::Start() {
    bool expected = false;
    if (!running_.compare_exchange_strong(expected, true)) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};  // 已在运行
    }
    worker_ = std::thread(&ChqTaskRunner::WorkerLoop, this);
    return ChqStatus::Ok();
}

ChqStatus ChqTaskRunner::Post(ChqTask task) {
    if (!running_.load(std::memory_order_acquire)) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};  // 未启动或已停止
    }
    // TryPush 是非阻塞的：这是 Post「绝不阻塞」的关键。
    // 队列满 = 背压信号，由调用方降速/丢帧（ARCH-001 §6 铁律 3）。
    if (!queue_.TryPush(std::move(task))) {
        return ChqStatus{ChqStatusCode::kResourceExhausted};
    }
    return ChqStatus::Ok();
}

void ChqTaskRunner::RequestStop() { cancel_.RequestCancel(); }

ChqStatus ChqTaskRunner::Shutdown() {
    // 先置 false：此后新 Post 直接失败，避免往正在收尾的队列里塞任务。
    running_.store(false, std::memory_order_release);
    cancel_.RequestCancel();
    if (worker_.joinable()) {
        worker_.join();
    }
    return ChqStatus::Ok();
}

bool ChqTaskRunner::IsRunning() const { return running_.load(std::memory_order_acquire); }

size_t ChqTaskRunner::PendingCount() const { return queue_.Size(); }

size_t ChqTaskRunner::QueueCapacity() const { return queue_.Capacity(); }

ChqThreadRole ChqTaskRunner::Role() const { return cfg_.role; }

size_t ChqTaskRunner::ExecutedCount() const { return executed_.load(std::memory_order_acquire); }

const char* ChqTaskRunner::Name() const { return cfg_.name; }

void ChqTaskRunner::WorkerLoop() {
    // 线程入口标记角色：之后任务体内的 CurrentThreadRole() 即为 cfg_.role。
    SetCurrentThreadRole(cfg_.role);

    ChqTask task;
    while (true) {
        // 阻塞取任务；被取消时 ChqBoundedQueue 会 ≤ ~1ms 返回 kCancelled（CORE-005）。
        ChqStatus st = queue_.Pop(task, cancel_);
        if (!st.IsOk()) {
            break;  // kCancelled —— 停止信号，不是错误
        }
        // ⚠️ 契约：任务不得抛异常（见头文件注释）。此处不捕获 —— 捕获等于默许
        // 异常流向内核，违反「禁用异常」红线。
        task();
        executed_.fetch_add(1, std::memory_order_release);
    }
}

}  // namespace cq
