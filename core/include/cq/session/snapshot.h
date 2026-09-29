// ChuanqiCut — 会话快照与变更记录（CORE-009）
//
// 边界（详见 docs/tasks/TASK-CORE-009.md）：
//   本文件只定义**快照机制**，不定义编辑模型（那是 MODEL-001 的 TimelineModel），
//   也不定义 Command / Undo-Redo（那是 MODEL-002 的 CommandHistory）。
//   EditorSession 通过 ISessionState 这个扩展点拿到"状态是什么"，
//   从而在模型层尚未落地时也能把门面机制做实、做可测。

#ifndef CQ_SESSION_SNAPSHOT_H_
#define CQ_SESSION_SNAPSHOT_H_

#include <cstdint>

#include "cq/base/status.h"

namespace cq {

// ---- 状态扩展点（由模型层实现，见 D3）-------------------------------------
// EditorSession 不认识 TimelineModel，只要求注入方能给出状态摘要。
// 这样 CORE-009 不必阻塞在 MODEL-001 上，也不会在门面里塞一个假模型。
//
// ⚠️ 线程约定：Digest() 只会在 **session 线程** 被调用（变更提交成功后）。
//    不得跨线程调用 —— 读取方请用 EditorSession::CurrentSnapshot()（见 D4）。
class ISessionState {
public:
    virtual ~ISessionState() = default;

    // 当前状态的摘要。语义由模型层定义（例如时间线结构哈希）。
    // 仅用于「状态是否变了」的快速判断与 diff 辅助，不要求全局唯一。
    virtual uint64_t Digest() const = 0;

    // 状态类型名（仅用于日志/诊断文本，须指向静态存储）。
    virtual const char* TypeName() const = 0;
};

// ---- 快照 ------------------------------------------------------------------
// 版本 0 表示"尚未发生任何变更"的初始状态。
struct Snapshot {
    uint64_t version = 0;  // 单调递增；每次成功的变更 +1
    uint64_t digest = 0;   // 状态摘要（未注入 ISessionState 时恒为 0）
};

inline bool operator==(const Snapshot& a, const Snapshot& b) {
    return a.version == b.version && a.digest == b.digest;
}
inline bool operator!=(const Snapshot& a, const Snapshot& b) { return !(a == b); }

// ---- 变更记录 --------------------------------------------------------------
// UI 据此做增量刷新：给定"我上次看到的版本"，取之后发生的所有变更（可 diff）。
struct ChangeRecord {
    uint64_t version = 0;    // 本次变更产生的版本号
    const char* name = "";   // 变更名，**须指向静态存储**（本结构不持有所有权）
    Status status = Status::Ok();  // 该变更的执行结果；此处恒为 Ok（失败不记录）
};

}  // namespace cq

#endif  // CQ_SESSION_SNAPSHOT_H_
