# 模块：时间线模型与命令

> **归属**：A 线（编辑器/UI；时间线模型与命令） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`core/src/model/`、`core/src/command/`、`core/src/anim/`

## 职责
Timeline / Track / Clip / Transition / EffectBinding 数据模型；Command 模式与 Undo/Redo；关键帧与插值引擎。

## 入口
- `TimelineModel` — 轨道、片段、转场、效果挂载
- `EditorCommand` / `CommandHistory` — **所有模型变更的唯一入口**
- `Keyframe<T>` / `AnimationChannel<T>` / 插值引擎 — Linear / Bezier / Hermite / Catmull-Rom

## 硬约束
1. **UI 不得直接修改模型**，一律走 `Command`。这是 Undo/Redo 与三端一致性的前提。
2. Command 只存"怎么撤销"（如 clipID + oldTime + newTime），不存数据拷贝。
3. 时间字段一律 `RationalTime`。
4. 模型序列化必须能往返（serialize → deserialize → 相等）。

## 验证
```bash
ctest -R model_command     # 100 次 undo 后回到初始态
ctest -R model_serialize   # 往返一致
ctest -R anim_interp       # 四种插值曲线正确性
```

## 相关
ADR-0006、`docs/tasks/TASK-BACKLOG.md` 的 `MODEL-0xx` / `ANIM-0xx`


---

# MODEL-002 落地（2026-10-03）：Command / CommandHistory

## 位置与入口

- `core/include/cq/command/command.h` + `core/src/command/command.cpp`
- `ICommand`（Do / Undo / Redo / Name）+ `CommandHistory`（Execute/Undo/Redo/CanX/Depth/Clear）
- 首批 6 个命令覆盖 Timeline 全部变更面：
  `AddTrack / RemoveTrack / InsertClip / RemoveClip / MoveClip / TrimClip`

## 语义要点

| 主题 | 约定 |
|---|---|
| 失败语义 | Execute 失败 = 不入栈、模型不变、**redo 分支保留**；Undo/Redo 失败 = 栈不动（不变量破坏，测试守卫） |
| 线性历史 | 新 Execute 丢弃 redo 分支；Clear() 清双栈不动模型 |
| 编辑类命令 | 只存增量（clipID + old/new 值），不存实体 —— 硬约束 #2 原型 |
| 结构类命令 | 持有受影响**单个实体**的内容（命令输入参数 / 回放依据），不做模型级快照 |
| Redo 的 id | Add/Insert 重放会分配新 id → 必须走 `RestoreTrack/RestoreClip` 恢复**原 id**，否则历史里后续命令的引用悬空 |
| 线程 | 非线程安全，在 session 线程用（CORE-009 已串行化） |

## Timeline 最小扩展

`RestoreTrack(const Track&)` / `RestoreClip(uint64_t track_id, const Clip&)`：
按实体自带 id 恢复，不分配新 id；校验与 Add/Insert 一致；`next_id_` 仍单调推进。
**仅供 Command 回放 / 序列化载入**，业务代码不要直调。

## 不变量（破坏即 Undo 栈失效）

1. Timeline 只能经 CommandHistory 变更（绕过直改会让历史 id 引用悬空）。
2. 命令 Do/Undo/Redo 失败时不得改动模型（先校验后变更，与 Timeline 同风格）。
3. Undo/Redo 按栈序（LIFO）：相邻命令的实体引用靠顺序保持有效。

## 验证

```bash
ctest --test-dir build -R model_command   # 4 组用例：逐命令往返 / 201 深度全撤销回初始态 /
                                          # 失败语义 / 排序不变量（门禁 35/35）
ctest --test-dir build -R c_abi_edit      # UIA-005：move/trim/undo/redo 经 C ABI 的往返
```

# UIA-005 落地（2026-10-03）：撤销链路接到 C ABI

`CommandHistory` 此前只有 C++ 侧入口（MODEL-002 完成但**对外不可用**）。
UIA-005 把它接到 `EditorModelState::Undo/Redo` 与 `cq_session_undo/redo`。

- **撤销也发布新快照**：`Undo/Redo` 成功后 `Publish()`（否则 UI 读到的还是旧
  时间线）+ `RefreshHistoryFlags()`（刷新 can_undo/can_redo 原子标志）。
- **id 稳定性得到 C 侧实证**：全 undo 到空再全 redo，clip id 与撤销前完全相同
  （`RestoreClip` 生效，未重分配）—— 这是不变量 3 的端到端守卫。
- **digest 可回退**：undo 到某一步时 fingerprint 与「那一步之前」的值相等，
  测试直接断言相等（不是"变了就行"）。

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| Task ID | 标题 | 状态 |
|---|---|---|
| MODEL-001/002 | 时间线模型 / Command+History | ✅（编辑链在用） |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| — | 未实测（本模块无独立阶段批记录） | — |

### 调研 · 决策 · 池指针

- ADR-0012（命令提交时机）· 红线 #5（UI 不直改模型）
