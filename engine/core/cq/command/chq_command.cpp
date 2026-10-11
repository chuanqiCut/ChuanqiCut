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
// ChqSplitClipCommand
// ===========================================================================

ChqStatus ChqSplitClipCommand::Do(ChqTimeline& model) {
    const ChqClip* left = model.FindClip(clip_id_);
    if (left == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    left_before_ = *left;

    uint64_t right_id = 0;
    ChqStatus s = model.SplitClip(clip_id_, at_, right_id);
    if (!s.IsOk()) return s;
    right_id_ = right_id;

    // Redo 的全部输入此刻一次性捕获；任一取不到即内部不变量被破坏。
    const ChqClip* left_after = model.FindClip(clip_id_);
    const ChqClip* right_after = model.FindClip(right_id_);
    if (left_after == nullptr || right_after == nullptr) {
        return ChqStatus(ChqStatusCode::kInternal);
    }
    track_id_ = 0;
    for (const ChqTrack& track : model.Tracks()) {
        for (const ChqClip& c : track.clips) {
            if (c.id == right_id_) {
                track_id_ = track.id;
                break;
            }
        }
        if (track_id_ != 0) break;
    }
    if (track_id_ == 0) return ChqStatus(ChqStatusCode::kInternal);
    left_after_ = *left_after;
    right_after_ = *right_after;
    captured_ = true;
    return ChqStatus::Ok();
}

ChqStatus ChqSplitClipCommand::Undo(ChqTimeline& model) {
    if (!captured_) return ChqStatus(ChqStatusCode::kInternal);
    // 先删右半再还原左半：左半还原后的占位覆盖右半位置，顺序反了会被判重叠。
    ChqStatus s = model.RemoveClip(right_id_);
    if (!s.IsOk()) return s;
    return model.ReplaceClip(left_before_);
}

ChqStatus ChqSplitClipCommand::Redo(ChqTimeline& model) {
    if (!captured_) return ChqStatus(ChqStatusCode::kInternal);
    // 重放 Do 会给右半分配新 id，历史里后续命令的引用会悬空 ——
    // 用 Do 时捕获的快照恢复原 id（与 Insert/Remove 同一纪律）。
    ChqStatus s = model.ReplaceClip(left_after_);
    if (!s.IsOk()) return s;
    return model.RestoreClip(track_id_, right_after_);
}

// ===========================================================================
// ChqTrimClipInCommand（左缘裁剪）
// ===========================================================================

ChqStatus ChqTrimClipInCommand::Do(ChqTimeline& model) {
    const ChqClip* clip = model.FindClip(clip_id_);
    if (clip == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    // 右缘不动：Δ = new_start - start，同时落到媒体侧（source_in += Δ）
    // 与时间线侧（duration -= Δ）。任一步算术失败即整体失败，模型不动。
    old_clip_ = *clip;
    ChqRationalTime delta;
    ChqStatus s = SubRational(new_start_, clip->start, delta);
    if (!s.IsOk()) return s;
    ChqRationalTime new_source_in;
    s = AddRational(clip->source.source_in, delta, new_source_in);
    if (!s.IsOk()) return s;
    ChqRationalTime new_duration;
    s = SubRational(clip->duration, delta, new_duration);
    if (!s.IsOk()) return s;
    // 媒体窗口与时间线占时同步收缩（与 SplitClip 同纪律）—— 否则 media ref
    // 声称的窗口比片段实际使用的更长，解码/导出会读进不会显示的帧。
    ChqRationalTime new_source_duration;
    s = SubRational(clip->source.source_duration, delta, new_source_duration);
    if (!s.IsOk()) return s;

    new_clip_ = *clip;
    new_clip_.start = new_start_;
    new_clip_.source.source_in = new_source_in;
    new_clip_.source.source_duration = new_source_duration;
    new_clip_.duration = new_duration;
    captured_ = true;

    // 校验（duration > 0 / source_in >= 0 / 同轨不重叠）全在 ReplaceClip 内；
    // 失败时模型未变更，历史不收这条命令。
    return model.ReplaceClip(new_clip_);
}

ChqStatus ChqTrimClipInCommand::Undo(ChqTimeline& model) {
    if (!captured_) return ChqStatus(ChqStatusCode::kInternal);
    return model.ReplaceClip(old_clip_);
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
