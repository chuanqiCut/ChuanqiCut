// ChuanqiCut — ChqEditorSession 实现（CORE-009 + UIA-009 子步骤 1）

#include "cq/session/chq_editor_session.h"

#include <utility>

#include "cq/command/chq_command.h"
#include "cq/model/chq_editor_model_state.h"

namespace cq {

ChqEditorSession::ChqEditorSession() : ChqEditorSession(Config{}, nullptr) {}

ChqEditorSession::ChqEditorSession(Config cfg, ChqISessionState* state)
    : cfg_(cfg),
      state_(state),
      runner_(ChqTaskRunner::Config{ChqThreadRole::kSession, cfg.queue_capacity, "cq-session"}),
      version_(0),
      digest_(0),
      running_(false) {
    // 未注入自定义状态时，内建真实模型状态（UIA-009 子步骤 1）：
    // 时间线 + 素材表 + 命令历史成为会话状态，digest 为真实指纹。
    if (state_ == nullptr) {
        builtin_model_ = std::make_shared<ChqEditorModelState>();
        state_ = builtin_model_.get();
    }
    // 初始 digest 在构造时写入（版本 0 = 尚无变更，但状态已存在且可查）。
    // 此前语义是「未变更则 digest 0」——模型接入后 digest 必须从一开始就真实。
    digest_.store(state_->Digest(), std::memory_order_release);
}

ChqEditorSession::~ChqEditorSession() { Shutdown(); }

ChqStatus ChqEditorSession::Start() {
    bool expected = false;
    if (!running_.compare_exchange_strong(expected, true)) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};  // 已在运行
    }
    ChqStatus st = runner_.Start();
    if (!st.IsOk()) {
        running_.store(false, std::memory_order_release);
        return st;
    }
    return ChqStatus::Ok();
}

ChqStatus ChqEditorSession::Shutdown() {
    running_.store(false, std::memory_order_release);
    return runner_.Shutdown();
}

ChqStatus ChqEditorSession::Submit(const char* change_name, ChqMutateFn mutate) {
    if (!running_.load(std::memory_order_acquire)) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};
    }
    // 名字须指向静态存储（ChqChangeRecord 不持有所有权），此处按约定直接透传。
    // name 为空串时用占位，避免下游空指针。
    const char* name = (change_name != nullptr) ? change_name : "";
    // 把变更包装成任务投递到 session 线程：**不阻塞调用线程**（D1）。
    return runner_.Post([this, name, mutate] { RunChange(name, mutate); });
}

void ChqEditorSession::RunChange(const char* name, const ChqMutateFn& mutate) {
    // 已在 session 线程（ChqTaskRunner 的 worker 入口已打角色标记）。
    ChqStatus st = mutate();

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
        records_.push_back(ChqChangeRecord{new_version, name, st});
    }

    // 观察者回调同样在 session 线程（D1）：调用方自行转发到 UI 线程。
    if (observer_) {
        observer_(ChqSnapshot{new_version, new_digest});
    }
}

ChqSnapshot ChqEditorSession::CurrentSnapshot() const {
    // 只读 atomic，不触碰 state_（D4）。
    return ChqSnapshot{version_.load(std::memory_order_acquire),
                    digest_.load(std::memory_order_acquire)};
}

// ---- 类型化模型提交（UIA-009 子步骤 1）------------------------------------
// 全部走 Submit 投递到 session 线程执行；Ok = 已入队，校验在 session 线程做
// （失败：版本不推进、观察者不回调）。

ChqEditorModelState* ChqEditorSession::BuiltinModel() const { return builtin_model_.get(); }

ChqStatus ChqEditorSession::SubmitRegisterAsset(const char* name, uint64_t asset_id,
                                          const char* path) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    if (path == nullptr) return ChqStatus{ChqStatusCode::kInvalidArgument};
    const std::string path_copy(path);  // 跨线程传递：先拷贝，调用方可立即释放
    return Submit(name, [model, asset_id, path_copy]() -> ChqStatus {
        return model->RegisterAsset(asset_id, path_copy);
    });
}

ChqStatus ChqEditorSession::SubmitAddTrack(const char* name, ChqTrackKind kind) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    return Submit(name, [model, kind]() -> ChqStatus {
        return model->Execute(std::make_unique<ChqAddTrackCommand>(kind));
    });
}

ChqStatus ChqEditorSession::SubmitAddClip(const char* name, uint64_t track_id, const ChqClip& clip) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    return Submit(name, [model, track_id, clip]() -> ChqStatus {
        return model->Execute(std::make_unique<ChqInsertClipCommand>(track_id, clip));
    });
}

ChqStatus ChqEditorSession::SubmitMoveClip(const char* name, uint64_t clip_id,
                                     const ChqRationalTime& start) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    if (start.timescale <= 0) return ChqStatus{ChqStatusCode::kInvalidArgument};
    return Submit(name, [model, clip_id, start]() -> ChqStatus {
        return model->Execute(std::make_unique<ChqMoveClipCommand>(clip_id, start));
    });
}

ChqStatus ChqEditorSession::SubmitTrimClip(const char* name, uint64_t clip_id,
                                     const ChqRationalTime& duration) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    if (duration.timescale <= 0) return ChqStatus{ChqStatusCode::kInvalidArgument};
    return Submit(name, [model, clip_id, duration]() -> ChqStatus {
        return model->Execute(std::make_unique<ChqTrimClipCommand>(clip_id, duration));
    });
}

ChqStatus ChqEditorSession::SubmitSplitClip(const char* name, uint64_t clip_id,
                                      const ChqRationalTime& at) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    if (at.timescale <= 0) return ChqStatus{ChqStatusCode::kInvalidArgument};
    return Submit(name, [model, clip_id, at]() -> ChqStatus {
        return model->Execute(std::make_unique<ChqSplitClipCommand>(clip_id, at));
    });
}

ChqStatus ChqEditorSession::SubmitRemoveClip(const char* name, uint64_t clip_id) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    return Submit(name, [model, clip_id]() -> ChqStatus {
        return model->Execute(std::make_unique<ChqRemoveClipCommand>(clip_id));
    });
}

ChqStatus ChqEditorSession::SubmitRemoveTrack(const char* name, uint64_t track_id) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    return Submit(name, [model, track_id]() -> ChqStatus {
        return model->Execute(std::make_unique<ChqRemoveTrackCommand>(track_id));
    });
}

ChqStatus ChqEditorSession::SubmitTrimClipIn(const char* name, uint64_t clip_id,
                                       const ChqRationalTime& new_start) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    if (new_start.timescale <= 0) return ChqStatus{ChqStatusCode::kInvalidArgument};
    return Submit(name, [model, clip_id, new_start]() -> ChqStatus {
        return model->Execute(std::make_unique<ChqTrimClipInCommand>(clip_id, new_start));
    });
}

ChqStatus ChqEditorSession::SubmitMoveClipToTrack(const char* name, uint64_t clip_id,
                                            uint64_t target_track_id,
                                            const ChqRationalTime& new_start) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    if (new_start.timescale <= 0) return ChqStatus{ChqStatusCode::kInvalidArgument};
    return Submit(name, [model, clip_id, target_track_id, new_start]() -> ChqStatus {
        return model->Execute(
            std::make_unique<ChqMoveClipToTrackCommand>(clip_id, target_track_id, new_start));
    });
}

ChqStatus ChqEditorSession::SubmitSetCanvas(const char* name, int32_t width, int32_t height) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    return Submit(name, [model, width, height]() -> ChqStatus {
        return model->Execute(std::make_unique<ChqSetCanvasCommand>(width, height));
    });
}

ChqStatus ChqEditorSession::SubmitUndo(const char* name) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    return Submit(name, [model]() -> ChqStatus { return model->Undo(); });
}

ChqStatus ChqEditorSession::SubmitRedo(const char* name) {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return ChqStatus{ChqStatusCode::kInternal};
    return Submit(name, [model]() -> ChqStatus { return model->Redo(); });
}

bool ChqEditorSession::CanUndo() const {
    ChqEditorModelState* model = BuiltinModel();
    return (model != nullptr) ? model->CanUndo() : false;
}

bool ChqEditorSession::CanRedo() const {
    ChqEditorModelState* model = BuiltinModel();
    return (model != nullptr) ? model->CanRedo() : false;
}

std::shared_ptr<const ChqModelSnapshot> ChqEditorSession::CurrentModelSnapshot() const {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return nullptr;
    // 只读已发布的不可变快照，任意线程安全。
    return model->CurrentSnapshot();
}

std::shared_ptr<const ChqTimeline> ChqEditorSession::CurrentTimeline() const {
    ChqEditorModelState* model = BuiltinModel();
    if (model == nullptr) return nullptr;
    // 只读已发布的不可变快照（atomic load），任意线程安全。
    return model->CurrentTimeline();
}

size_t ChqEditorSession::ChangesSince(uint64_t from_version, std::vector<ChqChangeRecord>* out) const {
    if (out == nullptr) return 0;
    out->clear();
    std::lock_guard<std::mutex> lk(records_mtx_);
    for (const ChqChangeRecord& r : records_) {
        if (r.version > from_version) {
            out->push_back(r);
        }
    }
    return out->size();
}

size_t ChqEditorSession::ChangeCount() const {
    std::lock_guard<std::mutex> lk(records_mtx_);
    return records_.size();
}

void ChqEditorSession::SetSnapshotObserver(ChqSnapshotObserver observer) {
    observer_ = std::move(observer);
}

bool ChqEditorSession::IsRunning() const { return running_.load(std::memory_order_acquire); }

}  // namespace cq
