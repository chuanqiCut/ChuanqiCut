// ChuanqiCut — 内存池 / Arena / 纹理预算记账 单测（CORE-004）
//
// 覆盖：MemoryBudget 可查询当前分配量、超预算返回 kResourceExhausted(5000)；
//       TextureBudget 重点——已用/上限查询、超预算实测数字、注销恢复；
//       LinearArena bump 分配与 Reset；FixedPool 借出/回收。
// 所有数字为可复现实测输出（见各用例打印）。

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#include "cq/base/alloc.h"
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

// 编译期守卫：超预算错误码必须是稳定的 5000（CORE-002）。
static_assert(static_cast<int32_t>(cq::StatusCode::kResourceExhausted) == 5000,
              "kResourceExhausted must be 5000 (CORE-002 stable code)");

void TestMemoryBudget() {
    std::printf("[test] MemoryBudget：可查询当前分配量 + 超预算实测\n");
    constexpr int64_t kMB = 1024 * 1024;
    constexpr int64_t kLimit = 100 * kMB;  // 100 MiB
    cq::MemoryBudget mb(kLimit);

    Check(mb.Used() == 0, "初始已用 = 0");
    Check(mb.Limit() == kLimit, "上限 = 100 MiB");
    Check(mb.Remaining() == kLimit, "初始剩余 = 100 MiB");

    // 分配 100 次 1 MiB，应全部成功，Used 精确为 100 MiB。
    int64_t total = 0;
    for (int i = 0; i < 100; ++i) {
        cq::Status s = mb.TryAllocate(kMB);
        Check(s.IsOk(), "第 1..100 次 1MiB 分配成功");
        total += kMB;
    }
    Check(mb.Used() == total, "已用 = 100 MiB (实测数字)");
    Check(mb.Used() == 100 * kMB, "Used() == 104857600");
    Check(mb.Remaining() == 0, "剩余 = 0");
    std::printf("  分配 100 x 1MiB 后 Used=%lld byte (= %.2f MiB), Remaining=%lld\n",
                static_cast<long long>(mb.Used()),
                static_cast<double>(mb.Used()) / kMB,
                static_cast<long long>(mb.Remaining()));

    // 第 101 次超预算：必须返回 kResourceExhausted(5000)，且不改变计数。
    cq::Status over = mb.TryAllocate(kMB);
    Check(over.code == cq::StatusCode::kResourceExhausted,
          "第 101 次超预算返回 kResourceExhausted(5000)");
    Check(mb.Used() == 100 * kMB, "超预算后 Used 不变（无副作用）");
    std::printf("  第101次 TryAllocate -> code=%d (期望 5000), Used 仍=%lld\n",
                static_cast<int>(over.code), static_cast<long long>(mb.Used()));

    // 释放 50 MiB，Used 回到 50 MiB，剩余恢复。
    mb.Release(50 * kMB);
    Check(mb.Used() == 50 * kMB, "释放 50MiB 后 Used=50MiB");
    Check(mb.Remaining() == 50 * kMB, "释放后剩余=50MiB");
    std::printf("  释放 50MiB 后 Used=%lld, Remaining=%lld\n",
                static_cast<long long>(mb.Used()),
                static_cast<long long>(mb.Remaining()));
}

void TestTextureBudget() {
    std::printf("[test] TextureBudget（重点）：已用/上限查询 + 超预算实测数字\n");
    constexpr int64_t kMB = 1024 * 1024;
    // 上限：100 MiB，10 张（典型移动端纹理预算基线，见报告 baselines.md）。
    constexpr int64_t kByteLimit = 100 * kMB;
    constexpr int32_t kCountLimit = 10;
    cq::TextureBudget tb(kByteLimit, kCountLimit);

    Check(tb.UsedBytes() == 0 && tb.UsedCount() == 0, "初始已用 0 字节 / 0 张");
    Check(tb.LimitBytes() == kByteLimit && tb.LimitCount() == kCountLimit, "上限 100MiB/10张");
    Check(tb.RemainingBytes() == kByteLimit && tb.RemainingCount() == kCountLimit, "初始剩余满额");

    // 登记 10 张各 10 MiB：全部成功，Used = 100 MiB / 10 张。
    for (int i = 1; i <= 10; ++i) {
        cq::Status s = tb.Register(i, 10 * kMB);
        Check(s.IsOk(), "登记第 1..10 张成功");
    }
    Check(tb.UsedBytes() == 100 * kMB, "UsedBytes = 100 MiB (实测数字)");
    Check(tb.UsedCount() == 10, "UsedCount = 10");
    Check(tb.RemainingBytes() == 0, "字节剩余 = 0");
    Check(tb.RemainingCount() == 0, "张数剩余 = 0");
    std::printf("  登记 10 x 10MiB 后 UsedBytes=%lld (= %.2f MiB), UsedCount=%d, Remaining=%lld/%d\n",
                static_cast<long long>(tb.UsedBytes()),
                static_cast<double>(tb.UsedBytes()) / kMB,
                static_cast<int>(tb.UsedCount()),
                static_cast<long long>(tb.RemainingBytes()),
                static_cast<int>(tb.RemainingCount()));

    // 第 11 张超预算：kResourceExhausted(5000)，且不登记（Used 不变）。
    cq::Status over = tb.Register(11, 10 * kMB);
    Check(over.code == cq::StatusCode::kResourceExhausted,
          "第 11 张超预算返回 kResourceExhausted(5000)");
    Check(tb.UsedBytes() == 100 * kMB && tb.UsedCount() == 10,
          "超预算后 Used 不变（无副作用）");
    std::printf("  第11张 Register -> code=%d (期望 5000), UsedBytes 仍=%lld\n",
                static_cast<int>(over.code), static_cast<long long>(tb.UsedBytes()));

    // 张数维度也能触发超预算：把字节上限放宽、张数收紧到 1，再登记应失败。
    cq::TextureBudget tb2(1000 * kMB, 1);
    Check(tb2.Register(1, 1 * kMB).IsOk(), "tb2 第 1 张成功");
    cq::Status over2 = tb2.Register(2, 1 * kMB);
    Check(over2.code == cq::StatusCode::kResourceExhausted,
          "张数维度超预算返回 5000");
    tb2.Unregister(1);
    Check(tb2.UsedCount() == 0 && tb2.UsedBytes() == 0, "tb2 注销后归零");

    // 注销第 5 张：Used 回到 90 MiB / 9 张，剩余恢复。
    cq::Status un = tb.Unregister(5);
    Check(un.IsOk(), "注销已存在 id=5 成功");
    Check(tb.UsedBytes() == 90 * kMB, "注销后 UsedBytes=90MiB");
    Check(tb.UsedCount() == 9, "注销后 UsedCount=9");
    Check(tb.RemainingBytes() == 10 * kMB, "注销后字节剩余=10MiB");
    std::printf("  注销 id=5 后 UsedBytes=%lld, UsedCount=%d, Remaining=%lld/%d\n",
                static_cast<long long>(tb.UsedBytes()),
                static_cast<int>(tb.UsedCount()),
                static_cast<long long>(tb.RemainingBytes()),
                static_cast<int>(tb.RemainingCount()));

    // 重复注销未知 id：应返回 kInvalidArgument（不是崩溃）。
    cq::Status bad = tb.Unregister(999);
    Check(bad.code == cq::StatusCode::kInvalidArgument,
          "注销未知 id 返回 kInvalidArgument");
}

void TestArena() {
    std::printf("[test] LinearArena：bump 分配 + Reset\n");
    cq::LinearArena arena(4096);
    Check(arena.Capacity() == 4096, "容量 4096");
    Check(arena.Used() == 0, "初始已用 0");

    void* p1 = arena.Allocate(100);
    void* p2 = arena.Allocate(200);
    Check(p1 != nullptr && p2 != nullptr, "两次分配成功");
    Check(arena.Used() >= 300, "已用 >= 300（含对齐填充）");
    std::printf("  Allocate(100)+Allocate(200) 后 Used=%zu (>=300), Available=%zu\n",
                arena.Used(), arena.Available());

    // 超过容量应返回 nullptr。
    void* pbig = arena.Allocate(arena.Available() + 99999);
    Check(pbig == nullptr, "超容量分配返回 nullptr");

    arena.Reset();
    Check(arena.Used() == 0, "Reset 后已用归零");
    void* p3 = arena.Allocate(500);
    Check(p3 != nullptr, "Reset 后可重新分配");
    std::printf("  Reset 后 Used=%zu, 可再分配=%s\n", arena.Used(),
                p3 ? "yes" : "no");
}

void TestPool() {
    std::printf("[test] FixedPool：定长块借出/回收\n");
    cq::FixedPool pool(64, 4);
    Check(pool.BlockSize() == 64, "块大小 64");
    Check(pool.Capacity() == 4, "容量 4");
    Check(pool.FreeCount() == 4 && pool.LiveCount() == 0, "初始空闲 4");

    void* a[4];
    for (int i = 0; i < 4; ++i) {
        a[i] = pool.Acquire();
        Check(a[i] != nullptr, "借出成功");
    }
    Check(pool.LiveCount() == 4 && pool.FreeCount() == 0, "满负荷");
    std::printf("  Acquire x4 后 LiveCount=%zu, FreeCount=%zu\n",
                pool.LiveCount(), pool.FreeCount());

    // 池空再借返回 nullptr。
    Check(pool.Acquire() == nullptr, "池空借出返回 nullptr");

    // 全部归还。
    for (int i = 0; i < 4; ++i) pool.Release(a[i]);
    Check(pool.LiveCount() == 0 && pool.FreeCount() == 4, "全部归还");
    std::printf("  Release x4 后 LiveCount=%zu, FreeCount=%zu\n",
                pool.LiveCount(), pool.FreeCount());

    // 归还后可再借。
    Check(pool.Acquire() != nullptr, "归还后可再借");
}

// 线程安全实测：多线程并发 Register，计数最终一致、无重复 id 冲突。
void TestTextureBudgetThreadSafe() {
    std::printf("[test] TextureBudget 线程安全：8 线程各登记 10 张 1MiB\n");
    constexpr int64_t kMB = 1024 * 1024;
    cq::TextureBudget tb(1000 * kMB, 1000);  // 上限足够大，重点测并发一致性

    constexpr int kThreads = 8;
    constexpr int kPerThread = 10;
    std::vector<std::thread> threads;
    std::atomic<int> ok_count{0};
    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t]() {
            int base = t * kPerThread + 1;
            for (int i = 0; i < kPerThread; ++i) {
                int64_t id = base + i;
                cq::Status s = tb.Register(id, 1 * kMB);
                if (s.IsOk()) ok_count.fetch_add(1, std::memory_order_relaxed);
            }
        });
    }
    for (auto& th : threads) th.join();

    Check(static_cast<int>(ok_count.load()) == kThreads * kPerThread,
          "全部 80 张登记成功（无重复 id 冲突）");
    Check(tb.UsedCount() == kThreads * kPerThread, "UsedCount 一致 = 80");
    Check(tb.UsedBytes() == static_cast<int64_t>(kThreads) * kPerThread * kMB,
          "UsedBytes 一致 = 80 MiB");
    std::printf("  并发后 UsedCount=%d, UsedBytes=%lld (= %.2f MiB)\n",
                static_cast<int>(tb.UsedCount()),
                static_cast<long long>(tb.UsedBytes()),
                static_cast<double>(tb.UsedBytes()) / kMB);
}

}  // namespace

int main() {
    std::printf("== ChuanqiCut core_alloc 单测 ==\n");
    TestMemoryBudget();
    TestTextureBudget();
    TestArena();
    TestPool();
    TestTextureBudgetThreadSafe();

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
