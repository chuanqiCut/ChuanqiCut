// ChuanqiCut — EditorSession 实现（CORE-009）

#include "cq/session/editor_session.h"

#include <utility>

namespace cq {

EditorSession::EditorSession() : EditorSession(Config{}, nullptr) {}

EditorSession::EditorSession(Config cfg, ISessionState* state)
    : cfg_(cfg),
      state_(state),
      runner_(TaskRunner::Config{ThreadRole::kSession, cfg.queue_capacity, "cq-session"}),
      version_(0),
      digest_(0),
      running_(false) {}

EditorSession::~EditorSession() { Shutdown(); }

Status EditorSession::Start() {
    bool expected = false;
    if (!running_.compare_exchange_strong(expected, true)) {
        return Status{StatusCode::kInvalidArgument};  // 已在运行
    }
    Status st = runner_.Start();
    if (!st.IsOk()) {
        running_.store(false, std::memory_order_release);
        return st;
    }
    return Status::Ok();
}

Status EditorSession::Shutdown() {
    running_.store(false, std::memory_order_release);
    return runner_.Shutdown();
}

Status EditorSession::Submit(const char* change_name, MutateFn mutate) {
    if (!running_.load(std::memory_order_acquire)) {
        return Status{StatusCode::kInvalidArgument};
    }
    // 名字须指向静态存储（ChangeRecord 不持有所有权），此处按约定直接透传。
    // name 为空串时用占位，避免下游空指针。
    const char* name = (change_name != nullptr) ? change_name : "";
    // 把变更包装成任务投递到 session 线程：**不阻塞调用线程**（D1）。
    return runner_.Post([this, name, mutate] { RunChange(name, mutate); });
}

void EditorSession::RunChange(const char* name, const MutateFn& mutate) {
    // 已在 session 线程（TaskRunner 的 worker 入口已打角色标记）。
    Status st = mutate();

    // D2：只有成功（含"非错误"的 Ok）才推进版本。失败与取消都不推进 ——
    // 否则 UI 会以为状态变了，去做一次无意义的刷新甚至错刷。
    if (!st.IsOk()) {
        return;
    }

    uint64_t new_version = version_.fetch_add(1, std::memory_order_acq_rel) + 1;

    // D4：digest 在 session 线程算好存入 atomic —— 读路径绝不跨线程调用 state。
    uint64_t new_digest = (state_ != nullptr) ? state_->Digest() : 0;
    digest_.store(new_digest, std::memory_order_release);

    {
        std::lock_guard<std::mutex> lk(records_mtx_);
        records_.push_back(ChangeRecord{new_version, name, st});
    }

    // 观察者回调同样在 session 线程（D1）：调用方自行转发到 UI 线程。
    if (observer_) {
        observer_(Snapshot{new_version, new_digest});
    }
}

Snapshot EditorSession::CurrentSnapshot() const {
    // 只读 atomic，不触碰 state_（D4）。
    return Snapshot{version_.load(std::memory_order_acquire),
                    digest_.load(std::memory_order_acquire)};
}

size_t EditorSession::ChangesSince(uint64_t from_version, std::vector<ChangeRecord>* out) const {
    if (out == nullptr) return 0;
    out->clear();
    std::lock_guard<std::mutex> lk(records_mtx_);
    for (const ChangeRecord& r : records_) {
        if (r.version > from_version) {
            out->push_back(r);
        }
    }
    return out->size();
}

size_t EditorSession::ChangeCount() const {
    std::lock_guard<std::mutex> lk(records_mtx_);
    return records_.size();
}

void EditorSession::SetSnapshotObserver(SnapshotObserver observer) {
    observer_ = std::move(observer);
}

bool EditorSession::IsRunning() const { return running_.load(std::memory_order_acquire); }

}  // namespace cq
