// ChuanqiCut — EditorModelState：Session 的真实模型状态（UIA-009 子步骤 1）
//
// 这是 CORE-009 留下的 ISessionState 扩展点的**模型层实现**（此前只有测试桩）：
// 把 MODEL-001 的 Timeline、素材表（BIND-003 子步骤 1）与 MODEL-002 的
// CommandHistory 组装成会话状态 —— digest 从此是真实的，时间线从此可查。
//
// 线程模型（与 CORE-009 的约定一致）：
//   * 全部**变更接口**（Execute / RegisterAsset 等）只在 **session 线程** 调用
//     （经 EditorSession::Submit 投递，天然串行）。
//   * **读路径**走已发布的不可变快照：每次成功变更后重建
//     `shared_ptr<const Timeline>` 并原子发布；任意线程原子加载，无锁、不阻塞。
//     这同时是预览（UIA-009 D2）与时间线视图（UIA-004）的读路径。
//   * ⚠️ 快照是**变更后发布**（不是变更前）——读侧看到的是「某次成功变更之后」
//     的完整状态，不存在半更新。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常（错误一律 Status）。

#ifndef CQ_MODEL_EDITOR_MODEL_STATE_H_
#define CQ_MODEL_EDITOR_MODEL_STATE_H_

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

#include "cq/base/status.h"
#include "cq/command/command.h"
#include "cq/media/asset_registry.h"
#include "cq/model/model_snapshot.h"
#include "cq/model/timeline.h"
#include "cq/session/session_snapshot.h"

namespace cq {

class EditorModelState final : public ISessionState {
public:
    EditorModelState();

    EditorModelState(const EditorModelState&) = delete;
    EditorModelState& operator=(const EditorModelState&) = delete;

    // ---- 变更（仅 session 线程，经 EditorSession 投递）----

    // 经 CommandHistory 执行命令；成功后发布新快照并更新 fingerprint。
    // 失败：历史与模型不动（MODEL-002 语义），也不发布。
    Status Execute(std::unique_ptr<ICommand> cmd);

    // ---- 撤销 / 重做（仅 session 线程；UIA-005）----
    // 与 Execute 同构：成功后发布新快照，失败则历史与模型都不动。
    // 空历史返回 kInvalidArgument（CommandHistory 语义）。
    Status Undo();
    Status Redo();

    // 注册素材（id → 路径）。**不走 Command**：素材是资料库不是时间线编辑，
    // 不参与 Undo/Redo；但**会发布新快照**（素材表进入快照配对，预览读得到）。
    // 版本推进由 EditorSession 负责。fingerprint 不含素材表 —— 时间线结构未变。
    Status RegisterAsset(uint64_t asset_id, const std::string& path);

    // ---- session 线程内的直读（mutate 闭包内用，勿跨线程持有引用）----
    Timeline& timeline() { return timeline_; }
    CommandHistory& history() { return history_; }
    AssetRegistry& assets() { return assets_; }

    // ---- 读路径（任意线程）----

    // 最近一次成功变更后的模型快照（Timeline + AssetRegistry 配对，不可变）。
    // 初始即有值（空时间线 + 空素材表）。实现：mutex 保护的 shared_ptr
    // （持锁时长 = 一次指针拷贝，纳秒级；写侧只在命令提交后发生，无竞争压力）。
    // ⚠️ C++20 的 atomic<shared_ptr> 本机 libc++（Xcode 16 / x86_64）未实现
    // P0718，编译期即报 "_Atomic ... not trivially copyable"（2026-10-03 实测）。
    std::shared_ptr<const ModelSnapshot> CurrentSnapshot() const;

    // 便捷取时间线部分（同一份已发布快照，引用计数保证存活）。
    std::shared_ptr<const Timeline> CurrentTimeline() const;

    // ---- 撤销栈能力（任意线程读；UIA-005 D3）----
    // ⚠️ 不能直接读 CommandHistory：它非线程安全、只在 session 线程变更。
    //    故在这里缓存两个原子标志，由 Execute/Undo/Redo 成功后刷新。
    bool CanUndo() const { return can_undo_.load(std::memory_order_acquire); }
    bool CanRedo() const { return can_redo_.load(std::memory_order_acquire); }

    // ISessionState
    uint64_t Digest() const override;  // = fingerprint（时间线结构哈希）
    const char* TypeName() const override { return "EditorModelState"; }

    // fingerprint 算法（公开供测试比对）：对轨道/片段实体逐字段 FNV-1a。
    // 与 ui 呈现无关，只用于「状态是否变了」；字段增删会整体变，无兼容承诺。
    static uint64_t Fingerprint(const Timeline& timeline);

private:
    void Publish();  // (timeline_, assets_) → 重建配对快照并发布（session 线程）
    void RefreshHistoryFlags();  // history_ → can_undo_/can_redo_（session 线程）

    Timeline timeline_;
    AssetRegistry assets_;
    CommandHistory history_;

    // 撤销栈能力标志：session 线程写（Execute/Undo/Redo 后），任意线程读。
    std::atomic<bool> can_undo_{false};
    std::atomic<bool> can_redo_{false};

    // 不可变快照的发布点。mutable：读接口（const）也要锁。
    mutable std::mutex snap_mtx_;
    std::shared_ptr<const ModelSnapshot> published_;
};

}  // namespace cq

#endif /* CQ_MODEL_EDITOR_MODEL_STATE_H_ */
