// ChuanqiCut — Command 层实现（MODEL-002）
//
// 契约与不变量见 command.h 文件头。实现只有一条主线：
// 成功才入栈 / 出栈，失败保持历史与模型原状。

#include "cq/command/command.h"

namespace cq {

// ===========================================================================
// CommandHistory
// ===========================================================================

Status CommandHistory::Execute(std::unique_ptr<ICommand> cmd, Timeline& model) {
    if (!cmd) return Status(StatusCode::kInvalidArgument);
    Status s = cmd->Do(model);
    if (!s.IsOk()) return s;  // 失败：不入栈，redo 分支保持原状
    undo_stack_.push_back(std::move(cmd));
    redo_stack_.clear();  // 线性历史：新变更丢弃 redo 分支
    return Status::Ok();
}

Status CommandHistory::Undo(Timeline& model) {
    if (undo_stack_.empty()) return Status(StatusCode::kInvalidArgument);
    ICommand* cmd = undo_stack_.back().get();
    Status s = cmd->Undo(model);
    if (!s.IsOk()) return s;  // 不变量破坏：栈保持不变（测试守卫此路径）
    redo_stack_.push_back(std::move(undo_stack_.back()));
    undo_stack_.pop_back();
    return Status::Ok();
}

Status CommandHistory::Redo(Timeline& model) {
    if (redo_stack_.empty()) return Status(StatusCode::kInvalidArgument);
    ICommand* cmd = redo_stack_.back().get();
    Status s = cmd->Redo(model);
    if (!s.IsOk()) return s;
    undo_stack_.push_back(std::move(redo_stack_.back()));
    redo_stack_.pop_back();
    return Status::Ok();
}

void CommandHistory::Clear() {
    undo_stack_.clear();
    redo_stack_.clear();
}

// ===========================================================================
// AddTrackCommand
// ===========================================================================

Status AddTrackCommand::Do(Timeline& model) {
    Status s = model.AddTrack(kind_, track_id_);
    if (!s.IsOk()) return s;
    if (!captured_) {
        const Track* track = model.FindTrack(track_id_);
        if (track == nullptr) return Status(StatusCode::kInternal);
        snapshot_ = *track;
        captured_ = true;
    }
    return Status::Ok();
}

Status AddTrackCommand::Redo(Timeline& model) {
    // 重放 AddTrack 会分配新 id，历史里后续命令引用的 track_id_ 就悬空了。
    // 用首次 Do 捕获的快照恢复原 id（轨道内容此刻必为空，见不变量 3）。
    if (!captured_) return Status(StatusCode::kInternal);
    return model.RestoreTrack(snapshot_);
}

Status AddTrackCommand::Undo(Timeline& model) {
    return model.RemoveTrack(track_id_);
}

// ===========================================================================
// RemoveTrackCommand
// ===========================================================================

Status RemoveTrackCommand::Do(Timeline& model) {
    const Track* track = model.FindTrack(track_id_);
    if (track == nullptr) return Status(StatusCode::kInvalidArgument);
    snapshot_ = *track;  // 深拷贝（含全部片段）—— Undo 的唯一依据
    captured_ = true;
    return model.RemoveTrack(track_id_);
}

Status RemoveTrackCommand::Undo(Timeline& model) {
    if (!captured_) return Status(StatusCode::kInternal);
    return model.RestoreTrack(snapshot_);
}

// ===========================================================================
// InsertClipCommand
// ===========================================================================

Status InsertClipCommand::Do(Timeline& model) {
    uint64_t assigned = 0;
    Status s = model.InsertClip(track_id_, clip_, assigned);
    if (!s.IsOk()) return s;
    clip_id_ = assigned;
    return Status::Ok();
}

Status InsertClipCommand::Redo(Timeline& model) {
    if (clip_id_ == 0) return Status(StatusCode::kInternal);
    Clip restored = clip_;
    restored.id = clip_id_;  // 放回原 id，保住后续命令的引用
    return model.RestoreClip(track_id_, restored);
}

Status InsertClipCommand::Undo(Timeline& model) {
    if (clip_id_ == 0) return Status(StatusCode::kInternal);
    return model.RemoveClip(clip_id_);
}

// ===========================================================================
// RemoveClipCommand
// ===========================================================================

Status RemoveClipCommand::Do(Timeline& model) {
    const Clip* clip = model.FindClip(clip_id_);
    if (clip == nullptr) return Status(StatusCode::kInvalidArgument);
    snapshot_ = *clip;
    // FindClip 不返回所属轨道，这里自行定位（供 Undo 放回原轨）。
    track_id_ = 0;
    for (const Track& track : model.Tracks()) {
        for (const Clip& c : track.clips) {
            if (c.id == clip_id_) {
                track_id_ = track.id;
                break;
            }
        }
        if (track_id_ != 0) break;
    }
    if (track_id_ == 0) return Status(StatusCode::kInternal);
    captured_ = true;
    return model.RemoveClip(clip_id_);
}

Status RemoveClipCommand::Undo(Timeline& model) {
    if (!captured_) return Status(StatusCode::kInternal);
    return model.RestoreClip(track_id_, snapshot_);
}

// ===========================================================================
// MoveClipCommand
// ===========================================================================

Status MoveClipCommand::Do(Timeline& model) {
    const Clip* clip = model.FindClip(clip_id_);
    if (clip == nullptr) return Status(StatusCode::kInvalidArgument);
    old_start_ = clip->start;
    return model.MoveClip(clip_id_, new_start_);
}

Status MoveClipCommand::Undo(Timeline& model) {
    return model.MoveClip(clip_id_, old_start_);
}

// ===========================================================================
// TrimClipCommand
// ===========================================================================

Status TrimClipCommand::Do(Timeline& model) {
    const Clip* clip = model.FindClip(clip_id_);
    if (clip == nullptr) return Status(StatusCode::kInvalidArgument);
    old_duration_ = clip->duration;
    return model.TrimClip(clip_id_, new_duration_);
}

Status TrimClipCommand::Undo(Timeline& model) {
    return model.TrimClip(clip_id_, old_duration_);
}

}  // namespace cq
