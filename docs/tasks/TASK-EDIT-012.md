# TASK-EDIT-012：commit / done 双层提交（PreviewSync 通道）

> **状态：📋 已立卡，未开工**（2026-10-13，ADR-0040 拍板；与 MODEL-004 同属 B5.5）。
> 前置：B4（导出闭环）之后开工。

```yaml
id:          EDIT-012
layer:       跨平台
goal:        把「让画面跟上」与「记一笔可撤销的操作」拆成两层：
             连续操作走 PreviewSync（只 diff → 渲染，不入 undo 栈），
             操作结束走 Execute（入 undo 栈）。二者共用同一个 diff 出口。
             保留现有 Command 增量路线，不改为整模型快照
input:       [ADR-0040（本卡依据）, RESEARCH-016 §2.1（commit/done 双层）,
             RESEARCH-016 §3.7（不采纳快照式 undo 的理由）, 红线 #5, 红线 #9,
             ADR-0014（不得出现第二套路径）, .ai/modules/session.md]
output:      [cq/command/chq_command.{h,cpp}(PreviewSync 通道),
             cq/session/chq_editor_session.{h,cpp}(对外入口),
             tests/unit/test_command_preview_sync.cpp(新), tests/CMakeLists.txt]
write_set:   engine/core/cq/command/chq_command.{h,cpp}、
             engine/core/cq/session/chq_editor_session.{h,cpp}、
             tests/unit/test_command_preview_sync.cpp(新)、tests/CMakeLists.txt
             （若需对外暴露则含 cq_sdk.{h,cpp} —— 属热点，由集成机承接）
read_set:    cq/model/chq_timeline.h、cq/model/chq_editor_model_state.h、
             cq/render/*（B0 已落地的 diff/装配出口）
deps:        [MODEL-002, B0（同一 diff 出口的前提）, B4]
acceptance:
  - PreviewSync **不入 undo 栈**：连续 N 次 PreviewSync + 1 次 Execute，
    undo 栈深度只 +1（N 取 50，单测锁定）
  - PreviewSync 与 Execute **共用同一个 diff 出口**：不得出现第二个渲染同步路径
    （违反即 ADR-0014 复发，本条为硬性验收项，需在单测或代码结构上可证明）
  - Execute 的三件事（改模型 + 入栈 + 触发刷新）语义不变，既有命令全部不受影响
    （现有 ChqAddTrackCommand / ChqSplitClipCommand 等单测必须仍全绿）
  - 失败不入栈、不清 redo 分支（沿用既有 ChqCommandHistory 纪律）
  - 高频 PreviewSync 不得产生内存增长：连续 1000 次后 RSS 平稳（单测或基准断言）
  - 与拖拽场景对齐：拖拽开始 → PreviewSync（每帧）；拖拽结束 → Execute（一条）
  - 契约头门禁 PASS
```

## 设计约束（开工前必读）

1. **不推翻 Command**：在 `ChqCommandHistory` **之上**加通道，不是替换它。
   现有增量路线（编辑类存增量、结构类存单实体快照）的纪律全部保留。
2. **不改为整模型快照**：对标平台 `其提交接口` 持有完整 `其数据模型`，换来「新功能自动获得 undo」，
   代价是每次提交的内存与 diff 开销。本仓已选增量，本卡不改这个选择（ADR-0040 §5）。
3. **共用 diff 出口是硬约束**：这是本卡唯一真正的设计风险点。
   一旦另开一条同步路径，就是第二套渲染路径，ADR-0014 的债会再背一次。
4. **不做 UI**：拖拽手势归 B6/B7 的 UI 面，本卡只提供内核通道与单测。

## 为什么要有这条通道

RESEARCH-016 §2.1：对标平台把渲染同步与事务边界分开后，拖拽时每帧 `commit`（画面实时跟随），
松手时一次 `done`（只产生一条撤销记录）。

本仓现状：工作区约定「拖拽结束只提交一条命令」—— 这条约定本身就是在**用纪律弥补机制缺失**，
UI 得自己憋着不提，最后一刻才提一条。本卡把这件事变成机制保证。

## 验收命令（开工时实跑并写数字）

```bash
tools/build/build_core.sh --platform=apple --config=Debug
tools/build/build_core.sh --platform=apple --config=Release
/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/ctest --test-dir build
```

> ⚠️ `ctest` 不在 PATH，须用上列全路径。

交付后按 `docs/reviews/TEMPLATE-真机问卷.md` 出问卷，**问卷未回收不得标记完成**。

---

## 签名

- 立卡：WorkBuddy（集成机），2026-10-13
- 依据：ADR-0040 + RESEARCH-016 §2.1 / §3.7
