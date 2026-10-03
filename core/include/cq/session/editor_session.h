// ChuanqiCut — EditorSession：对外唯一门面（CORE-009）
//
// 规格来源：docs/specs/ARCH-001-技术方案总纲.md §4.1
//   session = 「编辑器会话：串起上述模块，对外唯一门面」
//
// 本对象是 BIND-001 要冻结成 C ABI 的东西，也是整条
// BIND-001 → BIND-002 → 所有 UIA-* 依赖链的最后缺口。
//
// 职责：
//   * 串行执行变更（复用 CORE-008 的 TaskRunner，命令天然串行 —— 这是
//     Undo/Redo 与三端一致性的前提，红线 #5）
//   * 维护快照版本号与变更日志，供 UI 增量刷新（"UI 可 diff"）
//
// 不做（避免越界，详见任务卡）：
//   * 不定义 TimelineModel（MODEL-001）
//   * 不定义 Command / CommandHistory / Undo-Redo（MODEL-002）

#ifndef CQ_SESSION_EDITOR_SESSION_H_
#define CQ_SESSION_EDITOR_SESSION_H_

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>

#include "cq/base/status.h"
// session → model：模型层（MODEL-001/002）落地后，类型化模型接口进入门面。
// CORE-009 当初用 ISessionState 解耦是为了不被 MODEL-001 阻塞，不是永久边界。
#include "cq/model/model_snapshot.h"
#include "cq/model/timeline.h"
#include "cq/session/snapshot.h"
#include "cq/session/task_runner.h"

namespace cq {

class EditorModelState;

// 变更体：在 **session 线程** 内执行。返回 Status：
//   Ok         —— 变更成功，快照版本推进（D2）
//   其它/取消  —— 变更失败或中止，版本**不推进**、不记入变更日志
using MutateFn = std::function<Status()>;

// 快照变更通知。**在 session 线程被调用**（D1）：调用方须自行转发到 UI 线程，
// 例如 Swift 侧 dispatch 到 main queue —— 本对象不替调用方做线程跳转。
using SnapshotObserver = std::function<void(const Snapshot&)>;

class EditorSession {
public:
    struct Config {
        // 变更队列容量（有界，背压）。满则 Submit 返回 kResourceExhausted，
        // 由调用方重试/降速 —— 本对象不内置重试（重试属交互层语义）。
        size_t queue_capacity = 64;
    };

    // 默认构造：内建 EditorModelState（UIA-009 子步骤 1）—— 时间线、素材表、
    // 命令历史自此成为会话状态，digest 为真实指纹。
    // 为什么写成两个重载而不是 `Config cfg = {}`：
    //   嵌套类 Config 的默认成员初始化器不能在**类外**的函数默认参数里使用
    //   （C++ 标准限制，实测 clang 报 "default member initializer needed within
    //   definition of enclosing class outside of member functions"）。
    //   改为重载 + 委托构造，语义不变。
    EditorSession();

    // state 可为 nullptr：使用**注入的自定义状态**时，模型仍是"未接入"
    // （类型化模型接口返回 kInternal，digest 由注入方决定）。
    // ⚠️ 不接管裸指针的生命周期；其生命周期须长于本对象。
    EditorSession(Config cfg, ISessionState* state = nullptr);
    ~EditorSession();

    EditorSession(const EditorSession&) = delete;
    EditorSession& operator=(const EditorSession&) = delete;

    Status Start();
    Status Shutdown();

    // ---- 变更提交（异步，不阻塞调用线程）----
    //   Ok                 —— 已入队
    //   kResourceExhausted —— 队列满（背压）
    //   kInvalidArgument   —— 未启动或已停止
    Status Submit(const char* change_name, MutateFn mutate);

    // ---- 类型化模型提交（UIA-009 子步骤 1；同样异步，不阻塞）----
    // 均经 CommandHistory（可撤销）或素材表执行，**命令参数的合法性校验发生在
    // session 线程**：Ok 只代表「已入队」，校验失败通过版本不推进 + 观察者
    // 不回调体现（调用方经 CurrentTimeline() 轮询确认）。
    //   kInternal      —— 注入了自定义 ISessionState（无内建模型）
    //   kResourceExhausted —— 队列满
    Status SubmitRegisterAsset(const char* name, uint64_t asset_id, const char* path);
    Status SubmitAddTrack(const char* name, TrackKind kind);
    Status SubmitAddClip(const char* name, uint64_t track_id, const Clip& clip);

    // ---- 快照查询（任意线程可调用）----
    // 读路径只碰 atomic：绝不跨线程调用 state->Digest()（D4）。
    Snapshot CurrentSnapshot() const;

    // 内建模型的**配对快照**（Timeline + AssetRegistry，不可变，任意线程读；
    // 预览渲染的唯一输入 —— UIA-009 子步骤 2 收口后 CQPreview 不再有本地模型）。
    // 注入自定义状态时返回 nullptr（cq_preview_create 据此返回 NULL）。
    std::shared_ptr<const ModelSnapshot> CurrentModelSnapshot() const;

    // 便捷取时间线部分（同一份快照）。
    std::shared_ptr<const Timeline> CurrentTimeline() const;

    // ---- 变更日志（UI 可 diff）----
    // 取 version > from_version 的全部变更记录，按版本升序。
    size_t ChangesSince(uint64_t from_version, std::vector<ChangeRecord>* out) const;
    size_t ChangeCount() const;

    // ---- 观察 ----
    // 设置/清除快照变更观察者。非线程安全：应在 Start() 之前或生命周期边界设置。
    void SetSnapshotObserver(SnapshotObserver observer);

    bool IsRunning() const;

private:
    void RunChange(const char* name, const MutateFn& mutate);
    EditorModelState* BuiltinModel() const;  // 内建模型（未内建时 nullptr）

    Config cfg_;
    ISessionState* state_;
    std::shared_ptr<EditorModelState> builtin_model_;  // 默认构造时创建并持有

    TaskRunner runner_;

    std::atomic<uint64_t> version_;
    std::atomic<uint64_t> digest_;
    std::atomic<bool> running_;

    // 变更日志：session 线程写，任意线程读（ChangesSince），故加锁。
    mutable std::mutex records_mtx_;
    std::vector<ChangeRecord> records_;

    // 观察者：约定在 Start 前设置，之后只读；故无需加锁（设置接口会注明）。
    SnapshotObserver observer_;
};

}  // namespace cq

#endif  // CQ_SESSION_EDITOR_SESSION_H_
