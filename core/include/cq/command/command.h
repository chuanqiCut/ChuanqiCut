// ChuanqiCut — Command 模式与命令历史（MODEL-002）
//
// 红线 #5：UI 不得直接修改模型，**所有** Timeline 变更必须经本层。
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
// 不变量（CommandHistory 依赖，破坏即 Undo 栈失效）：
//   1. Timeline 只能经 CommandHistory 变更；绕过直改会让历史里的 id 引用悬空。
//   2. 命令 Do/Undo/Redo **失败时不得改动模型**（实现责任：先校验后变更，
//      与 Timeline 既有方法同一风格）。CommandHistory 依赖这一点保证
//      「失败不入栈、栈状态不被破坏」。
//   3. Undo/Redo 按栈序执行：历史中相邻命令的实体引用靠 LIFO 顺序保持有效
//      （先删轨道必先撤销轨道内片段的插入）。

#ifndef CQ_COMMAND_COMMAND_H_
#define CQ_COMMAND_COMMAND_H_

#include <cstdint>
#include <memory>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/model/timeline.h"

namespace cq {

// ---------------------------------------------------------------------------
// 命令基类
// ---------------------------------------------------------------------------
class ICommand {
public:
    virtual ~ICommand() = default;

    // 首次执行。失败 = 模型未变更（不变量 2）。
    virtual Status Do(Timeline& model) = 0;

    // 撤销。仅对「已 Do 且未 Undo」的命令有意义（由 CommandHistory 保证）。
    virtual Status Undo(Timeline& model) = 0;

    // 重做。默认重放 Do；结构类命令（Add）重放会分配新 id，必须覆写为
    // 显式恢复路径（RestoreX），否则历史里后续命令的 id 引用会失效。
    virtual Status Redo(Timeline& model) { return Do(model); }

    // 变更名（日志 / 诊断用；ChangeRecord 的 name 由 Session 提交方提供）。
    virtual const char* Name() const = 0;
};

// ---------------------------------------------------------------------------
// 命令历史（线性：无分支；新 Execute 丢弃 redo 分支）
// ---------------------------------------------------------------------------
class CommandHistory {
public:
    // 执行并（成功时）入撤销栈。失败：**不入栈、不改历史、模型未变更**，
    // redo 分支也保持原状（失败不丢历史）。
    Status Execute(std::unique_ptr<ICommand> cmd, Timeline& model);

    // 撤销最近一条。空历史返回 kInvalidArgument。
    // 失败（不变量被破坏）时栈保持不变 —— 正常用法下不应发生，测试守卫。
    Status Undo(Timeline& model);

    // 重做。空 redo 栈返回 kInvalidArgument。
    Status Redo(Timeline& model);

    bool CanUndo() const { return !undo_stack_.empty(); }
    bool CanRedo() const { return !redo_stack_.empty(); }
    size_t UndoDepth() const { return undo_stack_.size(); }

    // 清空（丢弃全部历史；模型不变）。用于关闭工程等场景。
    void Clear();

private:
    std::vector<std::unique_ptr<ICommand>> undo_stack_;
    std::vector<std::unique_ptr<ICommand>> redo_stack_;
};

// ---------------------------------------------------------------------------
// 结构类：加轨道。Undo = 删轨道（此时轨道内容必为空，见不变量 3）。
// ---------------------------------------------------------------------------
class AddTrackCommand : public ICommand {
public:
    explicit AddTrackCommand(TrackKind kind) : kind_(kind) {}

    Status Do(Timeline& model) override;
    // Redo 不能再走 AddTrack（会分配新 id）—— 用 Do 时捕获的轨道快照恢复原 id。
    Status Redo(Timeline& model) override;
    Status Undo(Timeline& model) override;
    const char* Name() const override { return "add-track"; }

private:
    TrackKind kind_;
    uint64_t track_id_ = 0;  // 首次 Do 后有效
    Track snapshot_{};       // 首次 Do 后捕获（Redo 的 RestoreTrack 输入）
    bool captured_ = false;
};

// ---------------------------------------------------------------------------
// 结构类：删轨道。Undo/Redo 都靠 Do 时捕获的轨道快照（含全部片段）。
// ---------------------------------------------------------------------------
class RemoveTrackCommand : public ICommand {
public:
    explicit RemoveTrackCommand(uint64_t track_id) : track_id_(track_id) {}

    Status Do(Timeline& model) override;
    Status Undo(Timeline& model) override;
    const char* Name() const override { return "remove-track"; }

private:
    uint64_t track_id_;
    Track snapshot_{};  // Do 时捕获（RestoreTrack 的输入）
    bool captured_ = false;
};

// ---------------------------------------------------------------------------
// 结构类：插片段。Undo = 删片段；Redo = RestoreClip（原 id）。
// ---------------------------------------------------------------------------
class InsertClipCommand : public ICommand {
public:
    // clip 参数中的 id 字段被忽略（由 Timeline 分配）；track_id 指定目标轨道。
    InsertClipCommand(uint64_t track_id, const Clip& clip)
        : track_id_(track_id), clip_(clip) {}

    Status Do(Timeline& model) override;
    Status Redo(Timeline& model) override;
    Status Undo(Timeline& model) override;
    const char* Name() const override { return "insert-clip"; }

    // 首次 Do 后有效：实际分配的片段 id（UI 拿它做后续选择/拖拽）。
    uint64_t clip_id() const { return clip_id_; }

private:
    uint64_t track_id_;
    Clip clip_;              // 用户输入参数（id 字段无效）
    uint64_t clip_id_ = 0;   // 首次 Do 分配的 id
};

// ---------------------------------------------------------------------------
// 结构类：删片段。Undo = RestoreClip（原 id 原轨道）；Redo = RemoveClip。
// ---------------------------------------------------------------------------
class RemoveClipCommand : public ICommand {
public:
    explicit RemoveClipCommand(uint64_t clip_id) : clip_id_(clip_id) {}

    Status Do(Timeline& model) override;
    Status Undo(Timeline& model) override;
    const char* Name() const override { return "remove-clip"; }

private:
    uint64_t clip_id_;
    Clip snapshot_{};        // Do 时捕获
    uint64_t track_id_ = 0;  // 片段原所在轨道
    bool captured_ = false;
};

// ---------------------------------------------------------------------------
// 编辑类：移动片段（只存增量 —— model.md 硬约束 #2 的原型）。
// ---------------------------------------------------------------------------
class MoveClipCommand : public ICommand {
public:
    MoveClipCommand(uint64_t clip_id, const RationalTime& new_start)
        : clip_id_(clip_id), new_start_(new_start) {}

    Status Do(Timeline& model) override;
    Status Undo(Timeline& model) override;
    const char* Name() const override { return "move-clip"; }

private:
    uint64_t clip_id_;
    RationalTime new_start_;
    RationalTime old_start_{0, 1};  // 首次 Do 时捕获
};

// ---------------------------------------------------------------------------
// 编辑类：修剪片段时长（当前模型语义：只改 duration，不动 source_in）。
// ---------------------------------------------------------------------------
class TrimClipCommand : public ICommand {
public:
    TrimClipCommand(uint64_t clip_id, const RationalTime& new_duration)
        : clip_id_(clip_id), new_duration_(new_duration) {}

    Status Do(Timeline& model) override;
    Status Undo(Timeline& model) override;
    const char* Name() const override { return "trim-clip"; }

private:
    uint64_t clip_id_;
    RationalTime new_duration_;
    RationalTime old_duration_{0, 1};  // 首次 Do 时捕获
};

}  // namespace cq

#endif /* CQ_COMMAND_COMMAND_H_ */
