// ChuanqiCut — 时间线数据模型（MODEL-001）
//
// 硬约束（与 CORE 层一致，勿破）：
//   * 零平台类型：不出现 Metal / Vulkan / AVFoundation 等专有类型，不 include 平台头。
//   * 零 FFmpeg 类型：不出现 AV* 类型，不 include ffmpeg 头。
//   * 统一 base 类型：时间一律 RationalTime（项目网格 timescale = kProjectTimeScale），
//     错误一律 Status。
//   * 内核禁用异常：无 throw，错误靠 Status 传播。
//
// 时间语义（两条容易搞错，改代码前先读）：
//   1. 同轨 clip **互不重叠**（重叠语义含糊：谁覆盖谁？）—— 插入/移动冲突返回
//      kInvalidArgument。跨轨重叠**允许**，那正是多轨合成的意义。
//   2. 转场挂在 clip 的 in/out 边界上，**不延长 clip 自身占时**。转场"吃掉"的是
//      相邻两个 clip 之间的重叠区间；Timeline::Duration() 才把出转场时长计入总长。

#ifndef CQ_MODEL_TIMELINE_H_
#define CQ_MODEL_TIMELINE_H_

#include <cstdint>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/time.h"

namespace cq {

enum class TrackKind { kVideo, kAudio };
enum class ClipKind { kVideo, kAudio };
enum class TransitionKind { kNone, kCrossFade, kDipToBlack };

// ---------------------------------------------------------------------------
// 媒体引用：只引用，不持有媒体数据（解码与缓存在 media 层）
// ---------------------------------------------------------------------------
struct MediaRef {
    uint64_t asset_id = 0;            // 素材 id（具体解析由上层负责）
    RationalTime source_in;           // 素材内入点
    RationalTime source_duration;     // 自入点起使用的时长
};

// ---------------------------------------------------------------------------
// Clip — 时间线上的一个片段
// ---------------------------------------------------------------------------
struct Clip {
    uint64_t id = 0;
    ClipKind kind = ClipKind::kVideo;
    MediaRef source;
    RationalTime start;      // 时间线起点
    RationalTime duration;   // 时间线占时（trim 后）

    TransitionKind in_transition = TransitionKind::kNone;
    TransitionKind out_transition = TransitionKind::kNone;
    RationalTime transition_duration;  // 转场时长（kNone 时应为 0）

    // 结束时刻 = start + duration（不含出转场）。
    Status End(RationalTime& out) const;
};

// ---------------------------------------------------------------------------
// Track — 一条轨道
// ---------------------------------------------------------------------------
struct Track {
    uint64_t id = 0;
    TrackKind kind = TrackKind::kVideo;
    std::vector<Clip> clips;  // 按 start 升序维护，同轨互不重叠
    bool enabled = true;
    bool muted = false;
};

// ---------------------------------------------------------------------------
// Timeline — 时间线（多轨容器，MODEL-001 主体）
// ---------------------------------------------------------------------------
class Timeline {
public:
    // 轨道
    Status AddTrack(TrackKind kind, uint64_t& out_id);
    Status RemoveTrack(uint64_t track_id);
    const Track* FindTrack(uint64_t track_id) const;
    const std::vector<Track>& Tracks() const { return tracks_; }

    // 片段
    Status InsertClip(uint64_t track_id, const Clip& clip, uint64_t& out_id);
    Status RemoveClip(uint64_t clip_id);
    Status MoveClip(uint64_t clip_id, const RationalTime& new_start);
    Status TrimClip(uint64_t clip_id, const RationalTime& new_duration);
    const Clip* FindClip(uint64_t clip_id) const;

    // 命中测试：返回覆盖时刻 t 的 clip（同轨最多一个，因为不重叠）
    const Clip* FindClipAt(uint64_t track_id, const RationalTime& t) const;

    // 总时长 = 所有轨道中最大的「clip 结束时刻 + 出转场时长」
    RationalTime Duration() const;

    // ---- 显式恢复（仅供 Command 回放 / 序列化载入使用，业务代码不要调）----
    // 与 AddTrack/InsertClip 的区别：**使用实体自带的 id，不分配新 id**。
    // Undo/Redo 必须把实体放回原 id 上，否则历史里后续命令的 id 引用会全部失效。
    // next_id_ 仍单调推进（max(next_id_, id+1)），保证之后新分配的 id 唯一。
    // 校验与对应 Add/Insert 一致（同 id 已存在 / 轨道缺失 / 类型不匹配 /
    // 时长非正 / 同轨重叠 → kInvalidArgument）。
    Status RestoreTrack(const Track& track);
    Status RestoreClip(uint64_t track_id, const Clip& clip);

private:
    Clip* find_clip_mut(uint64_t clip_id, Track*& out_track);
    // exclude：移动/修剪时排除自身（否则自己跟自己判重叠）
    bool overlaps_in_track(const Track& track, const Clip& candidate,
                           const Clip* exclude) const;
    static bool ranges_overlap(const RationalTime& a_start, const RationalTime& a_end,
                               const RationalTime& b_start, const RationalTime& b_end);

    std::vector<Track> tracks_;
    uint64_t next_id_ = 1;
};

}  // namespace cq

#endif  // CQ_MODEL_TIMELINE_H_
