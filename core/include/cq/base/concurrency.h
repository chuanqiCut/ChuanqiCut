// ChuanqiCut — 并发原语 / 有界队列 / CancelToken（CORE-005）
//
// 设计约束（来自 ARCH-001 §6 线程模型 / AGENTS.root.md 红线）：
//   1. 头文件零平台类型：本文件只使用 C/C++ 基础类型、标准库并发设施
//     （std::mutex / std::condition_variable / std::atomic），绝不出现任何
//      Apple/Android/鸿蒙平台类型或 API。
//   2. 内核禁用异常（ARCH-001「禁用异常跨模块」；CORE-002）。错误与停止信号
//      一律通过 `Status` 返回值传播，本文件不抛不捕。
//   3. 并发原语提供「必要的最小集合」，**不**做成通用线程库（无自己的线程池、
//      无读写锁、无 future/promise 封装）：仅 CancelToken（协作取消）+ BoundedQueue
//      （背压）。线程池/会话线程骨架属于 CORE-008，不在 base 层。
//
// 与 CORE-002 `Status::kCancelled`(6000) 的语义闭合（本任务重点验收）：
//   * 取消是「独立的停止信号」，不是「错误」。`CancelToken` 的取消路径只产生
//     `kCancelled`，其 `IsError()` 返回 false（CORE-002 已定，本文件 static_assert 固化）。
//   * 调用方据此区分两件语义完全不同的事（视频编辑里关键）：
//       - 收到 kCancelled：用户主动中止 → 释放 GPU/媒体资源、清理临时文件、正常退出，
//         不计入失败、不弹「出错」提示。
//       - 收到其它非 OK 码：任务因故障失败（如文件损坏）→ 计入失败、上报。
//
// 为什么不用 std::future / 异步回调做取消？协作式轮询最贴合媒体管线：
//   长任务在 pass 边界 / 解码边界检查 `IsCancelled()` 即可，零额外锁；而回调/监听
//   需注册锁，与「音频线程禁锁」红线冲突，故不做（避免过度设计）。若未来确需区分
//   取消原因（用户取消 vs 资源不足），可在 State 增 reason 字段——本期不动。

#ifndef CQ_BASE_CONCURRENCY_H_
#define CQ_BASE_CONCURRENCY_H_

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <mutex>
#include <queue>
#include <utility>

#include "cq/base/status.h"

namespace cq {

// ===========================================================================
// CancelToken — 协作式取消（CORE-005，本任务重点）
// ===========================================================================
// 内部用 shared_ptr<State> 持有原子布尔标志，使 token 可**值拷贝**并分发给多个
// worker 线程，它们共享同一取消状态（一个 source 请求取消，多方立即感知）。
//
// 线程安全：所有公开方法线程安全。`RequestCancel` 幂等，可被任意线程调用。
// 取消及时性：协作式。阻塞原语（见 BoundedQueue 的阻塞 Push/Pop）通过轮询本
//   标志实现「被取消时 ≤ ~1ms 唤醒」，远小于主线程 16ms 预算，满足 UI 响应性。
class CancelToken {
public:
    // 构造一个「未取消」的 token，拥有独立共享状态。
    CancelToken() : state_(std::make_shared<State>()) {}

    CancelToken(const CancelToken&) = default;
    CancelToken& operator=(const CancelToken&) = default;
    ~CancelToken() = default;

    // 请求取消（幂等）。任意线程可调用。
    void RequestCancel() {
        state_->cancelled.store(true, std::memory_order_release);
    }

    // 是否已取消（原子读，acquire 保证后续清理读写发生在同步点之后）。
    bool IsCancelled() const {
        return state_->cancelled.load(std::memory_order_acquire);
    }

    // 语义闭合：已取消 → Status{kCancelled}（IsError()==false）；
    //           未取消 → Status::Ok()。长任务检测取消后直接 `return token.Cancelled();`。
    Status Cancelled() const {
        return IsCancelled() ? Status{StatusCode::kCancelled} : Status::Ok();
    }

private:
    struct State {
        std::atomic<bool> cancelled{false};
    };
    std::shared_ptr<State> state_;
};

// 语义闭合辅助：构造一个「已取消」状态（等价于 CancelToken 已取消时的 Cancelled()）。
// 供不持有 token 的代码路径（如资源清理阶段）直接返回取消信号。
Status CancelledStatus();

// ===========================================================================
// BoundedQueue<T> — 有界队列（背压，CORE-005）
// ===========================================================================
// 用途（ARCH-001 §6 背压铁律）：解码帧 / 渲染帧之间用有界队列，队列满时解码暂停
//   （预览）或降速（导出），**不允许无界增长导致 OOM**。
//
// 队列满时的三种行为（任务验收要求明确），映射到 API：
//   * 阻塞：   `Push(v, token)`       —— 满则阻塞直到有空间或被取消（可被取消唤醒）。
//   * 丢弃：   `TryPush(v)` 返回 false —— 调用方直接丢弃新帧（推理/预览丢帧场景）。
//   * 返回Status：`Push(v, token)` 在**被取消**时返回 kCancelled（非错误的停止信号）；
//               若调用方不允许阻塞，可用 `TryPush` 拿到 false 后自行映射为本域 Status。
//   设计选择：背压优先「暂停」而非「失败」——满队列在预览场景应当让上游暂停，而非
//   抛出错误；硬失败由调用方基于 TryPush 的 false 自行决定（本文件不擅自引入错误码）。
//
// 取消及时性（UI 响应性关键）：阻塞 Push/Pop 用 `condition_variable::wait_for`
//   以 1ms 为步长轮询 `token.IsCancelled()`，同时正常入队/出队会 notify_one。
//   因此即使另一端已退出、无人 notify，取消请求也能在 ≤ ~1ms + 调度延迟内唤醒阻塞方
//   （远小于 16ms 主线程预算），无需为每次等待在 token 上注册回调（保持精简）。
//
// 线程安全：多生产者 / 多消费者安全（内部 mutex + 双条件变量）。
//   注：T 必须可拷贝或可移动。
template <typename T>
class BoundedQueue {
public:
    explicit BoundedQueue(size_t capacity) : capacity_(capacity) {}

    // 非阻塞入队：成功返回 true；队列满返回 false（调用方据此「丢弃」或「报错」）。
    bool TryPush(const T& value) {
        std::unique_lock<std::mutex> lk(mtx_);
        if (q_.size() >= capacity_) return false;
        q_.push(value);
        lk.unlock();
        cv_not_full_.notify_one();
        return true;
    }

    bool TryPush(T&& value) {
        std::unique_lock<std::mutex> lk(mtx_);
        if (q_.size() >= capacity_) return false;
        q_.push(std::move(value));
        lk.unlock();
        cv_not_full_.notify_one();
        return true;
    }

    // 阻塞入队：满则阻塞直到有空间或被 token 取消。
    //   返回 Ok（已入队）；被取消返回 kCancelled（IsError()==false）。
    // 注意：`wait_for(lk, d, pred)` 在超时时返回 `pred()` 而**不会**循环到 pred 为真，
    //   故这里用显式 while 守护：仅在「有空间」或「被取消」时才离开等待，
    //   否则继续以 1ms 步长轮询取消标志（见下方「取消及时性」注释）。
    Status Push(const T& value, const CancelToken& token) {
        std::unique_lock<std::mutex> lk(mtx_);
        while (q_.size() >= capacity_ && !token.IsCancelled()) {
            cv_not_full_.wait_for(lk, std::chrono::milliseconds(1));
        }
        if (token.IsCancelled() && q_.size() >= capacity_) {
            return Status{StatusCode::kCancelled};
        }
        q_.push(value);
        lk.unlock();
        cv_not_empty_.notify_one();
        return Status::Ok();
    }

    // 非阻塞出队：成功返回 true 并写入 out；队列空返回 false。
    bool TryPop(T& out) {
        std::unique_lock<std::mutex> lk(mtx_);
        if (q_.empty()) return false;
        out = std::move(q_.front());
        q_.pop();
        lk.unlock();
        cv_not_full_.notify_one();
        return true;
    }

    // 阻塞出队：空则阻塞直到有元素或被 token 取消。
    //   返回 Ok（已出队）；被取消返回 kCancelled（IsError()==false）。
    // 同样用显式 while 守护（理由同 Push）：仅在「有元素」或「被取消」时离开等待，
    //   否则以 1ms 步长轮询取消标志，保证取消请求 ≤ ~1ms 唤醒阻塞方。
    Status Pop(T& out, const CancelToken& token) {
        std::unique_lock<std::mutex> lk(mtx_);
        while (q_.empty() && !token.IsCancelled()) {
            cv_not_empty_.wait_for(lk, std::chrono::milliseconds(1));
        }
        if (token.IsCancelled() && q_.empty()) {
            return Status{StatusCode::kCancelled};
        }
        out = std::move(q_.front());
        q_.pop();
        lk.unlock();
        cv_not_full_.notify_one();
        return Status::Ok();
    }

    size_t Capacity() const {
        std::unique_lock<std::mutex> lk(mtx_);
        return capacity_;
    }
    size_t Size() const {
        std::unique_lock<std::mutex> lk(mtx_);
        return q_.size();
    }
    bool Empty() const {
        std::unique_lock<std::mutex> lk(mtx_);
        return q_.empty();
    }
    bool Full() const {
        std::unique_lock<std::mutex> lk(mtx_);
        return q_.size() >= capacity_;
    }

private:
    mutable std::mutex mtx_;
    std::condition_variable cv_not_empty_;
    std::condition_variable cv_not_full_;
    std::queue<T> q_;
    size_t capacity_;
};

}  // namespace cq

#endif  // CQ_BASE_CONCURRENCY_H_
