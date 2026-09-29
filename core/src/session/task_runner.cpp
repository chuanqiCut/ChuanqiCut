// ChuanqiCut — 串行任务执行器实现（CORE-008）

#include "cq/session/task_runner.h"

#include <utility>

namespace cq {

TaskRunner::TaskRunner(Config cfg)
    : cfg_(cfg),
      queue_(cfg.queue_capacity),
      cancel_(),
      running_(false),
      executed_(0) {}

TaskRunner::~TaskRunner() {
    // D4：std::thread 在 joinable 状态析构会 std::terminate。
    // 无条件收尾，避免"忘记停就销毁"直接崩进程。
    Shutdown();
}

Status TaskRunner::Start() {
    bool expected = false;
    if (!running_.compare_exchange_strong(expected, true)) {
        return Status{StatusCode::kInvalidArgument};  // 已在运行
    }
    worker_ = std::thread(&TaskRunner::WorkerLoop, this);
    return Status::Ok();
}

Status TaskRunner::Post(Task task) {
    if (!running_.load(std::memory_order_acquire)) {
        return Status{StatusCode::kInvalidArgument};  // 未启动或已停止
    }
    // TryPush 是非阻塞的：这是 Post「绝不阻塞」的关键。
    // 队列满 = 背压信号，由调用方降速/丢帧（ARCH-001 §6 铁律 3）。
    if (!queue_.TryPush(std::move(task))) {
        return Status{StatusCode::kResourceExhausted};
    }
    return Status::Ok();
}

void TaskRunner::RequestStop() { cancel_.RequestCancel(); }

Status TaskRunner::Shutdown() {
    // 先置 false：此后新 Post 直接失败，避免往正在收尾的队列里塞任务。
    running_.store(false, std::memory_order_release);
    cancel_.RequestCancel();
    if (worker_.joinable()) {
        worker_.join();
    }
    return Status::Ok();
}

bool TaskRunner::IsRunning() const { return running_.load(std::memory_order_acquire); }

size_t TaskRunner::PendingCount() const { return queue_.Size(); }

size_t TaskRunner::QueueCapacity() const { return queue_.Capacity(); }

ThreadRole TaskRunner::Role() const { return cfg_.role; }

size_t TaskRunner::ExecutedCount() const { return executed_.load(std::memory_order_acquire); }

const char* TaskRunner::Name() const { return cfg_.name; }

void TaskRunner::WorkerLoop() {
    // 线程入口标记角色：之后任务体内的 CurrentThreadRole() 即为 cfg_.role。
    SetCurrentThreadRole(cfg_.role);

    Task task;
    while (true) {
        // 阻塞取任务；被取消时 BoundedQueue 会 ≤ ~1ms 返回 kCancelled（CORE-005）。
        Status st = queue_.Pop(task, cancel_);
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
