// ChuanqiCut — 预览取帧泵验收（UIA-010 子步骤 5）
//
// 用**假帧源**（可控耗时）测泵的并发语义 —— 真实 PreviewRenderer 依赖 Metal +
// 硬解后端，单帧耗时由解码速度决定，用它测「合并 / 线程归属 / 锁协议」既慢又
// 不确定。假源把耗时钉死，这些语义才能测成确定性断言。
//
// 本用例覆盖（每条都对应一个"挪线程"引入的真实风险）：
//   1. 请求 → 渲染 → 发布：帧的 pts / 句柄 / seq 正确。
//   2. **渲染不在调用线程**（否则挪线程等于没挪）。
//   3. **Request 不阻塞**：单帧耗时 50ms 时，Request 仍应在 ~1ms 内返回。
//   4. 请求合并（取最新 + 丢帧计数），且 request == render + coalesce 守恒。
//   5. 消费锁协议：持锁期间泵不能发布新帧（句柄稳定的根据）。
//   6. RequestResize 在泵线程执行，且让旧句柄失效（seq 前进 + 句柄清空）。
//   7. Stop 后不再渲染；Stop 可重启。
//
// 只链 cq_core（泵是平台无关的：std::thread + mutex + condvar）。

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>

#include "cq/base/concurrency.h"
#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/pal/common.h"
#include "cq/preview/preview_frame_source.h"
#include "cq/preview/preview_pump.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (cond) {
        std::printf("  ok  : %s\n", msg);
    } else {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

using Clock = std::chrono::steady_clock;

int64_t Ms(Clock::time_point from) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - from).count();
}

// 一个不可能出现在真实渲染器里的哨兵句柄：只要测出"句柄就是这个值"，就证明
// 帧确实来自假源（而不是哪里残留的旧值）。
char g_fake_texture_storage[64];
cq::TextureHandle FakeTexture() {
    return reinterpret_cast<cq::TextureHandle>(&g_fake_texture_storage[0]);
}

// ---- 假帧源：可控耗时 + 记录被谁在什么时候调用 ----
class FakeSource final : public cq::IPreviewFrameSource {
public:
    std::chrono::milliseconds frame_cost{5};
    cq::Status result = cq::Status::Ok();

    mutable std::mutex m;
    std::vector<int64_t> rendered_pts;  // 实际执行过的渲染（按完成顺序）
    std::thread::id worker_thread{};    // 最后一次 RenderFrame 所在线程
    int resize_calls = 0;
    std::thread::id resize_thread{};
    uint32_t last_w = 0;
    uint32_t last_h = 0;

    cq::Status RenderFrame(const cq::RationalTime& pts, cq::TextureHandle& out_texture,
                           const cq::CancelToken&) override {
        std::this_thread::sleep_for(frame_cost);
        {
            std::lock_guard<std::mutex> lk(m);
            rendered_pts.push_back(pts.value);
            worker_thread = std::this_thread::get_id();
        }
        out_texture = FakeTexture();
        return result;
    }

    cq::Status Resize(uint32_t width, uint32_t height) override {
        std::lock_guard<std::mutex> lk(m);
        ++resize_calls;
        resize_thread = std::this_thread::get_id();
        last_w = width;
        last_h = height;
        return cq::Status::Ok();
    }

    cq::IRenderTarget* Target() override { return nullptr; }

    size_t RenderedCount() const {
        std::lock_guard<std::mutex> lk(m);
        return rendered_pts.size();
    }
    int64_t LastRenderedPts() const {
        std::lock_guard<std::mutex> lk(m);
        return rendered_pts.empty() ? -1 : rendered_pts.back();
    }
    std::thread::id WorkerThread() const {
        std::lock_guard<std::mutex> lk(m);
        return worker_thread;
    }
};

// 等到条件成立或超时。返回是否成立。
template <typename Pred>
bool WaitUntil(Pred pred, int timeout_ms = 3000) {
    const Clock::time_point deadline = Clock::now() + std::chrono::milliseconds(timeout_ms);
    while (Clock::now() < deadline) {
        if (pred()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return pred();
}

cq::RationalTime Ticks(int64_t v) { return cq::RationalTime(v, cq::kProjectTimeScale); }

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut 预览取帧泵验收（UIA-010 子步骤 5）==\n");
    const std::thread::id main_thread = std::this_thread::get_id();

    // =========================================================================
    // 1. 基本链路：请求 → 渲染 → 发布
    // =========================================================================
    std::printf("\n[1] 请求 → 渲染 → 发布\n");
    {
        FakeSource src;
        src.frame_cost = std::chrono::milliseconds(5);
        cq::PreviewPump pump(&src);
        Check(!pump.IsRunning(), "创建后未启动（IsRunning=false）");
        Check(pump.Start().IsOk(), "Start()");
        Check(pump.IsRunning(), "启动后 IsRunning=true");

        pump.Request(Ticks(60000));  // 0.5s
        Check(WaitUntil([&] { return src.RenderedCount() == 1; }),
              "渲染执行了一次（done）");
        WaitUntil([&] {
            pump.Lock();
            const bool ok = pump.LatestLocked().seq >= 1;
            pump.Unlock();
            return ok;
        });

        pump.Lock();
        const cq::PreviewPump::Frame& f = pump.LatestLocked();
        Check(f.seq >= 1, "已发布帧（seq >= 1）");
        Check(f.texture == FakeTexture(), "句柄 == 帧源给出的句柄");
        Check(f.pts.value == 60000, "发布的 pts == 请求的 pts");
        Check(f.code == 0, "状态码 0（kOk）");
        pump.Unlock();

        pump.Stop();
        Check(!pump.IsRunning(), "Stop() 后 IsRunning=false");
    }

    // =========================================================================
    // 2. 渲染不在调用线程（挪线程的核心 —— 没这条就等于白做）
    // =========================================================================
    std::printf("\n[2] 渲染发生在泵线程，不是调用线程\n");
    {
        FakeSource src;
        cq::PreviewPump pump(&src);
        Check(pump.Start().IsOk(), "Start()");
        pump.Request(Ticks(1));
        Check(WaitUntil([&] { return src.RenderedCount() >= 1; }), "渲染执行");
        const std::thread::id worker = src.WorkerThread();
        Check(worker != main_thread, "RenderFrame 不在主线程执行（worker != main）");
        Check(worker != std::thread::id{}, "记录了真实的线程 id");
        pump.Stop();
    }

    // =========================================================================
    // 3. Request 不阻塞（红线 #8：主线程零阻塞）
    // =========================================================================
    std::printf("\n[3] 单帧 50ms 时 Request 仍立即返回\n");
    {
        FakeSource src;
        src.frame_cost = std::chrono::milliseconds(50);
        cq::PreviewPump pump(&src);
        Check(pump.Start().IsOk(), "Start()");
        pump.Request(Ticks(1));  // 让泵先进入渲染状态
        WaitUntil([&] { return src.RenderedCount() >= 1; });

        // 此时泵正忙（下一次渲染要 50ms），Request 必须立刻回来。
        const Clock::time_point t0 = Clock::now();
        for (int i = 0; i < 10; ++i) pump.Request(Ticks(i + 2));
        const int64_t elapsed = Ms(t0);
        std::printf("  10 次 Request 耗时 %lld ms（单帧成本 50ms）\n",
                    static_cast<long long>(elapsed));
        Check(elapsed < 10, "10 次 Request < 10ms（不随渲染耗时变长）");
        pump.Stop();
    }

    // =========================================================================
    // 4. 请求合并：取最新 + 守恒
    // =========================================================================
    std::printf("\n[4] 请求合并（取最新）+ requested == rendered + coalesced\n");
    {
        FakeSource src;
        src.frame_cost = std::chrono::milliseconds(20);
        cq::PreviewPump pump(&src);
        Check(pump.Start().IsOk(), "Start()");

        // 以 2ms 间隔投 12 个请求：远快于 20ms/帧的渲染速度 → 必然丢帧。
        for (int i = 1; i <= 12; ++i) {
            pump.Request(Ticks(i));
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        Check(WaitUntil([&] {
                  pump.Lock();
                  const bool ok = pump.LatestLocked().pts.value == 12;
                  pump.Unlock();
                  return ok;
              }),
              "最后一帧渲染的是最新请求（pts == 12，不是过时的）");

        // 等队列排空（没有待取走的请求了）
        WaitUntil([&] {
            const cq::PreviewPump::Stats s = pump.GetStats();
            return s.requested == s.rendered + s.coalesced;
        }, 3000);
        pump.Stop();
        const cq::PreviewPump::Stats s = pump.GetStats();
        std::printf("  requested=%llu rendered=%llu coalesced=%llu non_ok=%llu\n",
                    static_cast<unsigned long long>(s.requested),
                    static_cast<unsigned long long>(s.rendered),
                    static_cast<unsigned long long>(s.coalesced),
                    static_cast<unsigned long long>(s.non_ok));
        Check(s.requested == 12, "requested == 12（每个请求都被计数）");
        Check(s.coalesced > 0, "发生了丢帧（coalesced > 0）—— 请求快于渲染时的应有行为");
        Check(s.rendered < 12, "实际渲染次数 < 12（不可能追上 2ms 间隔）");
        Check(s.requested == s.rendered + s.coalesced, "守恒：requested == rendered + coalesced");
        Check(s.non_ok == 0, "假帧源恒成功 → non_ok == 0");
        Check(src.LastRenderedPts() == 12, "帧源最后一次渲染的 pts == 12");
    }

    // =========================================================================
    // 5. 消费锁协议：持锁期间泵不能发布新帧
    // =========================================================================
    std::printf("\n[5] 消费锁：持锁期间 seq 不前进（句柄稳定的根据）\n");
    {
        // ⚠️ 单帧成本取 100ms：必须保证「Request 之后立刻 Lock」发生在泵**渲染中**
        //    而不是它已经发布完之后，否则测不出"发布被锁挡住"。
        FakeSource src;
        src.frame_cost = std::chrono::milliseconds(100);
        cq::PreviewPump pump(&src);
        Check(pump.Start().IsOk(), "Start()");
        pump.Request(Ticks(1));
        WaitUntil([&] {
            pump.Lock();
            const bool ok = pump.LatestLocked().seq >= 1;
            pump.Unlock();
            return ok;
        });
        uint64_t seq_before = 0;
        pump.Lock();
        seq_before = pump.LatestLocked().seq;
        pump.Unlock();

        // ⚠️ 顺序要紧：先 Request 再 Lock。**不可**在持锁期间调 Request ——
        //    Request 也要拿同一把锁，那样会直接死锁（这不是理论风险，是本用例
        //    第一版真踩出来的）。契约见 preview_pump.h。
        pump.Request(Ticks(2));  // 泵开始渲染（100ms），发布时要等锁
        pump.Lock();
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        const uint64_t seq_held = pump.LatestLocked().seq;
        pump.Unlock();
        Check(seq_held == seq_before, "持锁 150ms 期间 seq 未前进（泵被挡住）");
        Check(WaitUntil([&] {
                  pump.Lock();
                  const bool ok = pump.LatestLocked().seq > seq_before;
                  pump.Unlock();
                  return ok;
              }),
              "解锁后 seq 前进（泵恢复发布）");
        pump.Stop();
    }

    // =========================================================================
    // 6. RequestResize：在泵线程执行 + 旧句柄失效
    // =========================================================================
    std::printf("\n[6] RequestResize：泵线程执行，且让旧句柄失效\n");
    {
        FakeSource src;
        src.frame_cost = std::chrono::milliseconds(5);
        cq::PreviewPump pump(&src);
        Check(pump.Start().IsOk(), "Start()");
        pump.Request(Ticks(1));
        WaitUntil([&] {
            pump.Lock();
            const bool ok = pump.LatestLocked().seq >= 1;
            pump.Unlock();
            return ok;
        });
        uint64_t seq_before = 0;
        pump.Lock();
        seq_before = pump.LatestLocked().seq;
        pump.Unlock();

        Check(pump.RequestResize(640, 360).IsOk(), "RequestResize(640,360)");
        Check(WaitUntil([&] { return src.resize_calls >= 1; }), "Resize 被执行");
        Check(src.resize_thread != main_thread, "Resize 在泵线程执行（不是主线程）");
        Check(src.last_w == 640 && src.last_h == 360, "尺寸参数正确传递");

        WaitUntil([&] {
            pump.Lock();
            const bool ok = pump.LatestLocked().seq > seq_before;
            pump.Unlock();
            return ok;
        });
        pump.Lock();
        const cq::PreviewPump::Frame& f = pump.LatestLocked();
        Check(f.texture == nullptr, "Resize 后旧句柄作废（texture == nullptr）");
        Check(f.seq > seq_before, "seq 前进（消费者据此丢弃旧句柄）");
        pump.Unlock();
        pump.Stop();
    }

    // =========================================================================
    // 7. Stop / 重启
    // =========================================================================
    std::printf("\n[7] Stop 后不再渲染；可重启\n");
    {
        FakeSource src;
        src.frame_cost = std::chrono::milliseconds(5);
        cq::PreviewPump pump(&src);
        Check(pump.Start().IsOk(), "Start()");
        pump.Request(Ticks(1));
        WaitUntil([&] { return src.RenderedCount() >= 1; });
        pump.Stop();
        const size_t n = src.RenderedCount();
        pump.Request(Ticks(2));
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
        Check(src.RenderedCount() == n, "Stop 后 Request 不再触发渲染");

        Check(pump.Start().IsOk(), "重启 Start()");
        pump.Request(Ticks(3));
        Check(WaitUntil([&] { return src.RenderedCount() > n; }), "重启后恢复渲染");
        pump.Stop();
    }

    // =========================================================================
    // 8. 参数校验（不因为"内部用"就跳过边界）
    // =========================================================================
    std::printf("\n[8] 参数校验\n");
    {
        cq::PreviewPump null_pump(nullptr);
        Check(!null_pump.Start().IsOk(), "空帧源 Start() 失败（不静默成功）");
        FakeSource src;
        cq::PreviewPump pump(&src);
        Check(!pump.RequestResize(0, 100).IsOk(), "RequestResize(0,100) 被拒");
        Check(!pump.RequestResize(100, 0).IsOk(), "RequestResize(100,0) 被拒");
        // 未启动时 resize 也该被拒（没有线程执行它，静默入队会造成"明明改了没生效"）
        Check(!pump.RequestResize(100, 100).IsOk(), "未启动时 RequestResize 被拒");
    }

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
