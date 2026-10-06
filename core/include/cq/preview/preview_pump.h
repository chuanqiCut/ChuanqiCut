// ChuanqiCut — 预览取帧泵（UIA-010 子步骤 5）
//
// 解决什么：MVP 的 `cq_preview_render_frame` 是**同步**的 —— 谁调用谁承担
// seek + 解码 + 导入 + 等 GPU 的全部耗时。UI 在主线程调用它，就等价于把主线程
// 按单帧耗时（实测见 .ai/memory/baselines.md）堵住一次，播放时每帧堵一次。
//
// 本类把这条链路搬到自己的线程上：
//   UI 线程          —— 只做「请求 pts」和「把已完成的帧 blit 进 drawable + present」
//   泵线程（本类）   —— 取帧 / 导入 / 离屏绘制，全部在此
//
// ⚠️ 它**不提高帧率**：帧率上限仍是 1/单帧取帧耗时。它做的是把这份耗时从主线程
//    挪走（UI 不再被堵）。要提帧率得做 read-ahead 预解码，那是另一件事
//    （MODEL/渲染层有解码缓存机制后才谈）。别把这两件事混为一谈。
//
// ── 请求合并（coalescing）──
//   请求速率 > 渲染速率时必须丢帧，否则队列无界增长（背压铁律）。这里取最新：
//   新请求直接覆盖未取走的请求，被覆盖者永不被渲染（计入 `Stats::coalesced`）。
//   时刻由墙钟算（PlayerClock），丢帧只让画面少几张，**不会**让播放变快或变慢。
//
//   ⚠️ 与 UIA-005 拒绝的「命令合并」不是一回事：那里合并会丢掉用户的一次编辑
//      （撤销栈必须有这条记录），这里合并丢的是「某一时刻的画面」，而画面本来就
//      是时间的函数、重算即得。两个相反的决定，理由是相反的。
//
// ── 消费协议（Lock / Unlock）──
//   已发布帧的纹理句柄在两种情况下失效：(a) 下一次渲染不会换句柄（RT 复用，
//   内容会被覆盖）；(b) `RequestResize` 会**销毁** RT —— 这时旧句柄是悬垂指针。
//   故消费者取句柄必须走：
//       pump.Lock();  const Frame& f = pump.LatestLocked();  /* blit */  pump.Unlock();
//   持锁期间泵线程不会发布新帧、不会 resize → 句柄稳定。
//
//   ⚠️ 两条会真的出事的用法（都是在本类的第一版测试里实打实踩出来的，不是假想）：
//     (1) **持锁期间调 Request / RequestResize** —— 它们也要拿同一把锁 → 死锁。
//     (2) 持锁期间做阻塞等待（如 GPU waitUntilCompleted）—— 会把泵线程一起堵住。
//   正确顺序：先 Request，再 Lock → blit → Unlock。
//
// ── 跨队列顺序（为什么要共享命令队列）──
//   泵线程的渲染与 UI 线程的 blit 若各用一条 MTLCommandQueue，Metal **不保证**
//   两者对同一纹理的先后（跨队列需显式 MTLSharedEvent / MTLFence）。故 UI 侧
//   的 blit 必须用内核的同一条队列（见 `cq_preview_shared_queue`），由 commit
//   顺序保证「先写完再读」。这是把渲染挪走能成立的前提，不是可选项。
//
// 线程安全：`Request` / `RequestResize` / `GetStats` / `IsRunning` 可任意线程调用。
// `Lock` / `LatestLocked` / `Unlock` 是消费协议，见上。

#ifndef CQ_PREVIEW_PREVIEW_PUMP_H_
#define CQ_PREVIEW_PREVIEW_PUMP_H_

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/pal/common.h"  // TextureHandle
#include "cq/preview/preview_frame_source.h"

namespace cq {

class PreviewPump {
public:
    // 一次已完成的渲染结果。`seq` 单调递增，0 表示「还没有任何帧」。
    struct Frame {
        RationalTime pts{0, 1};
        TextureHandle texture = nullptr;  // 中性句柄；nullptr = 该帧渲染失败
        int32_t code = 0;                 // 内核状态码（0=kOk，1001=空隙，…）
        uint64_t seq = 0;
    };

    struct Stats {
        uint64_t requested = 0;  // 收到的请求总数
        uint64_t rendered = 0;   // 实际执行过的渲染次数
        uint64_t coalesced = 0;  // 被后续请求覆盖、从未进入渲染的请求数
        uint64_t non_ok = 0;     // 非 Ok 返回的渲染次数（含空隙 kIoNotFound）
    };

    // `source` 为**非拥有**指针，且从此刻起只由泵线程访问（见类注释）。
    explicit PreviewPump(IPreviewFrameSource* source);
    ~PreviewPump();

    PreviewPump(const PreviewPump&) = delete;
    PreviewPump& operator=(const PreviewPump&) = delete;

    Status Start();
    // 停止并回收线程。会等待当前这一帧渲染完（≤ 1 帧耗时），不是在半帧处强杀。
    void Stop();
    bool IsRunning() const;

    // 请求渲染 pts 处一帧。未取走的请求会被后续请求覆盖（合并，见类注释）。
    void Request(const RationalTime& pts);

    // 请求改变离屏目标尺寸。**在泵线程执行**（RT 只能由持有它的线程销毁）。
    Status RequestResize(uint32_t width, uint32_t height);

    // ---- 消费协议：Lock() → LatestLocked() → blit → Unlock() ----
    void Lock();
    void Unlock();
    const Frame& LatestLocked() const;

    Stats GetStats() const;

private:
    void Loop();

    IPreviewFrameSource* source_ = nullptr;

    mutable std::mutex mtx_;
    std::condition_variable cv_;

    Frame published_;
    uint64_t seq_ = 0;

    bool has_request_ = false;
    RationalTime requested_pts_{0, 1};

    bool resize_pending_ = false;
    uint32_t resize_w_ = 0;
    uint32_t resize_h_ = 0;

    bool running_ = false;
    bool stop_ = false;

    std::thread worker_;

    std::atomic<uint64_t> requested_{0};
    std::atomic<uint64_t> rendered_{0};
    std::atomic<uint64_t> coalesced_{0};
    std::atomic<uint64_t> non_ok_{0};

#ifndef NDEBUG
    // MEDIA-023 排障仪器（Debug only）：分段耗时样本（acquire/import/draw/total），
    // 每 60 帧打印直方图。
    std::vector<IPreviewFrameSource::StageTimings> stage_samples_;
    // 看门狗：渲染卡在某段 >1s 时打印段名与耗时（析构式警报对"永不返回"失明）。
    void WatchdogLoop();
    std::thread watchdog_;
#endif
};

}  // namespace cq

#endif  // CQ_PREVIEW_PREVIEW_PUMP_H_
