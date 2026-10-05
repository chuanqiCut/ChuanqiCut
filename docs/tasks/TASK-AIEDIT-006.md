# TASK-AIEDIT-006：EditPlan→Command 执行器 + 新增命令类型

```yaml
id:          AIEDIT-006
layer:       SDK
goal:        EditPlan.action 列表 → 原子 Command 批次（经 cq_session_submit）；新增 RemoveRange/SetTransition 命令
input:       [AIEDIT-001 契约, ADR-0012（提交时机与线程边界）, SPEC §7, .ai/modules/model.md]
output:      [新命令类型, 执行器, 复合命令批次, 单测]
write_set:   core/include/cq/command/command.h(新增 RemoveRangeCommand/SetTransitionCommand —— 高冲突文件,批次内独占)、
             core/src/command/*(新命令实现)、core/src/ai/plan/plan_executor.{h,cpp}(新)、
             core/tests/test_plan_executor.cpp(新)、core/tests/test_command_new_ops.cpp(新)
read_set:    core/include/cq/ai/edit_plan.h, core/include/cq/model/timeline.h, core/include/cq/session/*, docs/decisions/ADR-0012
deps:        [AIEDIT-001]
acceptance:
  - 应用合法 plan 后 cq_session_timeline_duration 与 plan 声明总时长有理数精确相等（RationalTime 比较非浮点）
  - undo 一次 → ModelSnapshot 与应用前逐字段相等（快照 diff 断言）；redo 恢复
  - 批次原子性：构造中途失败 plan（越界 trim），断言时间线零残留变更且失败命令不入栈（ADR-0012）
  - remove_range 跨 clip 中段切割删除：对 3 clip 场景产出正确 source_in/修复相邻边界，快照断言
  - set_transition 写入 in/out_transition + duration，且转场不延长 clip 占时（timeline.h 硬约束）
  - select_*/set_bgm_placeholder 不触模型、进 Narrative 记录层
  - ctest -R "plan_executor|command_new_ops" 全绿
verification:
  - ctest --test-dir build -R "plan_executor|command_new_ops"
  - tools/build/build_core.sh --platform=apple
risk:        command.h 是全仓高冲突文件 → 批次 2 内独占触碰；只追加类型不改动既有 6 命令（grep diff 审查）
parallel:    true（批次 2，command.h 独占）
```

## 背景

AI 产物与人手编辑必须同一撤销栈（ADR-0020 决策 4）。既有 6 命令不够表达 plan 的 remove_range/set_transition；新增命令同样服务手动编辑（转场 UI 复用）。

## 实现要点

1. `RemoveRangeCommand`：对 [start,end) 区间做 trim+split+remove 复合；构造期完成校验，Do 返回失败即整批拒绝。
2. 批次 = `PlanBatchCommand`（复合命令）：子命令顺序 Do、逆序 Undo；子命令失败 → 已 Do 的逆序回滚，整批不入栈。
3. 批次命名 `plan:<schema>@<timeline_rev>`，供 UI"撤销本轮 AI 调整"定位。
4. 执行器在 session 线程外不做任何模型读写（线程边界对照 ADR-0012）。

## 回写

.ai/modules/model.md 增补两条新命令；pitfalls 记录复合命令回滚次序坑（若有）。
