# TASK-MODEL-002：Command 模式与 CommandHistory（Undo/Redo）

```yaml
id:          TASK-MODEL-002
layer:       跨平台
goal:        把 Timeline 的全部变更收口为 Command（含可逆执行与线性历史），使 UI 变更可 Undo/Redo
input:       [docs/tasks/TASK-BACKLOG.md §3.4 MODEL-002, .ai/modules/model.md, .ai/modules/session.md, docs/decisions/ADR-0006-有理数时间与项目文件版本模型.md]
output:      [core/include/cq/command/*.h, core/src/command/*.cpp, core/src/model/timeline.* 最小扩展, tests/unit/test_model_command.cpp, .ai/modules/model.md 回写]
write_set:   core/include/cq/command/ + core/src/command/ + core/include/cq/model/timeline.h + core/src/model/timeline.cpp + tests/unit/test_model_command.cpp + tests/unit/CMakeLists.txt（仅登记新测试）
read_set:    core/include/cq/model/timeline.h, core/include/cq/base/{status,time,concurrency}.h, core/include/cq/session/editor_session.h
deps:        [MODEL-001]
acceptance:
  - 100 次「变更→undo」交替后，模型回到初始态（digest 或逐字段比对）
  - 连续 100 次 Add+Move+Trim 后 100 次 undo，回到初始态；再 100 次 redo，回到最终态
  - 失败的 Do（重叠 Move / 非法 Trim）不进入历史、不推进模型
  - Add/Remove 的 redo 恢复**同一 id**（RestoreClip/RestoreTrack 路径）
  - RemoveTrack 的 undo 恢复该轨道及其全部片段
verification:
  - ./tools/build/build_core.sh --platform=apple --config=Debug --test
  - ctest --test-dir build -R model_command
  - ./tools/build/build_core.sh --platform=apple --config=Release --test
risk:        Add/Remove 类命令的 redo 需要恢复同一 id（Timeline 现有 API 每次分配新 id）——
             用 RestoreTrack/RestoreClip 显式恢复解决，且 RestoreX 不得破坏 next_id_ 单调性；
             RemoveTrack 的 undo 需要深拷贝轨道内容，属「命令输入参数」而非模型快照，
             在 command.h 注释中与硬约束 #2 的边界写清。
parallel:    true（写集与 UIA-004 不相交；cq_sdk.h 不动）
```

## 状态：已完成（2026-10-03）

- 门禁：Debug **35/35**、Release **35/35**（`model_command` 0.31s / 0.22s，4 组用例全过）
- 验收逐条：①201 深度全撤销回初始态（指纹逐字段比对）✓ ②全撤销后全重做回最终态 ✓
  ③失败 Do（重叠 Move / 零 Trim / 缺失实体 / nullptr）不入历史、不改模型、不清 redo ✓
  ④Add/Insert 的 Redo 经 RestoreX 恢复原 id（指纹含 id 已验证）✓
  ⑤RemoveTrack 的 Undo 完整恢复轨道 + 片段 ✓
- 无新增 ADR（未改变既有惯例；RestoreX 属模块内接口补充，语义见 model.md）

## 背景

- BACKLOG §3.4：MODEL-002 = Command 模式与 CommandHistory，写集 `core/src/command/*`，
  验收「100 次 undo 后回到初始态」。
- 红线 #5：UI 不得直接改模型，所有变更走 Command —— 这是 Undo/Redo 与三端一致性的前提。
- 现状：`Timeline`（MODEL-001）只有直改方法；`EditorSession`（CORE-009）有通用
  Command 队列（session 线程串行 + 快照版本推进），但没有可逆命令语义。
  下游 UIA-005（拖拽/裁剪提交 Command）、UIA-006（参数走 Command）、UIA-008
  （Undo/Redo 入口）全部堵在 本任务上。

## 实现要点

### 契约（`core/include/cq/command/command.h`）

```cpp
class ICommand {                     // 非 thread-safe：在 session 线程使用
public:
    virtual ~ICommand() = default;
    virtual Status Do(Timeline& model) = 0;    // 首次执行 / Redo
    virtual Status Undo(Timeline& model) = 0;
    virtual const char* Name() const = 0;      // 进 ChangeRecord
};

class CommandHistory {               // 线性历史（无分支）
public:
    Status Execute(std::unique_ptr<ICommand> cmd, Timeline& model);  // 失败不入栈
    Status Undo(Timeline& model);
    Status Redo(Timeline& model);
    bool CanUndo() const;  bool CanRedo() const;
    size_t UndoDepth() const;
    void Clear();
};
```

- 错误一律 Status（内核禁用异常）；`Execute` 失败时**不推进历史、不推进模型**
  （与 CORE-009「仅成功推进」语义对齐）。
- Undo/Redo 失败视为**不变量破坏**（历史里已验证过的命令不应失败）：保持栈状态
  不变并返回错误，测试断言这类路径不会发生。

### 首批具体命令（覆盖 Timeline 全部变更面）

| 命令 | Do | Undo | Redo 支撑 |
|---|---|---|---|
| AddTrackCommand(kind) | AddTrack → 记录 id | RemoveTrack(id) | RestoreTrack(快照) |
| RemoveTrackCommand(id) | Do 时深拷贝 Track（含 clips）后 RemoveTrack | RestoreTrack | 同上 |
| InsertClipCommand(track_id, clip参数) | InsertClip → 记录 id | RemoveClip(id) | RestoreClip |
| RemoveClipCommand(id) | Do 时拷贝 Clip + 所属 track_id | RestoreClip | 同上 |
| MoveClipCommand(id, new_start) | 记录 old_start 后 MoveClip | MoveClip(old_start) | MoveClip(new_start) |
| TrimClipCommand(id, new_duration) | 记录 old_duration 后 TrimClip | TrimClip(old_duration) | TrimClip(new_duration) |

- 编辑类（Move/Trim）只存增量（old/new 值 + id）——即硬约束 #2 的「clipID + oldTime
  + newTime」，**不存模型快照**。
- Add/Remove 类必须持有实体内容才能 redo/undo，这属于**命令的输入参数**（用户提交时
  给的就是这些值），不是「模型快照」；边界在 command.h 头注释写明。

### Timeline 最小扩展（`core/src/model/timeline.*`）

```cpp
// 仅供 Command / 序列化层恢复用：按显式 id 插入，不分配新 id；
// next_id_ 仍保持单调（max(next_id_, id+1)），保证后续新实体的 id 唯一性。
Status RestoreTrack(const Track& track);
Status RestoreClip(uint64_t track_id, const Clip& clip);
```

- 不改既有 API 语义；RestoreX 的重叠校验与对应 Add/Insert 一致（历史回放时
  不应触发，触发即测试失败）。

## 验收

1. `ctest -R model_command` 全绿，覆盖上表 6 命令的 Do/Undo/Redo 往返。
2. 压力用例：随机交错 100 次变更（合法路径）→ 100 次 Undo → 逐字段比对 == 初始态
   → 100 次 Redo → == 最终态。
3. 失败 Do 不入历史：重叠 Move 返回错误后，UndoDepth 不变、模型不变。
4. 回写：`.ai/modules/model.md` 补 command 层装配形状与语义表。

## 回写

- 架构事实（Command 契约 + RestoreX 语义）→ `.ai/modules/model.md`
- 踩坑 → `.ai/memory/pitfalls.md`
- 若有实测（Submit+Execute 开销）→ `.ai/memory/baselines.md`；无实测明确写"未实测"
