// ChuanqiCut — Command 模式与命令历史（MODEL-002）
//
// 红线 #5：UI 不得直接修改模型，**所有** ChqTimeline 变更必须经本层。
// 这是 Undo/Redo 与三端一致性的前提（model.md 硬约束 #1）。
//
// 「不存数据拷贝」约束（model.md #2）的边界解释：
//   * **编辑类**命令（Move/Trim）只存增量 —— clipID + old/new 值，不存任何实体；
//   * **结构类**命令（Add/Remove）必须持有受影响实体的内容才能回放 ——
//     这属于「命令的输入参数 / 受影响实体」，粒度被严格限制在单个实体，
//     **绝不**做轨道树/整模型级快照。
//
// 线程约定：本层**非线程安全**，在 session 线程使用（CORE-009 已把变更串行化）。
//
// 不变量（ChqCommandHistory 依赖，破坏即 Undo 栈失效）：
//   1. ChqTimeline 只能经 ChqCommandHistory 变更；绕过直改会让历史里的 id 引用悬空。
//   2. 命令 Do/Undo/Redo **失败时不得改动模型**（实现责任：先校验后变更，
//      与 ChqTimeline 既有方法同一风格）。ChqCommandHistory 依赖这一点保证
//      「失败不入栈、栈状态不被破坏」。
//   3. Undo/Redo 按栈序执行：历史中相邻命令的实体引用靠 LIFO 顺序保持有效
//      （先删轨道必先撤销轨道内片段的插入）。

#ifndef CQ_CORE_COMMAND_CHQ_COMMAND_H_
#define CQ_CORE_COMMAND_CHQ_COMMAND_H_

#include <cstdint>
#include <memory>
#include <vector>

#include "cq/base/chq_status.h"
#include "cq/base/chq_rational_time.h"
#include "cq/model/chq_timeline.h"

namespace cq {

// ---------------------------------------------------------------------------
// 命令基类
// ---------------------------------------------------------------------------
class ChqICommand {
public:
    virtual ~ChqICommand() = default;

    // 首次执行。失败 = 模型未变更（不变量 2）。
    virtual ChqStatus Do(ChqTimeline& model) = 0;

    // 撤销。仅对「已 Do 且未 Undo」的命令有意义（由 ChqCommandHistory 保证）。
    virtual ChqStatus Undo(ChqTimeline& model) = 0;

    // 重做。默认重放 Do；结构类命令（Add）重放会分配新 id，必须覆写为
    // 显式恢复路径（RestoreX），否则历史里后续命令的 id 引用会失效。
    virtual ChqStatus Redo(ChqTimeline& model) { return Do(model); }

    // 变更名（日志 / 诊断用；ChqChangeRecord 的 name 由 Session 提交方提供）。
    virtual const char* Name() const = 0;
};

// ---------------------------------------------------------------------------
// 命令历史（线性：无分支；新 Execute 丢弃 redo 分支）
// ---------------------------------------------------------------------------
class ChqCommandHistory {
public:
    // 执行并（成功时）入撤销栈。失败：**不入栈、不改历史、模型未变更**，
    // redo 分支也保持原状（失败不丢历史）。
    ChqStatus Execute(std::unique_ptr<ChqICommand> cmd, ChqTimeline& model);

    // 撤销最近一条。空历史返回 kInvalidArgument。
    // 失败（不变量被破坏）时栈保持不变 —— 正常用法下不应发生，测试守卫。
    ChqStatus Undo(ChqTimeline& model);

    // 重做。空 redo 栈返回 kInvalidArgument。
    ChqStatus Redo(ChqTimeline& model);

    bool CanUndo() const { return !undo_stack_.empty(); }
    bool CanRedo() const { return !redo_stack_.empty(); }
    size_t UndoDepth() const { return undo_stack_.size(); }

    // 清空（丢弃全部历史；模型不变）。用于关闭工程等场景。
    void Clear();

private:
    std::vector<std::unique_ptr<ChqICommand>> undo_stack_;
    std::vector<std::unique_ptr<ChqICommand>> redo_stack_;
};

// ---------------------------------------------------------------------------
// 结构类：加轨道。Undo = 删轨道（此时轨道内容必为空，见不变量 3）。
// ---------------------------------------------------------------------------
class ChqAddTrackCommand : public ChqICommand {
public:
    explicit ChqAddTrackCommand(ChqTrackKind kind) : kind_(kind) {}

    ChqStatus Do(ChqTimeline& model) override;
    // Redo 不能再走 AddTrack（会分配新 id）—— 用 Do 时捕获的轨道快照恢复原 id。
    ChqStatus Redo(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "add-track"; }

private:
    ChqTrackKind kind_;
    uint64_t track_id_ = 0;  // 首次 Do 后有效
    ChqTrack snapshot_{};    // 首次 Do 后捕获（Redo 的 RestoreTrack 输入）
    bool captured_ = false;
};

// ---------------------------------------------------------------------------
// 结构类：删轨道。Undo/Redo 都靠 Do 时捕获的轨道快照（含全部片段）。
// ---------------------------------------------------------------------------
class ChqRemoveTrackCommand : public ChqICommand {
public:
    explicit ChqRemoveTrackCommand(uint64_t track_id) : track_id_(track_id) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "remove-track"; }

private:
    uint64_t track_id_;
    ChqTrack snapshot_{};  // Do 时捕获（RestoreTrack 的输入）
    bool captured_ = false;
};

// ---------------------------------------------------------------------------
// 结构类：插片段。Undo = 删片段；Redo = RestoreClip（原 id）。
// ---------------------------------------------------------------------------
class ChqInsertClipCommand : public ChqICommand {
public:
    // clip 参数中的 id 字段被忽略（由 ChqTimeline 分配）；track_id 指定目标轨道。
    ChqInsertClipCommand(uint64_t track_id, const ChqClip& clip)
        : track_id_(track_id), clip_(clip) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Redo(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "insert-clip"; }

    // 首次 Do 后有效：实际分配的片段 id（UI 拿它做后续选择/拖拽）。
    uint64_t clip_id() const { return clip_id_; }

private:
    uint64_t track_id_;
    ChqClip clip_;          // 用户输入参数（id 字段无效）
    uint64_t clip_id_ = 0;  // 首次 Do 分配的 id
};

// ---------------------------------------------------------------------------
// 结构类：删片段。Undo = RestoreClip（原 id 原轨道）；Redo = RemoveClip。
// ---------------------------------------------------------------------------
class ChqRemoveClipCommand : public ChqICommand {
public:
    explicit ChqRemoveClipCommand(uint64_t clip_id) : clip_id_(clip_id) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "remove-clip"; }

private:
    uint64_t clip_id_;
    ChqClip snapshot_{};     // Do 时捕获
    uint64_t track_id_ = 0;  // 片段原所在轨道
    bool captured_ = false;
};

// ---------------------------------------------------------------------------
// 结构类：分割片段（EDIT-007）。一个命令产生两处变更：
//   左半  —— 原 id 原位收缩（TrimClip 语义覆盖不到的 out_transition 置 kNone）；
//   右半  —— 新 id（Do 时分配）。
// Undo = 删右半 + 左半整体还原；Redo 不能重放 Do（会分配新右半 id），
// 走 ReplaceClip(左) + RestoreClip(右，原 id) —— 与 Insert/Remove 同一纪律。
// 快照粒度：左右两个**单个实体**（结构类允许的粒度，见文件头）。
// ---------------------------------------------------------------------------
class ChqSplitClipCommand : public ChqICommand {
public:
    ChqSplitClipCommand(uint64_t clip_id, const ChqRationalTime& at)
        : clip_id_(clip_id), at_(at) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Redo(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "split-clip"; }

    // 首次 Do 后有效：右半实际分配的片段 id（UI 拿它做后续选择）。
    uint64_t right_clip_id() const { return right_id_; }

private:
    uint64_t clip_id_;  // 左半（原片段）
    ChqRationalTime at_;
    uint64_t right_id_ = 0;  // 首次 Do 分配
    uint64_t track_id_ = 0;  // 首次 Do 定位（Redo 的 RestoreClip 输入）
    ChqClip left_before_{};  // Do 前的左半（Undo 还原依据）
    ChqClip left_after_{};   // Do 后的左半（Redo 的 ReplaceClip 输入）
    ChqClip right_after_{};  // Do 后的右半（Redo 的 RestoreClip 输入）
    bool captured_ = false;
};

// ---------------------------------------------------------------------------
// 编辑类：左缘裁剪（EDIT-008）。右缘（end = start + duration）不动，
// 同时改三个耦合字段：start / source_in / duration。
// 与 Move/Trim 不同，三条增量彼此约束（新 end == 旧 end），分开存会留下
// 「只回放了一部分」的半更新窗口 —— 故存**单个实体**的变更前后快照
// （粒度仍被限制在单个实体，见文件头；Redo = Do，id 稳定无需 Restore）。
// ---------------------------------------------------------------------------
class ChqTrimClipInCommand : public ChqICommand {
public:
    // new_start = 拖动左缘后的新时间线起点；source_in / duration 由内核按
    // 「右缘不动」推导（source_in += Δ，duration -= Δ），调用方只给一个参数。
    ChqTrimClipInCommand(uint64_t clip_id, const ChqRationalTime& new_start)
        : clip_id_(clip_id), new_start_(new_start) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "trim-clip-in"; }

private:
    uint64_t clip_id_;
    ChqRationalTime new_start_;
    ChqClip old_clip_{};  // 首次 Do 时捕获
    ChqClip new_clip_{};  // 首次 Do 时推导
    bool captured_ = false;
};

// ---------------------------------------------------------------------------
// 编辑类：画布比例（UIA-040）。项目级属性，只存新旧宽高（增量）。
// ---------------------------------------------------------------------------
class ChqSetCanvasCommand : public ChqICommand {
public:
    ChqSetCanvasCommand(int32_t width, int32_t height)
        : new_width_(width), new_height_(height) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "set-canvas"; }

private:
    int32_t new_width_;
    int32_t new_height_;
    int32_t old_width_ = 0;  // 首次 Do 时捕获
    int32_t old_height_ = 0;
};

// ---------------------------------------------------------------------------
// 编辑类：轨道静音（CORE-011 / 问卷 E1 裁定）。只存新旧布尔，与
// ChqSetCanvasCommand 同形；Do 先捕获 old 再写，未知 track_id 直接失败。
// ---------------------------------------------------------------------------
class ChqSetTrackMutedCommand : public ChqICommand {
public:
    ChqSetTrackMutedCommand(uint64_t track_id, bool muted)
        : track_id_(track_id), new_muted_(muted) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "set-track-muted"; }

private:
    uint64_t track_id_;
    bool new_muted_;
    bool old_muted_ = false;  // 首次 Do 时捕获
};

// ---------------------------------------------------------------------------
// 编辑类：跨轨移动（UIA-040 多轨操作）。id 不变，只存起止（轨 + 起点）增量。
// ---------------------------------------------------------------------------
class ChqMoveClipToTrackCommand : public ChqICommand {
public:
    ChqMoveClipToTrackCommand(uint64_t clip_id, uint64_t target_track_id,
                              const ChqRationalTime& new_start)
        : clip_id_(clip_id), target_track_id_(target_track_id), new_start_(new_start) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "move-clip-to-track"; }

private:
    uint64_t clip_id_;
    uint64_t target_track_id_;
    ChqRationalTime new_start_;
    uint64_t old_track_id_ = 0;  // 首次 Do 时捕获
    ChqRationalTime old_start_{0, 1};
};

// ---------------------------------------------------------------------------
// 编辑类：移动片段（只存增量 —— model.md 硬约束 #2 的原型）。
// ---------------------------------------------------------------------------
class ChqMoveClipCommand : public ChqICommand {
public:
    ChqMoveClipCommand(uint64_t clip_id, const ChqRationalTime& new_start)
        : clip_id_(clip_id), new_start_(new_start) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "move-clip"; }

private:
    uint64_t clip_id_;
    ChqRationalTime new_start_;
    ChqRationalTime old_start_{0, 1};  // 首次 Do 时捕获
};

// ---------------------------------------------------------------------------
// 编辑类：修剪片段时长（当前模型语义：只改 duration，不动 source_in）。
// ---------------------------------------------------------------------------
class ChqTrimClipCommand : public ChqICommand {
public:
    ChqTrimClipCommand(uint64_t clip_id, const ChqRationalTime& new_duration)
        : clip_id_(clip_id), new_duration_(new_duration) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "trim-clip"; }

private:
    uint64_t clip_id_;
    ChqRationalTime new_duration_;
    ChqRationalTime old_duration_{0, 1};  // 首次 Do 时捕获
};

// ---------------------------------------------------------------------------
// 结构类：给片段添加效果（MODEL-003）。Undo = 按 effect_id 移除。
// Redo 用默认（= 重新 Do）：效果 id 由调用方给出、追加恒在栈尾，
// 重放得到与首次 Do 完全一致的状态 —— 与 ChqAddTrackCommand 不同
// （那条重放会分配新 id，必须覆写 Redo 走 RestoreTrack）。
// ---------------------------------------------------------------------------
class ChqAddClipEffectCommand : public ChqICommand {
public:
    ChqAddClipEffectCommand(uint64_t clip_id, const ChqEffectBinding& effect)
        : clip_id_(clip_id), effect_(effect) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "add-clip-effect"; }

private:
    uint64_t clip_id_;
    ChqEffectBinding effect_;  // 输入参数（深拷贝：字符串 + 参数袋）
};

// ---------------------------------------------------------------------------
// 结构类：移除片段效果（MODEL-003）。Do 时捕获整条效果栈快照（单实体粒度，
// 同 ChqRemoveTrackCommand 的轨道快照）：移除会丢掉原次序，逐条 Append
// 还原会改变其余效果的相对顺序，而顺序是渲染语义，不能漂。
// Undo = 整栈替换还原；Redo = 再移除一次。
// ---------------------------------------------------------------------------
class ChqRemoveClipEffectCommand : public ChqICommand {
public:
    ChqRemoveClipEffectCommand(uint64_t clip_id, std::string effect_id)
        : clip_id_(clip_id), effect_id_(std::move(effect_id)) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    ChqStatus Redo(ChqTimeline& model) override;
    const char* Name() const override { return "remove-clip-effect"; }

private:
    uint64_t clip_id_;
    std::string effect_id_;
    ChqEffectStack stack_before_{};  // Do 时捕获（Undo 的整栈还原依据）
    bool captured_ = false;
};

// ---------------------------------------------------------------------------
// 编辑类：设效果参数（MODEL-003）。存 key + 新旧值（增量，model.md #2）。
// "原先没有该 key"（首次拖滑块创建覆盖）用 had_old_ = false 表达，
// Undo 走擦除而不是写回一个假默认值 —— 否则模型里会留下一个
// 「用户从没设过、撤销也删不掉」的幽灵参数。
// ---------------------------------------------------------------------------
class ChqSetEffectParamCommand : public ChqICommand {
public:
    ChqSetEffectParamCommand(uint64_t clip_id, std::string effect_id, std::string key,
                             ChqPropertyValue new_value)
        : clip_id_(clip_id),
          effect_id_(std::move(effect_id)),
          key_(std::move(key)),
          new_value_(new_value) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    ChqStatus Redo(ChqTimeline& model) override;
    const char* Name() const override { return "set-effect-param"; }

private:
    uint64_t clip_id_;
    std::string effect_id_;
    std::string key_;
    ChqPropertyValue new_value_;
    ChqPropertyValue old_value_{};  // 首次 Do 时捕获（had_old_ = false 时无意义）
    bool had_old_ = false;
    bool captured_ = false;
};

// ---------------------------------------------------------------------------
// 编辑类：效果启用开关（MODEL-003）。只存新旧布尔（与 ChqSetCanvasCommand
// 同型的标量编辑）。与轨道 muted 正交：muted 静音整条轨，这个是单效果开关。
// ---------------------------------------------------------------------------
class ChqSetEffectEnabledCommand : public ChqICommand {
public:
    ChqSetEffectEnabledCommand(uint64_t clip_id, std::string effect_id, bool enabled)
        : clip_id_(clip_id), effect_id_(std::move(effect_id)), new_enabled_(enabled) {}

    ChqStatus Do(ChqTimeline& model) override;
    ChqStatus Undo(ChqTimeline& model) override;
    const char* Name() const override { return "set-effect-enabled"; }

private:
    uint64_t clip_id_;
    std::string effect_id_;
    bool new_enabled_;
    bool old_enabled_ = true;  // 首次 Do 时捕获
};

}  // namespace cq

#endif /* CQ_CORE_COMMAND_CHQ_COMMAND_H_ */
