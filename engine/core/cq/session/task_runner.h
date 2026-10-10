// ChuanqiCut — 串行任务执行器 / Session Thread 骨架（CORE-008）
//
// 职责边界：base 层的 `concurrency.h` 只给原语（CancelToken / BoundedQueue），
// 明确声明**不做**线程池；线程池就是本文件的活（见该文件头注释）。
//
// 为什么需要一个串行执行器：ARCH-001 §6 规定 Session Thread 负责
// 「命令执行、模型变更、状态通知（**串行**）」。模型变更必须串行，
// 否则 CORE-009 的快照 / Undo-Redo 语义无法成立。
//
// 设计要点：
//   D2 Post() 绝不阻塞 —— 队列满立即返回 kResourceExhausted（背压），
//      不提供 PostAndWait（那会让「主线程零阻塞」在 API 面被破坏得更隐蔽）。
//   D3 任务内部禁止抛异常（内核禁用异常，红线）；抛出即 terminate，
//      这是**调用方的责任契约**，TaskRunner 不 try/catch 兜底。
//   D4 析构无条件 RequestCancel + join —— std::thread 在 joinable 状态析构会 terminate。

#ifndef CQ_SESSION_TASK_RUNNER_H_
#define CQ_SESSION_TASK_RUNNER_H_

#include <atomic>
#include <cstddef>
#include <functional>
#include <thread>

#include "cq/base/concurrency.h"
#include "cq/base/status.h"
#include "cq/session/thread_model.h"

namespace cq {

// 投递单元。
// ⚠️ 契约：**不得抛出异常**。执行期抛出不会被捕获（会 terminate），
//    错误应通过 Status / 输出参数在任务内部消化。
using Task = std::function<void()>;

class TaskRunner {
public:
    struct Config {
        // worker 线程对外呈现的角色（默认是 session 线程）。
        ThreadRole role = ThreadRole::kSession;

        // 队列容量（有界，ARCH-001 §6 背压铁律）。满则 Post 立即返回
        // kResourceExhausted，交由调用方降速/丢帧，**不允许无界增长导致 OOM**。
        size_t queue_capacity = 64;

        // 仅用于日志/调试标识。必须指向静态存储（本对象不拷贝其内容）。
        const char* name = "cq-worker";
    };

    explicit TaskRunner(Config cfg);
    ~TaskRunner();

    TaskRunner(const TaskRunner&) = delete;
    TaskRunner& operator=(const TaskRunner&) = delete;

    // 启动 worker 线程。重复调用返回 kInvalidArgument（不重复拉线程）。
    Status Start();

    // **非阻塞**投递任务。
    //   Ok                 —— 已入队
    //   kResourceExhausted —— 队列满（背压：调用方应降速或丢弃）
    //   kInvalidArgument   —— 尚未 Start，或已停止
    Status Post(Task task);

    // 请求停止（不等待）。已入队的任务是否继续执行取决于 worker 是否先被唤醒清空。
    // 语义：停止是「尽快退出」，不是「排空后再退出」（drain 语义目前不提供）。
    void RequestStop();

    // 停止并**等待** worker 线程退出（会阻塞调用线程）。
    // ⚠️ 因此不应在主线程调用：生命周期收尾阶段（如 session 销毁）才用它。
    Status Shutdown();

    // ---- 观测（便于自测与诊断，非性能指标）----
    bool IsRunning() const;
    size_t PendingCount() const;
    size_t QueueCapacity() const;
    ThreadRole Role() const;
    // 已执行完的任务数（仅为可测性，见任务卡 D5）。
    size_t ExecutedCount() const;
    const char* Name() const;

private:
    void WorkerLoop();

    Config cfg_;
    BoundedQueue<Task> queue_;
    CancelToken cancel_;
    std::thread worker_;

    // running_ 与 worker_ 的生命周期由 Start/Shutdown 管理；
    // 用 atomic 供 Post 在多调用线程下做无数据竞争的检查。
    std::atomic<bool> running_;
    std::atomic<size_t> executed_;
};

}  // namespace cq

#endif  // CQ_SESSION_TASK_RUNNER_H_
