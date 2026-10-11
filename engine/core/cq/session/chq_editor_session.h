// ChuanqiCut — ChqEditorSession：对外唯一门面（CORE-009）
//
// 规格来源：docs/specs/ARCH-001-技术方案总纲.md §4.1
//   session = 「编辑器会话：串起上述模块，对外唯一门面」
//
// 本对象是 BIND-001 要冻结成 C ABI 的东西，也是整条
// BIND-001 → BIND-002 → 所有 UIA-* 依赖链的最后缺口。
//
// 职责：
//   * 串行执行变更（复用 CORE-008 的 ChqTaskRunner，命令天然串行 —— 这是
//     Undo/Redo 与三端一致性的前提，红线 #5）
//   * 维护快照版本号与变更日志，供 UI 增量刷新（"UI 可 diff"）
//
// 不做（避免越界，详见任务卡）：
//   * 不定义 TimelineModel（MODEL-001）
//   * 不定义 Command / ChqCommandHistory / Undo-Redo（MODEL-002）

#ifndef CQ_CORE_SESSION_CHQ_EDITOR_SESSION_H_
#define CQ_CORE_SESSION_CHQ_EDITOR_SESSION_H_

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>

#include "cq/base/chq_status.h"
// session → model：模型层（MODEL-001/002）落地后，类型化模型接口进入门面。
// CORE-009 当初用 ChqISessionState 解耦是为了不被 MODEL-001 阻塞，不是永久边界。
#include "cq/model/chq_model_snapshot.h"
#include "cq/model/chq_timeline.h"
#include "cq/session/chq_session_snapshot.h"
#include "cq/session/chq_task_runner.h"

namespace cq {

class ChqEditorModelState;

// 变更体：在 **session 线程** 内执行。返回 ChqStatus：
//   Ok         —— 变更成功，快照版本推进（D2）
//   其它/取消  —— 变更失败或中止，版本**不推进**、不记入变更日志
using ChqMutateFn = std::function<ChqStatus()>;

// 快照变更通知。**在 session 线程被调用**（D1）：调用方须自行转发到 UI 线程，
// 例如 Swift 侧 dispatch 到 main queue —— 本对象不替调用方做线程跳转。
using ChqSnapshotObserver = std::function<void(const ChqSnapshot&)>;

class ChqEditorSession {
public:
    struct Config {
        // 变更队列容量（有界，背压）。满则 Submit 返回 kResourceExhausted，
        // 由调用方重试/降速 —— 本对象不内置重试（重试属交互层语义）。
        size_t queue_capacity = 64;
    };

    // 默认构造：内建 ChqEditorModelState（UIA-009 子步骤 1）—— 时间线、素材表、
    // 命令历史自此成为会话状态，digest 为真实指纹。
    // 为什么写成两个重载而不是 `Config cfg = {}`：
    //   嵌套类 Config 的默认成员初始化器不能在**类外**的函数默认参数里使用
    //   （C++ 标准限制，实测 clang 报 "default member initializer needed within
    //   definition of enclosing class outside of member functions"）。
    //   改为重载 + 委托构造，语义不变。
    ChqEditorSession();

    // state 可为 nullptr：使用**注入的自定义状态**时，模型仍是"未接入"
    // （类型化模型接口返回 kInternal，digest 由注入方决定）。
    // ⚠️ 不接管裸指针的生命周期；其生命周期须长于本对象。
    ChqEditorSession(Config cfg, ChqISessionState* state = nullptr);
    ~ChqEditorSession();

    ChqEditorSession(const ChqEditorSession&) = delete;
    ChqEditorSession& operator=(const ChqEditorSession&) = delete;

    ChqStatus Start();
    ChqStatus Shutdown();

    // ---- 变更提交（异步，不阻塞调用线程）----
    //   Ok                 —— 已入队
    //   kResourceExhausted —— 队列满（背压）
    //   kInvalidArgument   —— 未启动或已停止
    ChqStatus Submit(const char* change_name, ChqMutateFn mutate);

    // ---- 类型化模型提交（UIA-009 子步骤 1；同样异步，不阻塞）----
    // 均经 ChqCommandHistory（可撤销）或素材表执行，**命令参数的合法性校验发生在
    // session 线程**：Ok 只代表「已入队」，校验失败通过版本不推进 + 观察者
    // 不回调体现（调用方经 CurrentTimeline() 轮询确认）。
    //   kInternal      —— 注入了自定义 ChqISessionState（无内建模型）
    //   kResourceExhausted —— 队列满
    ChqStatus SubmitRegisterAsset(const char* name, uint64_t asset_id, const char* path);
    ChqStatus SubmitAddTrack(const char* name, ChqTrackKind kind);
    ChqStatus SubmitAddClip(const char* name, uint64_t track_id, const ChqClip& clip);

    // ---- 编辑类提交（UIA-005；同样异步，校验在 session 线程）----
    // MoveClip：改片段起点（同轨；与同轨片段重叠 → 校验失败）。
    // TrimClip：改片段占时（duration ≤ 0 或与同轨下一片段重叠 → 校验失败）。
    // Undo/Redo：走 ChqCommandHistory。**历史本身也是 session 线程状态**，
    //   故撤销同样必须入队执行 —— 不能在调用线程直接翻栈。
    ChqStatus SubmitMoveClip(const char* name, uint64_t clip_id, const ChqRationalTime& start);
    ChqStatus SubmitTrimClip(const char* name, uint64_t clip_id, const ChqRationalTime& duration);
    // 分割（EDIT-007）：在 at 处把片段切成两半；右半新 id 经 query_clips 轮询获取。
    // 删除片段 / 删除轨道（EDIT-007）：结构类命令，Undo 走实体快照恢复原 id。
    // 左缘裁剪（EDIT-008）：右缘不动，start / source_in / duration 三字段联动。
    ChqStatus SubmitSplitClip(const char* name, uint64_t clip_id, const ChqRationalTime& at);
    ChqStatus SubmitRemoveClip(const char* name, uint64_t clip_id);
    ChqStatus SubmitRemoveTrack(const char* name, uint64_t track_id);
    ChqStatus SubmitTrimClipIn(const char* name, uint64_t clip_id, const ChqRationalTime& new_start);
    // 跨轨移动（UIA-040）：片段 id 不变，落到目标轨道 new_start 处。
    ChqStatus SubmitMoveClipToTrack(const char* name, uint64_t clip_id, uint64_t target_track_id,
                                    const ChqRationalTime& new_start);
    // 画布比例（UIA-040）：项目级属性，可撤销。
    ChqStatus SubmitSetCanvas(const char* name, int32_t width, int32_t height);
    ChqStatus SubmitUndo(const char* name);
    ChqStatus SubmitRedo(const char* name);

    // ---- 撤销栈能力（任意线程读；读的是原子标志，不触碰 history_）----
    // 注入自定义状态时恒为 false（无内建模型）。
    bool CanUndo() const;
    bool CanRedo() const;

    // ---- 快照查询（任意线程可调用）----
    // 读路径只碰 atomic：绝不跨线程调用 state->Digest()（D4）。
    ChqSnapshot CurrentSnapshot() const;

    // 内建模型的**配对快照**（ChqTimeline + ChqAssetRegistry，不可变，任意线程读；
    // 预览渲染的唯一输入 —— UIA-009 子步骤 2 收口后 CQPreview 不再有本地模型）。
    // 注入自定义状态时返回 nullptr（cq_preview_create 据此返回 NULL）。
    std::shared_ptr<const ChqModelSnapshot> CurrentModelSnapshot() const;

    // 便捷取时间线部分（同一份快照）。
    std::shared_ptr<const ChqTimeline> CurrentTimeline() const;

    // ---- 变更日志（UI 可 diff）----
    // 取 version > from_version 的全部变更记录，按版本升序。
    size_t ChangesSince(uint64_t from_version, std::vector<ChqChangeRecord>* out) const;
    size_t ChangeCount() const;

    // ---- 观察 ----
    // 设置/清除快照变更观察者。非线程安全：应在 Start() 之前或生命周期边界设置。
    void SetSnapshotObserver(ChqSnapshotObserver observer);

    bool IsRunning() const;

private:
    void RunChange(const char* name, const ChqMutateFn& mutate);
    ChqEditorModelState* BuiltinModel() const;  // 内建模型（未内建时 nullptr）

    Config cfg_;
    ChqISessionState* state_;
    std::shared_ptr<ChqEditorModelState> builtin_model_;  // 默认构造时创建并持有

    ChqTaskRunner runner_;

    std::atomic<uint64_t> version_;
    std::atomic<uint64_t> digest_;
    std::atomic<bool> running_;

    // 变更日志：session 线程写，任意线程读（ChangesSince），故加锁。
    mutable std::mutex records_mtx_;
    std::vector<ChqChangeRecord> records_;

    // 观察者：约定在 Start 前设置，之后只读；故无需加锁（设置接口会注明）。
    ChqSnapshotObserver observer_;
};

}  // namespace cq

#endif  // CQ_CORE_SESSION_CHQ_EDITOR_SESSION_H_
