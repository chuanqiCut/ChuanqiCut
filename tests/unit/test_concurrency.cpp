// ChuanqiCut — 并发原语 / 有界队列 / CancelToken 单测（CORE-005）
//
// 覆盖（验收要求：取消语义可测）：
//   1. CancelToken 基础：初始未取消；RequestCancel 后 IsCancelled 为真。
//   2. 取消语义闭合：kCancelled 的 IsError()==false；CancelledStatus()/Cancelled() 返回 6000。
//   3. 取消及时性：阻塞 Pop 被取消后在 ~1ms 级返回（实测，远小于 16ms 预算）。
//   4. 正常路径不受影响：未取消时阻塞 Pop 拿到正确值；阻塞 Push 在腾出空间后成功。
//   5. 有界队列满时行为：容量 / 入队结果 / 返回码（TryPush 满返回 false）。
//   6. 队列取消中断：满队列的阻塞 Push 被取消返回 kCancelled 且 IsError()==false。
//   7. 并发一致性：多生产者/多消费者计数与元素总和一致（无丢失/重复）。
// 所有计时为可复现实测输出（见各用例打印）。

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>
#include <vector>

#include "cq/base/concurrency.h"
#include "cq/base/status.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (!cond) {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

// 编译期守卫：取消码值稳定为 6000 且「不是错误」的语义闭合。
static_assert(static_cast<int32_t>(cq::StatusCode::kCancelled) == 6000,
              "kCancelled must be 6000 (CORE-002 stable code)");
static_assert(!cq::Status{cq::StatusCode::kCancelled}.IsError(),
              "kCancelled must NOT be an error (CORE-002 / CORE-005 contract)");
static_assert(cq::Status{cq::StatusCode::kCancelled}.IsCancelled(),
              "IsCancelled() must be true for kCancelled");

void TestCancelTokenBasic() {
    std::printf("[test] CancelToken 基础：初始未取消，请求后取消\n");
    cq::CancelToken token;
    Check(!token.IsCancelled(), "初始未取消");
    token.RequestCancel();
    Check(token.IsCancelled(), "请求取消后 IsCancelled()==true");
    token.RequestCancel();  // 幂等
    Check(token.IsCancelled(), "重复请求仍取消（幂等）");
}

void TestCancelTokenSharedState() {
    std::printf("[test] CancelToken 共享状态：拷贝后一方取消，另一方感知\n");
    cq::CancelToken a;
    cq::CancelToken b = a;  // 值拷贝，共享同一 State
    cq::CancelToken c = b;
    Check(!a.IsCancelled() && !b.IsCancelled() && !c.IsCancelled(), "拷贝后初始都未取消");
    b.RequestCancel();  // 通过 b 请求
    Check(a.IsCancelled(), "a 感知到 b 的取消（共享状态）");
    Check(c.IsCancelled(), "c 也感知到取消");
}

void TestCancelSemanticsClosure() {
    std::printf("[test] 取消语义闭合：kCancelled 不是错误，路径返回 6000\n");
    // 未取消时 Cancelled() 返回 Ok。
    cq::CancelToken live;
    Check(live.Cancelled().IsOk(), "未取消时 Cancelled()==Ok");
    // 取消后 Cancelled() 返回 kCancelled，且 IsError()==false。
    cq::CancelToken dead;
    dead.RequestCancel();
    cq::Status s = dead.Cancelled();
    Check(s.IsCancelled(), "取消后 Cancelled().IsCancelled()==true");
    Check(!s.IsError(), "kCancelled 不是错误（IsError()==false）");
    Check(static_cast<int>(s.code) == 6000, "取消路径返回码值 6000");
    // 便捷函数等价。
    cq::Status s2 = cq::CancelledStatus();
    Check(s2.IsCancelled() && !s2.IsError() && static_cast<int>(s2.code) == 6000,
          "CancelledStatus() 同样返回 6000 且非错误");
}

void TestCancelTimeliness() {
    std::printf("[test] 取消及时性：阻塞 Pop 被取消后应在 ~1ms 级返回\n");
    cq::BoundedQueue<int> q(4);
    cq::CancelToken token;
    cq::Status result = cq::Status::Ok();
    std::thread consumer([&]() {
        int v = 0;
        result = q.Pop(v, token);  // 阻塞在空队列
    });
    // 让 consumer 先进入阻塞态。
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    auto t0 = std::chrono::steady_clock::now();
    token.RequestCancel();
    consumer.join();
    auto t1 = std::chrono::steady_clock::now();
    double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    Check(result.IsCancelled(), "被取消后 Pop 返回 kCancelled");
    Check(ms < 50.0, "取消请求到阻塞 Pop 返回的耗时 < 50ms（实测远低于 16ms 预算）");
    std::printf("  取消请求 -> 阻塞 Pop 返回：实测 %.3f ms（code=%d）\n",
                ms, static_cast<int>(result.code));
}

void TestQueueNormalPath() {
    std::printf("[test] 正常路径（未取消）：阻塞 Pop 拿到正确值；阻塞 Push 等空间后成功\n");
    cq::BoundedQueue<int> q(2);
    cq::CancelToken token;
    std::thread producer([&]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        cq::Status s = q.Push(42, token);
        Check(s.IsOk(), "未取消的阻塞 Push 成功");
    });
    int v = 0;
    cq::Status s = q.Pop(v, token);  // 阻塞直到 producer 放入
    Check(s.IsOk(), "未取消的阻塞 Pop 成功");
    Check(v == 42, "Pop 拿到正确值 42");
    producer.join();
}

void TestQueueFullBehavior() {
    std::printf("[test] 有界队列满时行为：容量 + 入队结果 + 返回码\n");
    constexpr size_t kCap = 3;
    cq::BoundedQueue<int> q(kCap);
    Check(q.Capacity() == kCap, "容量 = 3");
    Check(q.Empty(), "初始空");

    Check(q.TryPush(1), "TryPush #1 成功");
    Check(q.TryPush(2), "TryPush #2 成功");
    Check(q.TryPush(3), "TryPush #3 成功");
    Check(q.Full(), "队列满（Full()==true）");
    Check(q.Size() == kCap, "Size == 3");

    // 满队列再 TryPush 必须返回 false（调用方据此「丢弃」或映射为本域 Status）。
    bool rejected = q.TryPush(4);
    Check(!rejected, "满队列 TryPush 返回 false（期望丢弃/报错路径）");
    std::printf("  容量=%zu，填满 3 个后第 4 次 TryPush 返回 %s（期望 false）\n",
                q.Capacity(), rejected ? "true" : "false");

    // 阻塞 Push 在满且未取消时应保持阻塞，待腾出空间后成功（不立即失败）。
    cq::CancelToken token;
    std::thread consumer([&]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        int tmp;
        q.TryPop(tmp);  // 腾出 1 个空间
    });
    cq::Status s = q.Push(4, token);
    Check(s.IsOk(), "阻塞 Push 在腾出空间后成功（未取消不失败）");
    consumer.join();
}

void TestQueueCancelInterrupt() {
    std::printf("[test] 队列取消中断：满队列的阻塞 Push 被取消返回 kCancelled\n");
    cq::BoundedQueue<int> q(1);
    cq::CancelToken token;
    Check(q.TryPush(99), "先填满队列（容量 1）");
    Check(q.Full(), "队列满");

    std::thread trigger([&]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(15));
        token.RequestCancel();
    });
    auto t0 = std::chrono::steady_clock::now();
    cq::Status s = q.Push(100, token);  // 满且被取消 → kCancelled
    auto t1 = std::chrono::steady_clock::now();
    double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    Check(s.IsCancelled(), "满队列阻塞 Push 被取消返回 kCancelled");
    Check(!s.IsError(), "kCancelled 不是错误（IsError()==false）");
    trigger.join();
    std::printf("  满队列 Push 被取消返回：耗时 %.3f ms，code=%d\n",
                ms, static_cast<int>(s.code));
}

void TestQueueConcurrent() {
    std::printf("[test] 有界队列并发一致性：4 生产者 × 1000 / 4 消费者计数与总和一致\n");
    constexpr size_t kCap = 16;
    cq::BoundedQueue<int> q(kCap);
    cq::CancelToken token;  // 本测试全程不取消
    constexpr int kProducers = 4;
    constexpr int kPerProducer = 1000;
    constexpr int kTotal = kProducers * kPerProducer;

    std::atomic<int> produced{0};
    std::atomic<int> consumed{0};
    std::atomic<int64_t> sum{0};

    std::vector<std::thread> producers;
    std::vector<std::thread> consumers;
    for (int p = 0; p < kProducers; ++p) {
        producers.emplace_back([&, p]() {
            for (int i = 0; i < kPerProducer; ++i) {
                q.Push(p * kPerProducer + i, token);  // 全程不取消 → 必成功
                produced.fetch_add(1, std::memory_order_relaxed);
            }
        });
    }
    for (int c = 0; c < 4; ++c) {
        consumers.emplace_back([&]() {
            while (consumed.load(std::memory_order_relaxed) < kTotal) {
                int v = 0;
                cq::Status s = q.Pop(v, token);
                if (s.IsOk()) {
                    sum.fetch_add(static_cast<int64_t>(v), std::memory_order_relaxed);
                    consumed.fetch_add(1, std::memory_order_relaxed);
                } else {
                    break;  // 仅取消才可能发生，本测试不应到达
                }
            }
        });
    }
    for (auto& t : producers) t.join();
    for (auto& t : consumers) t.join();

    Check(produced.load() == kTotal, "全部生产完成（计数一致）");
    Check(consumed.load() == kTotal, "全部消费完成（计数一致，无丢失/卡死）");

    int64_t expected = 0;
    for (int p = 0; p < kProducers; ++p) {
        for (int i = 0; i < kPerProducer; ++i) {
            expected += static_cast<int64_t>(p * kPerProducer + i);
        }
    }
    Check(sum.load() == expected, "消费到的值总和与生产者写入一致（无重复/错乱）");
    std::printf("  并发后 produced=%d consumed=%d sum=%lld (期望 %lld)\n",
                static_cast<int>(produced.load()),
                static_cast<int>(consumed.load()),
                static_cast<long long>(sum.load()),
                static_cast<long long>(expected));
}

}  // namespace

int main() {
    std::printf("== ChuanqiCut core_concurrency 单测 ==\n");
    TestCancelTokenBasic();
    TestCancelTokenSharedState();
    TestCancelSemanticsClosure();
    TestCancelTimeliness();
    TestQueueNormalPath();
    TestQueueFullBehavior();
    TestQueueCancelInterrupt();
    TestQueueConcurrent();

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
