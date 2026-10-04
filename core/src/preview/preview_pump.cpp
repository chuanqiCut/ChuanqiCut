// ChuanqiCut — 预览取帧泵实现（UIA-010 子步骤 5）
//
// 契约与不变量见 preview_pump.h 的类注释，这里只写实现层面的取舍。
//
// 硬约束：内核禁用异常（ARCH-001），且 CocoaPods 侧的 Pods target 是显式
//   -fno-exceptions（实测：`cannot use 'try' with exceptions disabled`）。故这里
//   **不能**用 try/catch 包 std::thread 的构造 —— 与既有 TaskRunner 一致：
//   线程创建失败在禁异常构建下会 terminate，不做（也做不了）降级。

#include "cq/preview/preview_pump.h"

#include <new>
#include <utility>

namespace cq {

PreviewPump::PreviewPump(IPreviewFrameSource* source) : source_(source) {}

PreviewPump::~PreviewPump() { Stop(); }

Status PreviewPump::Start() {
    std::lock_guard<std::mutex> lk(mtx_);
    if (running_) return Status::Ok();
    if (source_ == nullptr) return Status(StatusCode::kInvalidArgument);
    stop_ = false;
    // ⚠️ 不用 try/catch（禁异常构建下连 try 都编译不过，见文件头）。
    //    创建失败在禁异常构建里会 terminate —— 与 TaskRunner 同策略，不假装能降级。
    worker_ = std::thread([this] { Loop(); });
    if (!worker_.joinable()) return Status(StatusCode::kResourceExhausted);
    running_ = true;
    return Status::Ok();
}

void PreviewPump::Stop() {
    {
        std::lock_guard<std::mutex> lk(mtx_);
        if (!running_) return;
        stop_ = true;
        running_ = false;
    }
    cv_.notify_one();
    if (worker_.joinable()) worker_.join();
    worker_ = std::thread();
}

bool PreviewPump::IsRunning() const {
    std::lock_guard<std::mutex> lk(mtx_);
    return running_;
}

void PreviewPump::Request(const RationalTime& pts) {
    {
        std::lock_guard<std::mutex> lk(mtx_);
        // 上一个请求还没被泵取走就被覆盖 = 那一帧永不渲染（丢帧）。
        if (has_request_) coalesced_.fetch_add(1, std::memory_order_relaxed);
        requested_pts_ = pts;
        has_request_ = true;
    }
    requested_.fetch_add(1, std::memory_order_relaxed);
    cv_.notify_one();
}

Status PreviewPump::RequestResize(uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) return Status(StatusCode::kInvalidArgument);
    {
        std::lock_guard<std::mutex> lk(mtx_);
        if (!running_) return Status(StatusCode::kInvalidArgument);
        resize_pending_ = true;
        resize_w_ = width;
        resize_h_ = height;
    }
    cv_.notify_one();
    return Status::Ok();
}

void PreviewPump::Lock() { mtx_.lock(); }

void PreviewPump::Unlock() { mtx_.unlock(); }

const PreviewPump::Frame& PreviewPump::LatestLocked() const { return published_; }

PreviewPump::Stats PreviewPump::GetStats() const {
    Stats s;
    s.requested = requested_.load(std::memory_order_relaxed);
    s.rendered = rendered_.load(std::memory_order_relaxed);
    s.coalesced = coalesced_.load(std::memory_order_relaxed);
    s.non_ok = non_ok_.load(std::memory_order_relaxed);
    return s;
}

void PreviewPump::Loop() {
    for (;;) {
        bool do_render = false;
        bool do_resize = false;
        RationalTime pts{0, 1};
        uint32_t w = 0;
        uint32_t h = 0;
        {
            std::unique_lock<std::mutex> lk(mtx_);
            cv_.wait(lk, [this] { return stop_ || has_request_ || resize_pending_; });
            if (stop_) return;
            if (resize_pending_) {
                do_resize = true;
                w = resize_w_;
                h = resize_h_;
                resize_pending_ = false;
            }
            if (has_request_) {
                do_render = true;
                pts = requested_pts_;
                has_request_ = false;
            }
        }

        // Resize 必须持锁执行：它会销毁旧 RT，而消费者可能正拿着旧句柄。
        if (do_resize) {
            std::lock_guard<std::mutex> lk(mtx_);
            const Status rs = source_->Resize(w, h);
            // 句柄失效要如实告知消费者：清空 frame 并推进 seq（seq 前进 = 旧句柄作废）。
            published_ = Frame{};
            published_.seq = ++seq_;
            if (!rs.IsOk()) non_ok_.fetch_add(1, std::memory_order_relaxed);
        }

        if (!do_render) continue;

        // ---- 唯一触碰解码会话 / 纹理缓存的地方（其余线程不得再调 RenderFrame）----
        TextureHandle tex = nullptr;
        CancelToken token;
        const Status s = source_->RenderFrame(pts, tex, token);
        if (!s.IsOk()) non_ok_.fetch_add(1, std::memory_order_relaxed);

        {
            std::lock_guard<std::mutex> lk(mtx_);
            published_.pts = pts;
            published_.texture = tex;
            published_.code = static_cast<int32_t>(s.code);
            published_.seq = ++seq_;
        }
        rendered_.fetch_add(1, std::memory_order_relaxed);
    }
}

}  // namespace cq
