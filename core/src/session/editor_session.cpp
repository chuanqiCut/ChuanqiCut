// ChuanqiCut — EditorSession 实现（CORE-009 + UIA-009 子步骤 1）

#include "cq/session/editor_session.h"

#include <utility>

#include "cq/command/command.h"
#include "cq/model/editor_model_state.h"

namespace cq {

EditorSession::EditorSession() : EditorSession(Config{}, nullptr) {}

EditorSession::EditorSession(Config cfg, ISessionState* state)
    : cfg_(cfg),
      state_(state),
      runner_(TaskRunner::Config{ThreadRole::kSession, cfg.queue_capacity, "cq-session"}),
      version_(0),
      digest_(0),
      running_(false) {
    // 未注入自定义状态时，内建真实模型状态（UIA-009 子步骤 1）：
    // 时间线 + 素材表 + 命令历史成为会话状态，digest 为真实指纹。
    if (state_ == nullptr) {
        builtin_model_ = std::make_shared<EditorModelState>();
        state_ = builtin_model_.get();
    }
    // 初始 digest 在构造时写入（版本 0 = 尚无变更，但状态已存在且可查）。
    // 此前语义是「未变更则 digest 0」——模型接入后 digest 必须从一开始就真实。
    digest_.store(state_->Digest(), std::memory_order_release);
}

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

// ---- 类型化模型提交（UIA-009 子步骤 1）------------------------------------
// 全部走 Submit 投递到 session 线程执行；Ok = 已入队，校验在 session 线程做
// （失败：版本不推进、观察者不回调）。

EditorModelState* EditorSession::BuiltinModel() const { return builtin_model_.get(); }

Status EditorSession::SubmitRegisterAsset(const char* name, uint64_t asset_id,
                                          const char* path) {
    EditorModelState* model = BuiltinModel();
    if (model == nullptr) return Status{StatusCode::kInternal};
    if (path == nullptr) return Status{StatusCode::kInvalidArgument};
    const std::string path_copy(path);  // 跨线程传递：先拷贝，调用方可立即释放
    return Submit(name, [model, asset_id, path_copy]() -> Status {
        return model->RegisterAsset(asset_id, path_copy);
    });
}

Status EditorSession::SubmitAddTrack(const char* name, TrackKind kind) {
    EditorModelState* model = BuiltinModel();
    if (model == nullptr) return Status{StatusCode::kInternal};
    return Submit(name, [model, kind]() -> Status {
        return model->Execute(std::make_unique<AddTrackCommand>(kind));
    });
}

Status EditorSession::SubmitAddClip(const char* name, uint64_t track_id, const Clip& clip) {
    EditorModelState* model = BuiltinModel();
    if (model == nullptr) return Status{StatusCode::kInternal};
    return Submit(name, [model, track_id, clip]() -> Status {
        return model->Execute(std::make_unique<InsertClipCommand>(track_id, clip));
    });
}

std::shared_ptr<const ModelSnapshot> EditorSession::CurrentModelSnapshot() const {
    EditorModelState* model = BuiltinModel();
    if (model == nullptr) return nullptr;
    // 只读已发布的不可变快照，任意线程安全。
    return model->CurrentSnapshot();
}

std::shared_ptr<const Timeline> EditorSession::CurrentTimeline() const {
    EditorModelState* model = BuiltinModel();
    if (model == nullptr) return nullptr;
    // 只读已发布的不可变快照（atomic load），任意线程安全。
    return model->CurrentTimeline();
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
