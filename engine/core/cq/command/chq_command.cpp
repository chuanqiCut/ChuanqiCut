// ChuanqiCut — Command 层实现（MODEL-002）
//
// 契约与不变量见 command.h 文件头。实现只有一条主线：
// 成功才入栈 / 出栈，失败保持历史与模型原状。

#include "cq/command/chq_command.h"

namespace cq {

// ===========================================================================
// ChqCommandHistory
// ===========================================================================

ChqStatus ChqCommandHistory::Execute(std::unique_ptr<ChqICommand> cmd, ChqTimeline& model) {
    if (!cmd) return ChqStatus(ChqStatusCode::kInvalidArgument);
    ChqStatus s = cmd->Do(model);
    if (!s.IsOk()) return s;  // 失败：不入栈，redo 分支保持原状
    undo_stack_.push_back(std::move(cmd));
    redo_stack_.clear();  // 线性历史：新变更丢弃 redo 分支
    return ChqStatus::Ok();
}

ChqStatus ChqCommandHistory::Undo(ChqTimeline& model) {
    if (undo_stack_.empty()) return ChqStatus(ChqStatusCode::kInvalidArgument);
    ChqICommand* cmd = undo_stack_.back().get();
    ChqStatus s = cmd->Undo(model);
    if (!s.IsOk()) return s;  // 不变量破坏：栈保持不变（测试守卫此路径）
    redo_stack_.push_back(std::move(undo_stack_.back()));
    undo_stack_.pop_back();
    return ChqStatus::Ok();
}

ChqStatus ChqCommandHistory::Redo(ChqTimeline& model) {
    if (redo_stack_.empty()) return ChqStatus(ChqStatusCode::kInvalidArgument);
    ChqICommand* cmd = redo_stack_.back().get();
    ChqStatus s = cmd->Redo(model);
    if (!s.IsOk()) return s;
    undo_stack_.push_back(std::move(redo_stack_.back()));
    redo_stack_.pop_back();
    return ChqStatus::Ok();
}

void ChqCommandHistory::Clear() {
    undo_stack_.clear();
    redo_stack_.clear();
}

// ===========================================================================
// ChqAddTrackCommand
// ===========================================================================

ChqStatus ChqAddTrackCommand::Do(ChqTimeline& model) {
    ChqStatus s = model.AddTrack(kind_, track_id_);
    if (!s.IsOk()) return s;
    if (!captured_) {
        const ChqTrack* track = model.FindTrack(track_id_);
        if (track == nullptr) return ChqStatus(ChqStatusCode::kInternal);
        snapshot_ = *track;
        captured_ = true;
    }
    return ChqStatus::Ok();
}

ChqStatus ChqAddTrackCommand::Redo(ChqTimeline& model) {
    // 重放 AddTrack 会分配新 id，历史里后续命令引用的 track_id_ 就悬空了。
    // 用首次 Do 捕获的快照恢复原 id（轨道内容此刻必为空，见不变量 3）。
    if (!captured_) return ChqStatus(ChqStatusCode::kInternal);
    return model.RestoreTrack(snapshot_);
}

ChqStatus ChqAddTrackCommand::Undo(ChqTimeline& model) {
    return model.RemoveTrack(track_id_);
}

// ===========================================================================
// ChqRemoveTrackCommand
// ===========================================================================

ChqStatus ChqRemoveTrackCommand::Do(ChqTimeline& model) {
    const ChqTrack* track = model.FindTrack(track_id_);
    if (track == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    snapshot_ = *track;  // 深拷贝（含全部片段）—— Undo 的唯一依据
    captured_ = true;
    return model.RemoveTrack(track_id_);
}

ChqStatus ChqRemoveTrackCommand::Undo(ChqTimeline& model) {
    if (!captured_) return ChqStatus(ChqStatusCode::kInternal);
    return model.RestoreTrack(snapshot_);
}

// ===========================================================================
// ChqInsertClipCommand
// ===========================================================================

ChqStatus ChqInsertClipCommand::Do(ChqTimeline& model) {
    uint64_t assigned = 0;
    ChqStatus s = model.InsertClip(track_id_, clip_, assigned);
    if (!s.IsOk()) return s;
    clip_id_ = assigned;
    return ChqStatus::Ok();
}

ChqStatus ChqInsertClipCommand::Redo(ChqTimeline& model) {
    if (clip_id_ == 0) return ChqStatus(ChqStatusCode::kInternal);
    ChqClip restored = clip_;
    restored.id = clip_id_;  // 放回原 id，保住后续命令的引用
    return model.RestoreClip(track_id_, restored);
}

ChqStatus ChqInsertClipCommand::Undo(ChqTimeline& model) {
    if (clip_id_ == 0) return ChqStatus(ChqStatusCode::kInternal);
    return model.RemoveClip(clip_id_);
}

// ===========================================================================
// ChqRemoveClipCommand
// ===========================================================================

ChqStatus ChqRemoveClipCommand::Do(ChqTimeline& model) {
    const ChqClip* clip = model.FindClip(clip_id_);
    if (clip == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    snapshot_ = *clip;
    // FindClip 不返回所属轨道，这里自行定位（供 Undo 放回原轨）。
    track_id_ = 0;
    for (const ChqTrack& track : model.Tracks()) {
        for (const ChqClip& c : track.clips) {
            if (c.id == clip_id_) {
                track_id_ = track.id;
                break;
            }
        }
        if (track_id_ != 0) break;
    }
    if (track_id_ == 0) return ChqStatus(ChqStatusCode::kInternal);
    captured_ = true;
    return model.RemoveClip(clip_id_);
}

ChqStatus ChqRemoveClipCommand::Undo(ChqTimeline& model) {
    if (!captured_) return ChqStatus(ChqStatusCode::kInternal);
    return model.RestoreClip(track_id_, snapshot_);
}

// ===========================================================================
// ChqMoveClipCommand
// ===========================================================================

ChqStatus ChqMoveClipCommand::Do(ChqTimeline& model) {
    const ChqClip* clip = model.FindClip(clip_id_);
    if (clip == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    old_start_ = clip->start;
    return model.MoveClip(clip_id_, new_start_);
}

ChqStatus ChqMoveClipCommand::Undo(ChqTimeline& model) {
    return model.MoveClip(clip_id_, old_start_);
}

// ===========================================================================
// ChqTrimClipCommand
// ===========================================================================

ChqStatus ChqTrimClipCommand::Do(ChqTimeline& model) {
    const ChqClip* clip = model.FindClip(clip_id_);
    if (clip == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    old_duration_ = clip->duration;
    return model.TrimClip(clip_id_, new_duration_);
}

ChqStatus ChqTrimClipCommand::Undo(ChqTimeline& model) {
    return model.TrimClip(clip_id_, old_duration_);
}

}  // namespace cq
