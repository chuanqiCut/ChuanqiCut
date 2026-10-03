// ChuanqiCut — 时间线数据模型实现（MODEL-001）
//
// 时间运算一律走 base 层的 AddRational / CompareRational（跨 timescale 由它们
// 以最小公倍数对齐），**不**直接对 value 做算术 —— 否则 timescale 不同时会算错。

#include "cq/model/timeline.h"

#include <algorithm>  // std::sort（移动片段后重排）

namespace cq {

// ===========================================================================
// Clip
// ===========================================================================

Status Clip::End(RationalTime& out) const {
    return AddRational(start, duration, out);
}

// ===========================================================================
// 轨道
// ===========================================================================

Status Timeline::AddTrack(TrackKind kind, uint64_t& out_id) {
    Track track;
    track.id = next_id_++;
    track.kind = kind;
    tracks_.push_back(track);
    out_id = track.id;
    return Status::Ok();
}

Status Timeline::RemoveTrack(uint64_t track_id) {
    for (auto it = tracks_.begin(); it != tracks_.end(); ++it) {
        if (it->id == track_id) {
            tracks_.erase(it);
            return Status::Ok();
        }
    }
    return Status(StatusCode::kInvalidArgument);
}

const Track* Timeline::FindTrack(uint64_t track_id) const {
    for (const Track& track : tracks_) {
        if (track.id == track_id) return &track;
    }
    return nullptr;
}

// ===========================================================================
// 片段
// ===========================================================================

Status Timeline::InsertClip(uint64_t track_id, const Clip& clip, uint64_t& out_id) {
    Track* track = nullptr;
    for (Track& t : tracks_) {
        if (t.id == track_id) { track = &t; break; }
    }
    if (track == nullptr) return Status(StatusCode::kInvalidArgument);

    // 轨道类型必须匹配：音频片段放视频轨会让后续混音/渲染分支到处做类型判断。
    const ClipKind expected = (track->kind == TrackKind::kVideo) ? ClipKind::kVideo
                                                                 : ClipKind::kAudio;
    if (clip.kind != expected) return Status(StatusCode::kInvalidArgument);

    // 时长必须为正（零时长片段在时间线上没有意义，且会让命中测试含糊）。
    if (clip.duration.value <= 0 || clip.duration.timescale <= 0) {
        return Status(StatusCode::kInvalidArgument);
    }

    // 同轨不允许重叠
    if (overlaps_in_track(*track, clip, nullptr)) {
        return Status(StatusCode::kInvalidArgument);
    }

    Clip inserted = clip;
    inserted.id = next_id_++;
    // 保持按 start 升序，便于命中测试与顺序遍历。
    auto pos = track->clips.begin();
    while (pos != track->clips.end() && CompareRational(pos->start, inserted.start) <= 0) {
        ++pos;
    }
    track->clips.insert(pos, inserted);
    out_id = inserted.id;
    return Status::Ok();
}

Status Timeline::RemoveClip(uint64_t clip_id) {
    Track* track = nullptr;
    find_clip_mut(clip_id, track);
    if (track == nullptr) return Status(StatusCode::kInvalidArgument);

    for (auto it = track->clips.begin(); it != track->clips.end(); ++it) {
        if (it->id == clip_id) {
            track->clips.erase(it);
            return Status::Ok();
        }
    }
    return Status(StatusCode::kInvalidArgument);
}

Status Timeline::MoveClip(uint64_t clip_id, const RationalTime& new_start) {
    Track* track = nullptr;
    Clip* clip = find_clip_mut(clip_id, track);
    if (clip == nullptr) return Status(StatusCode::kInvalidArgument);

    Clip candidate = *clip;
    candidate.start = new_start;
    // 排除自身：否则「原地移动」会被判成跟自己重叠。
    if (overlaps_in_track(*track, candidate, clip)) {
        return Status(StatusCode::kInvalidArgument);
    }
    clip->start = new_start;
    // 位置变了，重新排序
    std::vector<Clip> sorted;
    sorted.reserve(track->clips.size());
    for (const Clip& c : track->clips) sorted.push_back(c);
    std::sort(sorted.begin(), sorted.end(),
              [](const Clip& a, const Clip& b) {
                  return CompareRational(a.start, b.start) < 0;
              });
    track->clips = sorted;
    return Status::Ok();
}

Status Timeline::TrimClip(uint64_t clip_id, const RationalTime& new_duration) {
    Track* track = nullptr;
    Clip* clip = find_clip_mut(clip_id, track);
    if (clip == nullptr) return Status(StatusCode::kInvalidArgument);

    if (new_duration.value <= 0 || new_duration.timescale <= 0) {
        return Status(StatusCode::kInvalidArgument);
    }

    Clip candidate = *clip;
    candidate.duration = new_duration;
    if (overlaps_in_track(*track, candidate, clip)) {
        return Status(StatusCode::kInvalidArgument);
    }
    clip->duration = new_duration;
    return Status::Ok();
}

const Clip* Timeline::FindClip(uint64_t clip_id) const {
    for (const Track& track : tracks_) {
        for (const Clip& clip : track.clips) {
            if (clip.id == clip_id) return &clip;
        }
    }
    return nullptr;
}

const Clip* Timeline::FindClipAt(uint64_t track_id, const RationalTime& t) const {
    const Track* track = FindTrack(track_id);
    if (track == nullptr) return nullptr;

    for (const Clip& clip : track->clips) {
        RationalTime end;
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

RationalTime Timeline::Duration() const {
    RationalTime max_end(0, kProjectTimeScale);

    for (const Track& track : tracks_) {
        for (const Clip& clip : track.clips) {
            RationalTime end;
            if (!clip.End(end).IsOk()) continue;

            // 出转场在时间线上额外占时（转场不能凭空消失）
            if (clip.out_transition != TransitionKind::kNone &&
                clip.transition_duration.value > 0) {
                RationalTime with_transition;
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

Status Timeline::RestoreTrack(const Track& track) {
    if (track.id == 0) return Status(StatusCode::kInvalidArgument);
    for (const Track& t : tracks_) {
        if (t.id == track.id) return Status(StatusCode::kInvalidArgument);
    }
    // 轨道内片段沿用 RestoreClip 的全部校验（id 非零 / 类型匹配 / 时长正 / 同轨不重叠），
    // 但走同一条插入路径，保证回放结果与正常编辑一致。
    // 先在局部把内容装好、再一次性入列：校验失败时不留下半恢复状态。
    Track restored = track;
    restored.clips.clear();
    for (const Clip& clip : track.clips) {
        if (clip.id == 0) return Status(StatusCode::kInvalidArgument);
        const ClipKind expected = (restored.kind == TrackKind::kVideo)
                                      ? ClipKind::kVideo
                                      : ClipKind::kAudio;
        if (clip.kind != expected) return Status(StatusCode::kInvalidArgument);
        if (clip.duration.value <= 0 || clip.duration.timescale <= 0) {
            return Status(StatusCode::kInvalidArgument);
        }
        if (overlaps_in_track(restored, clip, nullptr)) {
            return Status(StatusCode::kInvalidArgument);
        }
        restored.clips.push_back(clip);
    }
    // 保持与正常编辑相同的有序不变量。
    std::sort(restored.clips.begin(), restored.clips.end(),
              [](const Clip& a, const Clip& b) {
                  return CompareRational(a.start, b.start) < 0;
              });
    tracks_.push_back(restored);
    if (next_id_ <= track.id) next_id_ = track.id + 1;
    for (const Clip& clip : restored.clips) {
        if (next_id_ <= clip.id) next_id_ = clip.id + 1;
    }
    return Status::Ok();
}

Status Timeline::RestoreClip(uint64_t track_id, const Clip& clip) {
    Track* track = nullptr;
    for (Track& t : tracks_) {
        if (t.id == track_id) { track = &t; break; }
    }
    if (track == nullptr) return Status(StatusCode::kInvalidArgument);
    if (clip.id == 0) return Status(StatusCode::kInvalidArgument);

    const ClipKind expected = (track->kind == TrackKind::kVideo) ? ClipKind::kVideo
                                                                 : ClipKind::kAudio;
    if (clip.kind != expected) return Status(StatusCode::kInvalidArgument);
    if (clip.duration.value <= 0 || clip.duration.timescale <= 0) {
        return Status(StatusCode::kInvalidArgument);
    }
    if (overlaps_in_track(*track, clip, nullptr)) {
        return Status(StatusCode::kInvalidArgument);
    }
    auto pos = track->clips.begin();
    while (pos != track->clips.end() && CompareRational(pos->start, clip.start) <= 0) {
        ++pos;
    }
    track->clips.insert(pos, clip);
    if (next_id_ <= clip.id) next_id_ = clip.id + 1;
    return Status::Ok();
}

// ===========================================================================
// 内部辅助
// ===========================================================================

Clip* Timeline::find_clip_mut(uint64_t clip_id, Track*& out_track) {
    out_track = nullptr;
    for (Track& track : tracks_) {
        for (Clip& clip : track.clips) {
            if (clip.id == clip_id) {
                out_track = &track;
                return &clip;
            }
        }
    }
    return nullptr;
}

bool Timeline::overlaps_in_track(const Track& track, const Clip& candidate,
                                 const Clip* exclude) const {
    RationalTime cand_start = candidate.start;
    RationalTime cand_end;
    if (!candidate.End(cand_end).IsOk()) return true;  // 算不出来就当冲突，宁可不放

    for (const Clip& other : track.clips) {
        if (exclude != nullptr && other.id == exclude->id) continue;

        RationalTime other_end;
        if (!other.End(other_end).IsOk()) return true;

        if (ranges_overlap(cand_start, cand_end, other.start, other_end)) return true;
    }
    return false;
}

// 半开区间 [start, end) 的重叠判定：只有严格"相交"才算重叠，
// 首尾相接（a_end == b_start）不算 —— 这是时间线片段的常规语义。
bool Timeline::ranges_overlap(const RationalTime& a_start, const RationalTime& a_end,
                              const RationalTime& b_start, const RationalTime& b_end) {
    return CompareRational(a_start, b_end) < 0 && CompareRational(b_start, a_end) < 0;
}

}  // namespace cq
