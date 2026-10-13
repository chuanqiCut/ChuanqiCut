// ChuanqiCut — 时间线数据模型（MODEL-001）
//
// 硬约束（与 CORE 层一致，勿破）：
//   * 零平台类型：不出现 Metal / Vulkan / AVFoundation 等专有类型，不 include 平台头。
//   * 零 FFmpeg 类型：不出现 AV* 类型，不 include ffmpeg 头。
//   * 统一 base 类型：时间一律 ChqRationalTime（项目网格 timescale = kProjectTimeScale），
//     错误一律 ChqStatus。
//   * 内核禁用异常：无 throw，错误靠 ChqStatus 传播。
//
// 时间语义（两条容易搞错，改代码前先读）：
//   1. 同轨 clip **互不重叠**（重叠语义含糊：谁覆盖谁？）—— 插入/移动冲突返回
//      kInvalidArgument。跨轨重叠**允许**，那正是多轨合成的意义。
//   2. 转场挂在 clip 的 in/out 边界上，**不延长 clip 自身占时**。转场"吃掉"的是
//      相邻两个 clip 之间的重叠区间；ChqTimeline::Duration() 才把出转场时长计入总长。

#ifndef CQ_CORE_MODEL_CHQ_TIMELINE_H_
#define CQ_CORE_MODEL_CHQ_TIMELINE_H_

#include <cstdint>
#include <vector>

#include "cq/base/chq_status.h"
#include "cq/base/chq_rational_time.h"
#include "cq/model/chq_property.h"  // MODEL-003：效果栈（片段级属性）

namespace cq {

enum class ChqTrackKind { kVideo, kAudio };
enum class ChqClipKind { kVideo, kAudio };
enum class ChqTransitionKind { kNone, kCrossFade, kDipToBlack };

// ---------------------------------------------------------------------------
// 媒体引用：只引用，不持有媒体数据（解码与缓存在 media 层）
// ---------------------------------------------------------------------------
struct ChqMediaRef {
    uint64_t asset_id = 0;            // 素材 id（具体解析由上层负责）
    ChqRationalTime source_in;           // 素材内入点
    ChqRationalTime source_duration;     // 自入点起使用的时长
};

// ---------------------------------------------------------------------------
// ChqClip — 时间线上的一个片段
// ---------------------------------------------------------------------------
struct ChqClip {
    uint64_t id = 0;
    ChqClipKind kind = ChqClipKind::kVideo;
    ChqMediaRef source;
    ChqRationalTime start;      // 时间线起点
    ChqRationalTime duration;   // 时间线占时（trim 后）

    ChqTransitionKind in_transition = ChqTransitionKind::kNone;
    ChqTransitionKind out_transition = ChqTransitionKind::kNone;
    ChqRationalTime transition_duration;  // 转场时长（kNone 时应为 0）

    // MODEL-003：效果栈（有序，顺序即渲染顺序）。与转场正交 —— 转场吃的是
    // 片段间重叠区间，效果吃的是片段自身内容，两者可同时存在。
    // B0 只立数据：渲染消费归 RENDER-011（B7），装配器如实上报 effects_dropped。
    ChqEffectStack effects;

    // 结束时刻 = start + duration（不含出转场）。
    ChqStatus End(ChqRationalTime& out) const;
};

// ---------------------------------------------------------------------------
// ChqTrack — 一条轨道
// ---------------------------------------------------------------------------
struct ChqTrack {
    uint64_t id = 0;
    ChqTrackKind kind = ChqTrackKind::kVideo;
    std::vector<ChqClip> clips;  // 按 start 升序维护，同轨互不重叠
    bool enabled = true;
    bool muted = false;
};

// ---------------------------------------------------------------------------
// ChqTimeline — 时间线（多轨容器，MODEL-001 主体）
// ---------------------------------------------------------------------------
class ChqTimeline {
public:
    // 轨道
    ChqStatus AddTrack(ChqTrackKind kind, uint64_t& out_id);
    ChqStatus RemoveTrack(uint64_t track_id);
    const ChqTrack* FindTrack(uint64_t track_id) const;
    const std::vector<ChqTrack>& Tracks() const { return tracks_; }

    // 片段
    ChqStatus InsertClip(uint64_t track_id, const ChqClip& clip, uint64_t& out_id);
    ChqStatus RemoveClip(uint64_t clip_id);
    ChqStatus MoveClip(uint64_t clip_id, const ChqRationalTime& new_start);
    ChqStatus TrimClip(uint64_t clip_id, const ChqRationalTime& new_duration);

    // 原位整体替换片段内容（id 不变、不换轨）：左缘裁剪等「同时改 start /
    // source_in / duration」的编辑用它一次提交，避免三条独立变更之间的半更新。
    // 校验与 Insert 同基：id 必须已存在、kind 必须匹配所在轨道、duration > 0、
    // source_in >= 0（素材内入点不能早于素材起点）、同轨不重叠（排除自身）。
    // 成功后轨内按 start 升序重排（start 可变）。
    ChqStatus ReplaceClip(const ChqClip& clip);

    // 在时刻 at 处把片段切成两半（EDIT-007 分割）：
    //   左半  —— 保留原 id，duration 收缩为 (at - start)，out_transition 置 kNone
    //            （分割点是媒体中段的切线，不是媒体边界，转场不能挂在它上面）；
    //   右半  —— 新分配 id，start = at，source_in += (at - start)，
    //            source_duration -= (at - start)，in_transition 置 kNone。
    // 校验：片段存在、at 严格落在 (start, end) 开区间内（切在边界上无意义）。
    // 全部运算先算术后变更：任一步溢出/非法即整体失败，模型不留半切状态。
    ChqStatus SplitClip(uint64_t clip_id, const ChqRationalTime& at, uint64_t& out_right_id);

    const ChqClip* FindClip(uint64_t clip_id) const;

    // 命中测试：返回覆盖时刻 t 的 clip（同轨最多一个，因为不重叠）
    const ChqClip* FindClipAt(uint64_t track_id, const ChqRationalTime& t) const;

    // ---- 画布（UIA-040；项目级属性，预览/导出的取景基准）----
    // 默认 1080×1920（9:16，竖屏短视频基准）。宽高只是**比例语义**（渲染侧按
    // 适配模式把内容装进画布），不是像素承诺；上界 8192 防呆。
    // 校验：w/h ∈ (0, 8192]。失败返回 kInvalidArgument，模型不动。
    int32_t CanvasWidth() const { return canvas_width_; }
    int32_t CanvasHeight() const { return canvas_height_; }
    ChqStatus SetCanvas(int32_t width, int32_t height);

    // ---- 跨轨移动（UIA-040 多轨操作；片段 id 不变）----
    // 把片段移到目标轨道的 new_start 处（画中画拖拽的模型语义）。
    // 校验：片段存在、目标轨道存在、片段 kind 与目标轨类型匹配、
    // 目标轨无重叠（同轨移动排除自身）。校验全过才变更，失败模型不动。
    ChqStatus MoveClipToTrack(uint64_t clip_id, uint64_t target_track_id,
                              const ChqRationalTime& new_start);

    // 总时长 = 所有轨道中最大的「clip 结束时刻 + 出转场时长」
    ChqRationalTime Duration() const;

    // ---- 效果栈（MODEL-003；片段级属性，全部经 Command 层提交，见 chq_command.h）----
    // 校验纪律与既有方法一致：先校验后变更，失败模型不动、返回错误码。
    //   clip 不存在 → kInvalidArgument；效果不存在 → kIoNotFound（如实区分
    //   "片段没了"与"效果没了"—— 前者是结构错误，后者只是没挂这个效果）。
    ChqStatus AddClipEffect(uint64_t clip_id, const ChqEffectBinding& effect);
    ChqStatus RemoveClipEffect(uint64_t clip_id, const std::string& effect_id);
    // 参数覆盖写（key 原先不存在 = 新增；存在 = 改值）。空 key → kInvalidArgument。
    ChqStatus SetClipEffectParam(uint64_t clip_id, const std::string& effect_id,
                                 const std::string& key, const ChqPropertyValue& value);
    // 删参数。key 不存在 → kIoNotFound（供 SetEffectParam 命令的"原先无此 key"
    // 撤销路径使用，UI 不直接调）。
    ChqStatus EraseClipEffectParam(uint64_t clip_id, const std::string& effect_id,
                                   const std::string& key);
    ChqStatus SetClipEffectEnabled(uint64_t clip_id, const std::string& effect_id, bool enabled);
    // 整栈替换（MODEL-003 移除效果命令的 Undo 用：移除会丢掉原次序，
    // 逐条 Append 还原会改变其余效果的相对顺序，故回放整栈）。
    ChqStatus ReplaceClipEffects(uint64_t clip_id, const ChqEffectStack& stack);

    // ---- 显式恢复（仅供 Command 回放 / 序列化载入使用，业务代码不要调）----
    // 与 AddTrack/InsertClip 的区别：**使用实体自带的 id，不分配新 id**。
    // Undo/Redo 必须把实体放回原 id 上，否则历史里后续命令的 id 引用会全部失效。
    // next_id_ 仍单调推进（max(next_id_, id+1)），保证之后新分配的 id 唯一。
    // 校验与对应 Add/Insert 一致（同 id 已存在 / 轨道缺失 / 类型不匹配 /
    // 时长非正 / 同轨重叠 → kInvalidArgument）。
    ChqStatus RestoreTrack(const ChqTrack& track);
    ChqStatus RestoreClip(uint64_t track_id, const ChqClip& clip);

private:
    ChqClip* find_clip_mut(uint64_t clip_id, ChqTrack*& out_track);
    // exclude：移动/修剪时排除自身（否则自己跟自己判重叠）
    bool overlaps_in_track(const ChqTrack& track, const ChqClip& candidate,
                           const ChqClip* exclude) const;
    static bool ranges_overlap(const ChqRationalTime& a_start, const ChqRationalTime& a_end,
                               const ChqRationalTime& b_start, const ChqRationalTime& b_end);

    std::vector<ChqTrack> tracks_;
    uint64_t next_id_ = 1;
    int32_t canvas_width_ = 1080;   // 9:16 竖屏基准（对标 App默认）
    int32_t canvas_height_ = 1920;
};

}  // namespace cq

#endif  // CQ_CORE_MODEL_CHQ_TIMELINE_H_
