// ChuanqiCut — 时间线数据模型实现（MODEL-001）
//
// 时间运算一律走 base 层的 AddRational / CompareRational（跨 timescale 由它们
// 以最小公倍数对齐），**不**直接对 value 做算术 —— 否则 timescale 不同时会算错。

#include "cq/model/chq_timeline.h"

#include <algorithm>  // std::sort（移动片段后重排）

namespace cq {

// ===========================================================================
// ChqClip
// ===========================================================================

ChqStatus ChqClip::End(ChqRationalTime& out) const {
    return AddRational(start, duration, out);
}

// ===========================================================================
// 轨道
// ===========================================================================

ChqStatus ChqTimeline::AddTrack(ChqTrackKind kind, uint64_t& out_id) {
    ChqTrack track;
    track.id = next_id_++;
    track.kind = kind;
    tracks_.push_back(track);
    out_id = track.id;
    return ChqStatus::Ok();
}

ChqStatus ChqTimeline::RemoveTrack(uint64_t track_id) {
    for (auto it = tracks_.begin(); it != tracks_.end(); ++it) {
        if (it->id == track_id) {
            tracks_.erase(it);
            return ChqStatus::Ok();
        }
    }
    return ChqStatus(ChqStatusCode::kInvalidArgument);
}

const ChqTrack* ChqTimeline::FindTrack(uint64_t track_id) const {
    for (const ChqTrack& track : tracks_) {
        if (track.id == track_id) return &track;
    }
    return nullptr;
}

// ===========================================================================
// 片段
// ===========================================================================

ChqStatus ChqTimeline::InsertClip(uint64_t track_id, const ChqClip& clip, uint64_t& out_id) {
    ChqTrack* track = nullptr;
    for (ChqTrack& t : tracks_) {
        if (t.id == track_id) { track = &t; break; }
    }
    if (track == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    // 轨道类型必须匹配：音频片段放视频轨会让后续混音/渲染分支到处做类型判断。
    const ChqClipKind expected = (track->kind == ChqTrackKind::kVideo) ? ChqClipKind::kVideo
                                                                 : ChqClipKind::kAudio;
    if (clip.kind != expected) return ChqStatus(ChqStatusCode::kInvalidArgument);

    // 时长必须为正（零时长片段在时间线上没有意义，且会让命中测试含糊）。
    if (clip.duration.value <= 0 || clip.duration.timescale <= 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }

    // 同轨不允许重叠
    if (overlaps_in_track(*track, clip, nullptr)) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }

    ChqClip inserted = clip;
    inserted.id = next_id_++;
    // 保持按 start 升序，便于命中测试与顺序遍历。
    auto pos = track->clips.begin();
    while (pos != track->clips.end() && CompareRational(pos->start, inserted.start) <= 0) {
        ++pos;
    }
    track->clips.insert(pos, inserted);
    out_id = inserted.id;
    return ChqStatus::Ok();
}

ChqStatus ChqTimeline::RemoveClip(uint64_t clip_id) {
    ChqTrack* track = nullptr;
    find_clip_mut(clip_id, track);
    if (track == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    for (auto it = track->clips.begin(); it != track->clips.end(); ++it) {
        if (it->id == clip_id) {
            track->clips.erase(it);
            return ChqStatus::Ok();
        }
    }
    return ChqStatus(ChqStatusCode::kInvalidArgument);
}

ChqStatus ChqTimeline::MoveClip(uint64_t clip_id, const ChqRationalTime& new_start) {
    ChqTrack* track = nullptr;
    ChqClip* clip = find_clip_mut(clip_id, track);
    if (clip == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    ChqClip candidate = *clip;
    candidate.start = new_start;
    // 排除自身：否则「原地移动」会被判成跟自己重叠。
    if (overlaps_in_track(*track, candidate, clip)) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    clip->start = new_start;
    // 位置变了，重新排序
    std::vector<ChqClip> sorted;
    sorted.reserve(track->clips.size());
    for (const ChqClip& c : track->clips) sorted.push_back(c);
    std::sort(sorted.begin(), sorted.end(),
              [](const ChqClip& a, const ChqClip& b) {
                  return CompareRational(a.start, b.start) < 0;
              });
    track->clips = sorted;
    return ChqStatus::Ok();
}

ChqStatus ChqTimeline::TrimClip(uint64_t clip_id, const ChqRationalTime& new_duration) {
    ChqTrack* track = nullptr;
    ChqClip* clip = find_clip_mut(clip_id, track);
    if (clip == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    if (new_duration.value <= 0 || new_duration.timescale <= 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }

    ChqClip candidate = *clip;
    candidate.duration = new_duration;
    if (overlaps_in_track(*track, candidate, clip)) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    clip->duration = new_duration;
    return ChqStatus::Ok();
}

ChqStatus ChqTimeline::ReplaceClip(const ChqClip& clip) {
    ChqTrack* track = nullptr;
    ChqClip* existing = find_clip_mut(clip.id, track);
    if (existing == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    // kind 必须匹配所在轨道（与 Insert 同规则：音频片段不能原地变成视频）。
    const ChqClipKind expected = (track->kind == ChqTrackKind::kVideo) ? ChqClipKind::kVideo
                                                                 : ChqClipKind::kAudio;
    if (clip.kind != expected) return ChqStatus(ChqStatusCode::kInvalidArgument);
    if (clip.duration.value <= 0 || clip.duration.timescale <= 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    // 素材内入点不能早于素材起点（左缘裁剪拖过头的第一道防线）。
    if (clip.source.source_in.value < 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    if (overlaps_in_track(*track, clip, existing)) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }

    *existing = clip;
    // start 可变（左缘裁剪），维持轨内按 start 升序的不变量。
    std::sort(track->clips.begin(), track->clips.end(),
              [](const ChqClip& a, const ChqClip& b) {
                  return CompareRational(a.start, b.start) < 0;
              });
    return ChqStatus::Ok();
}

ChqStatus ChqTimeline::SplitClip(uint64_t clip_id, const ChqRationalTime& at,
                                 uint64_t& out_right_id) {
    ChqTrack* track = nullptr;
    ChqClip* clip = find_clip_mut(clip_id, track);
    if (clip == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);

    // ---- 先算术后变更：任何一步失败都不得动模型 ----
    ChqRationalTime end;
    ChqStatus s = clip->End(end);
    if (!s.IsOk()) return s;
    // 严格内开区间：切在 start / end 边界上等于没切（右半时长为零）。
    if (CompareRational(at, clip->start) <= 0 || CompareRational(at, end) >= 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }

    ChqRationalTime delta;  // 左半时长 = at - start，也是右半的媒体偏移量
    s = SubRational(at, clip->start, delta);
    if (!s.IsOk()) return s;
    ChqRationalTime right_source_in;
    s = AddRational(clip->source.source_in, delta, right_source_in);
    if (!s.IsOk()) return s;
    ChqRationalTime right_source_duration;
    s = SubRational(clip->source.source_duration, delta, right_source_duration);
    if (!s.IsOk()) return s;
    ChqRationalTime right_duration;  // 右半时长 = end - at（delta 是左半的，别拿错）
    s = SubRational(end, at, right_duration);
    if (!s.IsOk()) return s;

    // ---- 变更段：左半原位收缩，右半构造后插入 ----
    const ChqTransitionKind orig_out_transition = clip->out_transition;  // 回滚留档
    ChqClip right = *clip;
    right.id = next_id_++;
    right.start = at;
    right.duration = right_duration;
    right.source.source_in = right_source_in;
    right.source.source_duration = right_source_duration;
    // 分割点是媒体中段的切线：两侧的转场边界随之作废（出转场归左、入转场归右，
    // 但都不再挂在切线上）。transition_duration 不动 —— 当前 setter 只产生 kNone，
    // 引入非 kNone 转场时再补「共享 duration 的归属」语义。
    clip->duration = delta;
    clip->out_transition = ChqTransitionKind::kNone;
    right.in_transition = ChqTransitionKind::kNone;

    // 左半已收缩为 [start, at)，与右半 [at, end) 首尾相接不构成重叠；
    // 排除左半后只需验证右半与更远的邻居不冲突。
    if (overlaps_in_track(*track, right, clip)) {
        // 理论不可达（右半落在原片段占位内），防御性回滚左半。
        ChqRationalTime orig_duration;
        if (SubRational(end, clip->start, orig_duration).IsOk()) {
            clip->duration = orig_duration;
            clip->out_transition = orig_out_transition;
        }
        return ChqStatus(ChqStatusCode::kInternal);
    }

    auto pos = track->clips.begin();
    while (pos != track->clips.end() && CompareRational(pos->start, right.start) <= 0) {
        ++pos;
    }
    track->clips.insert(pos, right);
    out_right_id = right.id;
    return ChqStatus::Ok();
}

const ChqClip* ChqTimeline::FindClip(uint64_t clip_id) const {
    for (const ChqTrack& track : tracks_) {
        for (const ChqClip& clip : track.clips) {
            if (clip.id == clip_id) return &clip;
        }
    }
    return nullptr;
}

const ChqClip* ChqTimeline::FindClipAt(uint64_t track_id, const ChqRationalTime& t) const {
    const ChqTrack* track = FindTrack(track_id);
    if (track == nullptr) return nullptr;

    for (const ChqClip& clip : track->clips) {
        ChqRationalTime end;
        if (!clip.End(end).IsOk()) continue;
        // 半开区间 [start, end)：边界处归属后一个片段，避免相邻片段在端点重复命中。
        if (CompareRational(clip.start, t) <= 0 && CompareRational(t, end) < 0) {
            return &clip;
        }
    }
    return nullptr;
}

// ===========================================================================
// 总时长
// ===========================================================================

ChqRationalTime ChqTimeline::Duration() const {
    ChqRationalTime max_end(0, kProjectTimeScale);

    for (const ChqTrack& track : tracks_) {
        for (const ChqClip& clip : track.clips) {
            ChqRationalTime end;
            if (!clip.End(end).IsOk()) continue;

            // 出转场在时间线上额外占时（转场不能凭空消失）
            if (clip.out_transition != ChqTransitionKind::kNone &&
                clip.transition_duration.value > 0) {
                ChqRationalTime with_transition;
                if (AddRational(end, clip.transition_duration, with_transition).IsOk()) {
                    end = with_transition;
                }
            }

            if (CompareRational(end, max_end) > 0) max_end = end;
        }
    }
    return max_end;
}

// ===========================================================================
// 显式恢复（Command 回放 / 序列化载入专用，见 timeline.h 注释）
// ===========================================================================

ChqStatus ChqTimeline::RestoreTrack(const ChqTrack& track) {
    if (track.id == 0) return ChqStatus(ChqStatusCode::kInvalidArgument);
    for (const ChqTrack& t : tracks_) {
        if (t.id == track.id) return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    // 轨道内片段沿用 RestoreClip 的全部校验（id 非零 / 类型匹配 / 时长正 / 同轨不重叠），
    // 但走同一条插入路径，保证回放结果与正常编辑一致。
    // 先在局部把内容装好、再一次性入列：校验失败时不留下半恢复状态。
    ChqTrack restored = track;
    restored.clips.clear();
    for (const ChqClip& clip : track.clips) {
        if (clip.id == 0) return ChqStatus(ChqStatusCode::kInvalidArgument);
        const ChqClipKind expected = (restored.kind == ChqTrackKind::kVideo)
                                      ? ChqClipKind::kVideo
                                      : ChqClipKind::kAudio;
        if (clip.kind != expected) return ChqStatus(ChqStatusCode::kInvalidArgument);
        if (clip.duration.value <= 0 || clip.duration.timescale <= 0) {
            return ChqStatus(ChqStatusCode::kInvalidArgument);
        }
        if (overlaps_in_track(restored, clip, nullptr)) {
            return ChqStatus(ChqStatusCode::kInvalidArgument);
        }
        restored.clips.push_back(clip);
    }
    // 保持与正常编辑相同的有序不变量。
    std::sort(restored.clips.begin(), restored.clips.end(),
              [](const ChqClip& a, const ChqClip& b) {
                  return CompareRational(a.start, b.start) < 0;
              });
    tracks_.push_back(restored);
    if (next_id_ <= track.id) next_id_ = track.id + 1;
    for (const ChqClip& clip : restored.clips) {
        if (next_id_ <= clip.id) next_id_ = clip.id + 1;
    }
    return ChqStatus::Ok();
}

ChqStatus ChqTimeline::RestoreClip(uint64_t track_id, const ChqClip& clip) {
    ChqTrack* track = nullptr;
    for (ChqTrack& t : tracks_) {
        if (t.id == track_id) { track = &t; break; }
    }
    if (track == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    if (clip.id == 0) return ChqStatus(ChqStatusCode::kInvalidArgument);

    const ChqClipKind expected = (track->kind == ChqTrackKind::kVideo) ? ChqClipKind::kVideo
                                                                 : ChqClipKind::kAudio;
    if (clip.kind != expected) return ChqStatus(ChqStatusCode::kInvalidArgument);
    if (clip.duration.value <= 0 || clip.duration.timescale <= 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    if (overlaps_in_track(*track, clip, nullptr)) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    auto pos = track->clips.begin();
    while (pos != track->clips.end() && CompareRational(pos->start, clip.start) <= 0) {
        ++pos;
    }
    track->clips.insert(pos, clip);
    if (next_id_ <= clip.id) next_id_ = clip.id + 1;
    return ChqStatus::Ok();
}

// ===========================================================================
// 内部辅助
// ===========================================================================

ChqClip* ChqTimeline::find_clip_mut(uint64_t clip_id, ChqTrack*& out_track) {
    out_track = nullptr;
    for (ChqTrack& track : tracks_) {
        for (ChqClip& clip : track.clips) {
            if (clip.id == clip_id) {
                out_track = &track;
                return &clip;
            }
        }
    }
    return nullptr;
}

bool ChqTimeline::overlaps_in_track(const ChqTrack& track, const ChqClip& candidate,
                                 const ChqClip* exclude) const {
    ChqRationalTime cand_start = candidate.start;
    ChqRationalTime cand_end;
    if (!candidate.End(cand_end).IsOk()) return true;  // 算不出来就当冲突，宁可不放

    for (const ChqClip& other : track.clips) {
        if (exclude != nullptr && other.id == exclude->id) continue;

        ChqRationalTime other_end;
        if (!other.End(other_end).IsOk()) return true;

        if (ranges_overlap(cand_start, cand_end, other.start, other_end)) return true;
    }
    return false;
}

// 半开区间 [start, end) 的重叠判定：只有严格"相交"才算重叠，
// 首尾相接（a_end == b_start）不算 —— 这是时间线片段的常规语义。
bool ChqTimeline::ranges_overlap(const ChqRationalTime& a_start, const ChqRationalTime& a_end,
                              const ChqRationalTime& b_start, const ChqRationalTime& b_end) {
    return CompareRational(a_start, b_end) < 0 && CompareRational(b_start, a_end) < 0;
}

}  // namespace cq
