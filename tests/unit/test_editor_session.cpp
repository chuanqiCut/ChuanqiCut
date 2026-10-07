// ChuanqiCut — EditorSession 门面与快照单测（CORE-009）
//
// 验收对应 BACKLOG「快照版本号递增，UI 可 diff」：
//   * 成功变更 → 版本 +1；失败/取消 → **不推进**（D2，否则 UI 会错刷）
//   * ChangesSince(v) 给出该版本之后的变更日志（UI 可 diff）
//   * 主线程 Submit 不阻塞（实测 < 16ms）
//   * 变更在 session 线程串行执行
//
// 状态内容由 ISessionState 注入（D3）：本期用 TestState 证明机制真跑通，
// 不等 MODEL-001 的 TimelineModel —— 但也因此**不代表真实模型的 diff 能力**。

#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

#include "cq/session/editor_session.h"
#include "cq/session/session_snapshot.h"
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

double ElapsedMs(Clock::time_point a, Clock::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}

void SleepMs(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

// 测试用状态实现：digest 就是一个计数器，足以验证"状态变了 digest 跟着变"。
class TestState final : public cq::ISessionState {
public:
    uint64_t Digest() const override { return counter_; }
    const char* TypeName() const override { return "test-state"; }
    void Bump() { ++counter_; }

private:
    uint64_t counter_ = 0;
};

// 等待版本号达到 target（带上限，避免 CI 挂死）。
bool WaitVersion(const cq::EditorSession& s, uint64_t target) {
    for (int i = 0; i < 5000; ++i) {
        if (s.CurrentSnapshot().version >= target) return true;
        SleepMs(1);
    }
    return false;
}

// ---- 1. 生命周期边界 ----
void TestLifecycle() {
    std::printf("[test] 生命周期边界\n");
    cq::EditorSession session;
    Check(!session.IsRunning(), "未启动时 IsRunning()==false");
    Check(session.Submit("x", [] { return cq::Status::Ok(); }).code ==
              cq::StatusCode::kInvalidArgument,
          "未启动时 Submit 返回 kInvalidArgument");

    Check(session.Start().IsOk(), "Start 成功");
    Check(session.Start().IsError(), "重复 Start 返回错误");
    Check(session.IsRunning(), "启动后 IsRunning()==true");

    Check(session.Shutdown().IsOk(), "Shutdown 成功");
    Check(!session.IsRunning(), "Shutdown 后不在运行");
    Check(session.Submit("x", [] { return cq::Status::Ok(); }).code ==
              cq::StatusCode::kInvalidArgument,
          "Shutdown 后 Submit 返回 kInvalidArgument");
}

// ---- 2. 版本号递增（成功才推进）----
void TestVersionIncrement() {
    std::printf("[test] 快照版本号递增\n");
    cq::EditorSession session;
    session.Start();

    Check(session.CurrentSnapshot().version == 0, "初始版本为 0");

    Check(session.Submit("add-clip", [] { return cq::Status::Ok(); }).IsOk(), "提交 1 成功");
    Check(WaitVersion(session, 1), "版本到达 1");
    Check(session.CurrentSnapshot().version == 1, "成功变更后版本为 1");

    Check(session.Submit("trim", [] { return cq::Status::Ok(); }).IsOk(), "提交 2 成功");
    Check(WaitVersion(session, 2), "版本到达 2");
    Check(session.CurrentSnapshot().version == 2, "版本单调递增到 2");
    Check(session.ChangeCount() == 2, "变更记录数为 2");

    session.Shutdown();
}

// ---- 3. 失败与取消都不推进版本（D2）----
void TestFailureDoesNotAdvanceVersion() {
    std::printf("[test] 失败/取消不推进版本\n");
    cq::EditorSession session;
    session.Start();

    session.Submit("ok", [] { return cq::Status::Ok(); });
    Check(WaitVersion(session, 1), "先成功一次（版本 1）");

    // 失败
    session.Submit("bad", [] { return cq::Status{cq::StatusCode::kInvalidArgument}; });
    SleepMs(50);  // 给变更足够时间执行完
    Check(session.CurrentSnapshot().version == 1, "失败变更后版本仍为 1");
    Check(session.ChangeCount() == 1, "失败变更不计入变更日志");

    // 取消（IsError()==false，但仍不是 Ok —— 同样不推进）
    session.Submit("cancelled", [] { return cq::Status{cq::StatusCode::kCancelled}; });
    SleepMs(50);
    Check(session.CurrentSnapshot().version == 1, "取消后版本仍为 1");
    Check(session.ChangeCount() == 1, "取消不计入变更日志");

    session.Shutdown();
}

// ---- 4. 主线程 Submit 不阻塞 ----
void TestSubmitDoesNotBlockMainThread() {
    std::printf("[test] 主线程 Submit 不阻塞\n");
    cq::SetCurrentThreadRole(cq::ThreadRole::kMain);
    cq::EditorSession session;
    session.Start();
    Check(cq::IsMainThread(), "当前标记为主线程（否则本用例无意义）");

    Clock::time_point t0 = Clock::now();
    cq::Status st = session.Submit("slow", [] {
        SleepMs(100);  // 远超主线程预算
        return cq::Status::Ok();
    });
    Clock::time_point t1 = Clock::now();
    double ms = ElapsedMs(t0, t1);

    Check(st.IsOk(), "Submit 成功");
    Check(ms < 16.0, "Submit 返回耗时 < 16ms");
    std::printf("    Submit() 实测耗时: %.3f ms\n", ms);

    Check(WaitVersion(session, 1), "慢变更最终完成");
    session.Shutdown();
}

// ---- 5. 变更在 session 线程串行执行 ----
void TestSerialExecutionOnSessionThread() {
    std::printf("[test] 变更在 session 线程串行执行\n");
    cq::EditorSession session;
    session.Start();

    std::atomic<int> completed{0};
    std::vector<int> order;
    bool all_on_session_thread = true;

    for (int i = 0; i < 8; ++i) {
        // ⚠️ 必须按值捕获 i：[&] 会捕获循环变量的引用，任务真正执行时 i 早已变成 8，
        //    于是所有任务都 push 同一个值 —— FIFO 断言就会"莫名其妙"失败。
        session.Submit("op", [&, i] {
            if (!cq::IsMainThread() && cq::CurrentThreadRole() == cq::ThreadRole::kSession) {
                // 正确：跑在 session 线程
            } else {
                all_on_session_thread = false;
            }
            order.push_back(i);
            completed.fetch_add(1, std::memory_order_release);
            return cq::Status::Ok();
        });
    }

    for (int i = 0; i < 5000 && completed.load(std::memory_order_acquire) < 8; ++i) {
        SleepMs(1);
    }
    Check(completed.load(std::memory_order_acquire) == 8, "8 个变更全部完成");
    Check(all_on_session_thread, "全部变更都在 session 线程执行（非主线程、角色正确）");

    bool ordered = (order.size() == 8);
    for (size_t i = 0; ordered && i < order.size(); ++i) {
        if (order[i] != static_cast<int>(i)) ordered = false;
    }
    Check(ordered, "执行顺序与提交顺序一致（串行 FIFO）");

    session.Shutdown();
}

// ---- 6. UI 可 diff：ChangesSince ----
void TestChangesSince() {
    std::printf("[test] UI 可 diff：ChangesSince\n");
    cq::EditorSession session;
    session.Start();

    session.Submit("c1", [] { return cq::Status::Ok(); });
    session.Submit("c2", [] { return cq::Status::Ok(); });
    session.Submit("c3", [] { return cq::Status::Ok(); });
    Check(WaitVersion(session, 3), "三次变更完成");

    std::vector<cq::ChangeRecord> changes;
    size_t n = session.ChangesSince(1, &changes);
    Check(n == 2, "从版本 1 之后有 2 条变更");
    bool names_ok = (changes.size() == 2 && changes[0].name != nullptr &&
                     changes[1].name != nullptr);
    Check(names_ok, "变更记录带有名字（UI 可据此增量刷新）");
    Check(changes.size() == 2 && changes[0].version == 2 && changes[1].version == 3,
          "变更记录按版本升序");

    changes.clear();
    Check(session.ChangesSince(3, &changes) == 0, "从最新版本之后无变更");
    changes.clear();
    Check(session.ChangesSince(0, &changes) == 3, "从 0 之后有 3 条变更");

    session.Shutdown();
}

// ---- 7. 状态摘要（ISessionState 扩展点）----
void TestStateDigest() {
    std::printf("[test] ISessionState 摘要随状态变化\n");
    TestState state;
    cq::EditorSession session(cq::EditorSession::Config{}, &state);
    session.Start();

    Check(session.CurrentSnapshot().digest == 0, "初始 digest 为 0");

    session.Submit("bump", [&state] {
        state.Bump();
        return cq::Status::Ok();
    });
    Check(WaitVersion(session, 1), "变更完成");
    Check(session.CurrentSnapshot().digest == 1, "状态变化后 digest 随之更新");

    session.Submit("bump-again", [&state] {
        state.Bump();
        return cq::Status::Ok();
    });
    Check(WaitVersion(session, 2), "第二次变更完成");
    Check(session.CurrentSnapshot().digest == 2, "digest 再次更新");

    session.Shutdown();
}

// ---- 8. 未注入状态也能工作 ----
void TestNoState() {
    std::printf("[test] 未注入 ISessionState：内建模型生效（UIA-009 子步骤 1 起的新语义）\n");
    // 语义变更（2026-10-03）：默认构造现在内建 EditorModelState ——
    // digest 从构造起就是真实时间线指纹，不再是 0。机制本身（不注入也不崩）不变。
    cq::EditorSession session;  // 不注入 state → 内建模型
    Check(session.CurrentSnapshot().digest != 0, "构造后 digest 即为真实指纹");
    session.Start();
    Check(session.Submit("x", [] { return cq::Status::Ok(); }).IsOk(), "Submit 成功");
    Check(WaitVersion(session, 1), "版本推进");
    Check(session.CurrentSnapshot().digest != 0, "变更后 digest 仍真实");
    Check(session.CurrentTimeline() != nullptr, "CurrentTimeline 快照可读");
    session.Shutdown();
}

// ---- 9. 观察者：在 session 线程收到递增后的快照 ----
void TestObserver() {
    std::printf("[test] 快照观察者\n");
    cq::EditorSession session;
    std::atomic<int> notified{0};
    std::atomic<uint64_t> last_version{0};
    bool observer_on_session_thread = true;

    session.SetSnapshotObserver([&](const cq::Snapshot& snap) {
        if (cq::IsMainThread()) observer_on_session_thread = false;
        last_version.store(snap.version, std::memory_order_release);
        notified.fetch_add(1, std::memory_order_release);
    });
    session.Start();

    session.Submit("a", [] { return cq::Status::Ok(); });
    for (int i = 0; i < 5000 && notified.load(std::memory_order_acquire) < 1; ++i) {
        SleepMs(1);
    }
    Check(notified.load(std::memory_order_acquire) == 1, "观察者被调用 1 次");
    Check(last_version.load(std::memory_order_acquire) == 1, "观察者拿到递增后的版本");
    Check(observer_on_session_thread, "观察者回调在 session 线程（不在主线程）");

    session.Shutdown();
}

// ---- 10. 背压：队列满 ----
void TestBackpressure() {
    std::printf("[test] 背压：变更队列满\n");
    cq::EditorSession::Config cfg;
    cfg.queue_capacity = 1;
    cq::EditorSession session(cfg);
    session.Start();

    std::atomic<bool> gate{false};
    std::atomic<bool> started{false};
    session.Submit("blocker", [&] {
        started.store(true, std::memory_order_release);
        for (int i = 0; i < 5000 && !gate.load(std::memory_order_acquire); ++i) {
            SleepMs(1);
        }
        return cq::Status::Ok();
    });
    for (int i = 0; i < 5000 && !started.load(std::memory_order_acquire); ++i) {
        SleepMs(1);
    }
    Check(started.load(std::memory_order_acquire), "首个变更已被取走执行");

    Check(session.Submit("fill", [] { return cq::Status::Ok(); }).IsOk(), "队列填满（1/1）");
    Clock::time_point t0 = Clock::now();
    cq::Status st = session.Submit("overflow", [] { return cq::Status::Ok(); });
    Clock::time_point t1 = Clock::now();
    Check(st.code == cq::StatusCode::kResourceExhausted, "满队列返回 kResourceExhausted");
    Check(ElapsedMs(t0, t1) < 16.0, "满队列时 Submit 立即返回（不阻塞）");

    gate.store(true, std::memory_order_release);
    session.Shutdown();
}

}  // namespace

int main() {
    TestLifecycle();
    TestVersionIncrement();
    TestFailureDoesNotAdvanceVersion();
    TestSubmitDoesNotBlockMainThread();
    TestSerialExecutionOnSessionThread();
    TestChangesSince();
    TestStateDigest();
    TestNoState();
    TestObserver();
    TestBackpressure();

    std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
