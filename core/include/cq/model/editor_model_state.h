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

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

#include "cq/base/status.h"
#include "cq/command/command.h"
#include "cq/media/asset_registry.h"
#include "cq/model/timeline.h"
#include "cq/session/snapshot.h"

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

    // 注册素材（id → 路径）。**不走 Command**：素材是资料库不是时间线编辑，
    // 不参与 Undo/Redo；但同样发布新版本（版本推进由 EditorSession 负责）。
    // fingerprint 不含素材表 —— 时间线结构未变。
    Status RegisterAsset(uint64_t asset_id, const std::string& path);

    // ---- session 线程内的直读（mutate 闭包内用，勿跨线程持有引用）----
    Timeline& timeline() { return timeline_; }
    CommandHistory& history() { return history_; }
    AssetRegistry& assets() { return assets_; }

    // ---- 读路径（任意线程）----

    // 最近一次成功变更后的时间线快照（不可变）。初始即有值（空时间线）。
    // 实现：mutex 保护的 shared_ptr（持锁时长 = 一次指针拷贝，纳秒级；
    // 写侧只在命令提交后发生，无竞争压力）。⚠️ C++20 的
    // atomic<shared_ptr> 本机 libc++（Xcode 16 / x86_64）未实现 P0718，
    // 编译期即报 "_Atomic ... not trivially copyable"（2026-10-03 实测）。
    std::shared_ptr<const Timeline> CurrentTimeline() const;

    // ISessionState
    uint64_t Digest() const override;  // = fingerprint（时间线结构哈希）
    const char* TypeName() const override { return "EditorModelState"; }

    // fingerprint 算法（公开供测试比对）：对轨道/片段实体逐字段 FNV-1a。
    // 与 ui 呈现无关，只用于「状态是否变了」；字段增删会整体变，无兼容承诺。
    static uint64_t Fingerprint(const Timeline& timeline);

private:
    void Publish();  // timeline_ → 重建快照并发布（session 线程）

    Timeline timeline_;
    AssetRegistry assets_;
    CommandHistory history_;

    // 不可变快照的发布点。mutable：读接口（const）也要锁。
    mutable std::mutex snap_mtx_;
    std::shared_ptr<const Timeline> published_;
};

}  // namespace cq

#endif /* CQ_MODEL_EDITOR_MODEL_STATE_H_ */
