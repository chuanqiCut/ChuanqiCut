# TASK-CORE-009：EditorSession 门面与快照机制

- **层**：跨平台内核（`core/src/session/`）
- **依赖**：CORE-006（PAL 冻结）、**CORE-008（线程模型，已完成）**
- **阻塞**：**BIND-001**（C ABI）→ BIND-002（Swift 绑定）→ 所有 UIA-*
- **规格**：`docs/specs/ARCH-001-技术方案总纲.md` §4.1（`session` = 对外唯一门面）
- **日期**：2026-09-29

## 背景

ARCH-001 §4.1 把 `session` 定义为「串起上述模块，**对外唯一门面**」（`EditorSession`）。
它是 BIND-001 要冻结成 C ABI 的对象，但目前**完全不存在** —— 这是整条
`BIND-001 → BIND-002 → 所有 UIA-*` 依赖链上最后的缺口。

## 边界（重要：不越界替后续任务做掉）

| 任务 | 职责 | 状态 |
|---|---|---|
| MODEL-001 | Timeline/Track/Clip/Transition 数据模型 | **未做**（`core/src/model/*`） |
| MODEL-002 | Command 模式 + CommandHistory + Undo/Redo | **未做**（`core/src/command/*`） |
| **CORE-009** | EditorSession 门面 + 快照机制 | **本任务**（`core/src/session/*`） |

因此本任务**不做**：
- 不定义 `TimelineModel`（MODEL-001 的活）
- 不定义 `EditorCommand` / `CommandHistory` / Undo-Redo（MODEL-002 的活）

本任务**只做**：门面骨架与**快照机制**——版本号递增、变更追踪、UI 可 diff。
状态内容由模型层通过 `ISessionState` 注入，本期用测试实现跑通机制
（避免又造一个"接口冻结但实现是断的"的空壳）。

## 写集（write_set）

| 文件 | 动作 | 说明 |
|---|---|---|
| `core/include/cq/session/snapshot.h` | 新增 | `Snapshot` / `ChangeRecord` / `ISessionState` |
| `core/include/cq/session/editor_session.h` | 新增 | `EditorSession` 门面 |
| `core/src/session/editor_session.cpp` | 新增 | 实现 |
| `core/CMakeLists.txt` | 修改 | 登记新 `.cpp` |
| `tests/unit/test_editor_session.cpp` | 新增 | 含版本递增 / diff / 线程验证 |
| `tests/CMakeLists.txt` | 修改 | 注册新用例 |

## 设计决策（评审点）

### D1 · 变更提交**异步不阻塞**，观察者在 session 线程回调

`Submit()` 投递到 CORE-008 的 `TaskRunner`，立即返回（主线程零阻塞）。
完成后通过 `SnapshotObserver` 通知 —— **回调在 session 线程执行**，调用方自行
转发到 UI 线程。

**不提供 `SubmitAndWait`**：与 CORE-008 同一条理由 —— 同步版本会让
「主线程零阻塞」在 API 面被破坏得更隐蔽。UI 靠快照版本变化感知结果。

### D2 · 版本号只在**变更成功**时递增

`mutate()` 返回非 Ok → 版本不动、不记录变更。失败不该让 UI 以为状态变了。
取消（kCancelled）同样不推进版本。

### D3 · `ISessionState` 是扩展点，不是模型实现

`EditorSession` 不认识 `TimelineModel`（它还没出生），只要求注入方实现
`ISessionState::Digest()`。本期测试注入一个 `TestState` 证明机制真跑通；
MODEL-001 落地后由 `TimelineModel` 实现该接口。

这样避免两件事：① CORE-009 阻塞在 MODEL-001 上；② 门面里塞进假模型（断接口）。

### D4 · 快照读取**跨线程安全**，且不调用状态对象

`CurrentSnapshot()` 可能被主线程（UI 刷新）随时调用，而状态对象此刻可能正被
session 线程修改。故 session 线程在变更成功后**预先算好 digest 存入 atomic**，
读路径只读 atomic，绝不跨线程调用 `state->Digest()`。

### D5 · 不保存历史快照（那是 Undo/Redo 的事）

只保存「当前快照 + 变更记录列表」。按版本回溯历史**状态**需要快照存储，
属 MODEL-002 的 CommandHistory 范畴，此处不预设。
`ChangesSince(v)` 提供的是**变更日志**（UI 可据此做增量刷新），不是状态回滚。

## 验证命令

```bash
tools/build/build_core.sh --platform=apple --config=Debug   --test
tools/build/build_core.sh --platform=apple --config=Release --test
tools/build/build_core_apple.sh --config=Release
python3 tools/pal/check_pal_headers.py
```

## 验收标准（对应 BACKLOG「快照版本号递增，UI 可 diff」）

- 每次成功 `Submit` → 版本号 **+1**；失败/取消 → **不推进**
- `ChangesSince(from)` 返回该版本之后的全部变更记录（UI 可 diff）
- 主线程 `Submit` 不阻塞：**实测 < 16ms**
- 变更在 session 线程**串行**执行（不并发）
- 观察者在 session 线程被调用，且能拿到递增后的快照
- 未注入 `ISessionState` 时 digest 为 0，机制仍可用（不崩）

## 剩余风险

- 状态内容（digest 语义）由模型层定义；本期只用计数器验证机制，
  **不代表真实模型的 diff 能力**。
- 观察者在 session 线程回调：Swift 侧（BIND-002）必须自己 dispatch 到主线程，
  否则 UI 更新会跑错线程。需在 BIND-002 明确处理。
- `Submit` 队列满返回 `kResourceExhausted`，UI 需自行重试/降速 —— 本任务不内置重试
  （重试策略属于交互层语义）。
