// ChuanqiCut — 线程模型与队列骨架单测（CORE-008）
//
// 验收重点是 ARCH-001 §6 铁律 1「主线程零阻塞」——必须**可测**，而不是写在文档里。
// 本用例实测：向 worker 投递一个 100ms 的任务，Post() 本身必须 < 16ms 返回。
//
// 附带验证：任务确实跑在 worker 线程（非主线程）、串行 FIFO、有界背压、
// 以及 RequestStop / Shutdown 的干净退出。

#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

#include "cq/session/task_runner.h"
#include "cq/session/thread_model.h"

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

using Clock = std::chrono::steady_clock;

double ElapsedMs(Clock::time_point begin, Clock::time_point end) {
    return std::chrono::duration<double, std::milli>(end - begin).count();
}

void SleepMs(int ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

// ---- 1. 角色标记与查询 ----
void TestThreadRole() {
    std::printf("[test] 线程角色标记与查询\n");
    // 未标记的线程必须是 kUnknown（不可猜成 main）。
    Check(cq::CurrentThreadRole() == cq::ThreadRole::kUnknown, "默认角色为 kUnknown");
    Check(!cq::IsMainThread(), "未标记时 IsMainThread()==false");
    Check(!cq::IsAudioThread(), "未标记时 IsAudioThread()==false");

    cq::SetCurrentThreadRole(cq::ThreadRole::kMain);
    Check(cq::CurrentThreadRole() == cq::ThreadRole::kMain, "标记为主线程后可读回");
    Check(cq::IsMainThread(), "标记后 IsMainThread()==true");
    Check(!cq::IsAudioThread(), "主线程不是音频线程");

    cq::SetCurrentThreadRole(cq::ThreadRole::kAudio);
    Check(cq::IsAudioThread(), "标记后可查询音频线程");
    Check(!cq::IsMainThread(), "音频线程不是主线程");

    // 角色名只是日志文本，不得返回空/未知。
    Check(cq::ThreadRoleName(cq::ThreadRole::kSession) != nullptr, "kSession 有名字");
    Check(cq::ThreadRoleName(cq::ThreadRole::kDecode) != nullptr, "kDecode 有名字");

    // 恢复到主线程身份：后续用例要模拟「宿主在主线程投递任务」。
    cq::SetCurrentThreadRole(cq::ThreadRole::kMain);
}

// ---- 2. 主线程零阻塞（本任务的验收核心）----
void TestPostDoesNotBlockMainThread() {
    std::printf("[test] 主线程零阻塞：投递 100ms 任务，Post() 本身须 < 16ms\n");
    cq::TaskRunner::Config cfg;
    cfg.role = cq::ThreadRole::kSession;
    cfg.queue_capacity = 8;
    cq::TaskRunner runner(cfg);
    Check(runner.Start().IsOk(), "Start 成功");

    Check(cq::IsMainThread(), "当前确实标记为主线程（否则本用例无意义）");

    std::atomic<bool> finished{false};
    Clock::time_point t0 = Clock::now();
    cq::Status st = runner.Post([&] {
        SleepMs(100);  // 故意耗时远超主线程预算
        finished.store(true, std::memory_order_release);
    });
    Clock::time_point t1 = Clock::now();
    double post_ms = ElapsedMs(t0, t1);

    Check(st.IsOk(), "Post 成功");
    Check(post_ms < 16.0, "Post() 返回耗时 < 16ms（主线程预算）");
    std::printf("    Post() 实测耗时: %.3f ms\n", post_ms);

    // 任务确实执行了（异步完成后）。
    // ⚠️ 等待对象必须是 ExecutedCount（更晚发生的事件）：worker 先执行任务
    // （任务内部置 finished）再 fetch_add 计数，若等 finished 就断言计数，
    // 会撞上「store 已见、自增未到」的窗口 —— 门禁负载下实测抖出过一次。
    int waited = 0;
    while (runner.ExecutedCount() < 1 && waited < 5000) {
        SleepMs(1);
        waited += 1;
    }
    Check(runner.ExecutedCount() == 1, "执行计数为 1");
    Check(finished.load(std::memory_order_acquire), "耗时任务最终完成");

    Check(runner.Shutdown().IsOk(), "Shutdown 成功");
    Check(!runner.IsRunning(), "Shutdown 后不在运行");
}

// ---- 3. 任务跑在 worker 线程，且角色被正确标记 ----
void TestTaskRunsOnWorkerThread() {
    std::printf("[test] 任务在 worker 线程执行（非主线程）\n");
    cq::TaskRunner::Config cfg;
    cfg.role = cq::ThreadRole::kDecode;  // 换个角色，验证标记可配置
    cq::TaskRunner runner(cfg);
    runner.Start();

    Check(runner.Role() == cq::ThreadRole::kDecode, "Role 返回配置的角色");

    std::atomic<bool> done{false};
    bool task_on_main = true;
    bool task_saw_role = false;
    runner.Post([&] {
        task_on_main = cq::IsMainThread();
        task_saw_role = (cq::CurrentThreadRole() == cq::ThreadRole::kDecode);
        done.store(true, std::memory_order_release);
    });

    int waited = 0;
    while (!done.load(std::memory_order_acquire) && waited < 5000) {
        SleepMs(1);
        waited += 1;
    }
    Check(done.load(std::memory_order_acquire), "任务完成");
    Check(!task_on_main, "任务不在主线程执行");
    Check(task_saw_role, "任务内 CurrentThreadRole() == 配置的角色");

    runner.Shutdown();
}

// ---- 4. 串行 FIFO ----
void TestSerialFifo() {
    std::printf("[test] 串行执行且保持 FIFO\n");
    cq::TaskRunner::Config cfg;
    cfg.queue_capacity = 32;
    cq::TaskRunner runner(cfg);
    runner.Start();

    constexpr int kCount = 10;
    std::vector<int> order;
    std::atomic<int> completed{0};
    for (int i = 0; i < kCount; ++i) {
        Check(runner.Post([&order, &completed, i] {
                  order.push_back(i);
                  completed.fetch_add(1, std::memory_order_release);
              }).IsOk(),
              "Post 成功");
    }
    int waited = 0;
    while (completed.load(std::memory_order_acquire) < kCount && waited < 5000) {
        SleepMs(1);
        waited += 1;
    }
    Check(completed.load(std::memory_order_acquire) == kCount, "全部任务完成");

    bool ordered = true;
    if (order.size() != static_cast<size_t>(kCount)) {
        ordered = false;
    } else {
        for (int i = 0; i < kCount; ++i) {
            if (order[static_cast<size_t>(i)] != i) ordered = false;
        }
    }
    Check(ordered, "执行顺序与投递顺序一致（FIFO）");

    runner.Shutdown();
}

// ---- 5. 有界背压：队列满 -> kResourceExhausted（不无限增长）----
void TestBackpressure() {
    std::printf("[test] 背压：队列满返回 kResourceExhausted\n");
    cq::TaskRunner::Config cfg;
    cfg.queue_capacity = 2;  // 故意很小
    cq::TaskRunner runner(cfg);
    runner.Start();
    Check(runner.QueueCapacity() == 2, "容量为 2");

    // A 占住 worker：它先置 started，再阻塞直到 gate 打开。
    std::atomic<bool> started{false};
    std::atomic<bool> gate{false};
    Check(runner.Post([&] {
              started.store(true, std::memory_order_release);
              int spins = 0;
              while (!gate.load(std::memory_order_acquire) && spins < 5000) {
                  SleepMs(1);
                  ++spins;
              }
          }).IsOk(),
          "投递 A 成功");

    // 等 worker 取走 A（此时队列重新为空，后续投递一定滞留在队列里）。
    int waited = 0;
    while (!started.load(std::memory_order_acquire) && waited < 5000) {
        SleepMs(1);
        ++waited;
    }
    Check(started.load(std::memory_order_acquire), "A 已被 worker 取走");

    Check(runner.Post([] {}).IsOk(), "投递 B 成功（队列 1/2）");
    Check(runner.Post([] {}).IsOk(), "投递 C 成功（队列 2/2）");

    // 队列已满：必须明确失败，不得阻塞、不得无界增长。
    Clock::time_point t0 = Clock::now();
    cq::Status st = runner.Post([] {});
    Clock::time_point t1 = Clock::now();
    Check(st.IsError(), "队列满时 Post 失败");
    Check(st.code == cq::StatusCode::kResourceExhausted,
          "失败码为 kResourceExhausted（背压信号，非崩溃/非阻塞）");
    Check(ElapsedMs(t0, t1) < 16.0, "满队列时 Post 也立即返回（< 16ms）");

    gate.store(true, std::memory_order_release);  // 放行 A
    runner.Shutdown();
}

// ---- 6. 生命周期边界 ----
void TestLifecycle() {
    std::printf("[test] 生命周期边界\n");
    // 未启动时投递必须明确失败，不得崩溃。
    cq::TaskRunner::Config cfg;
    cq::TaskRunner runner(cfg);
    Check(!runner.IsRunning(), "未启动时 IsRunning()==false");
    Check(runner.Post([] {}).code == cq::StatusCode::kInvalidArgument,
          "未启动时 Post 返回 kInvalidArgument");

    Check(runner.Start().IsOk(), "Start 成功");
    Check(runner.Start().IsError(), "重复 Start 返回错误（不重复拉线程）");

    Check(runner.Shutdown().IsOk(), "Shutdown 成功");
    Check(!runner.IsRunning(), "Shutdown 后 IsRunning()==false");
    Check(runner.Post([] {}).code == cq::StatusCode::kInvalidArgument,
          "Shutdown 后 Post 返回 kInvalidArgument");
    Check(runner.Shutdown().IsOk(), "重复 Shutdown 安全（幂等）");
}

}  // namespace

int main() {
    TestThreadRole();
    TestPostDoesNotBlockMainThread();
    TestTaskRunsOnWorkerThread();
    TestSerialFifo();
    TestBackpressure();
    TestLifecycle();

    std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
