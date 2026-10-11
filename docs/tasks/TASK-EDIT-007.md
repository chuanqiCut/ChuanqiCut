# TASK-EDIT-007：片段分割与删除的 C ABI（B1 模型层命令）

- **状态**：✅ 编码完成（2026-10-11）⚠️ 内核主体被并行会话 d31e6b8（CAM-035）卷入提交；两个缺陷修复 + C ABI 测试 + 文档仍待单独收口提交（修复不落，HEAD 的模型测试是红的）
- **批次**：RESEARCH-010 §5.2 **B1 模型层命令**（写集与 B0/B2/B3 不相交）
- **写集**：`engine/core/cq/model/chq_timeline.*`、`engine/core/cq/command/chq_command.*`、
  `engine/core/cq/session/chq_editor_session.*`、`engine/core/cq/cq_sdk.*`、
  `tests/unit/test_model_timeline.cpp`、`tests/unit/test_model_command.cpp`、`tests/unit/test_c_abi_edit.c`
- **依赖**：MODEL-002 ✅（无 RENDER-001 依赖 —— 分割/删除是纯模型结构操作）

## 范围

| 层 | 新增 | 说明 |
|---|---|---|
| 模型 | `ChqTimeline::SplitClip(clip_id, at, out_right_id)` | 左半保 id 收缩、右半新 id；at 严格内开区间；转场边界（左出/右入）置 kNone；算术全过才变更 |
| 模型 | `ChqTimeline::ReplaceClip(clip)` | 原位整体替换（id/轨不变）：duration>0、source_in≥0、同轨不重叠（排自身）、kind 匹配；start 可变后重排序 |
| 命令 | `ChqSplitClipCommand` | 结构类：Do 捕获左右快照；Undo = RemoveClip(右)+ReplaceClip(左前)；Redo = ReplaceClip(左后)+RestoreClip(右，原 id) |
| Session | `SubmitSplitClip / SubmitRemoveClip / SubmitRemoveTrack` | 与 SubmitMoveClip 同构（异步提交，校验在 session 线程） |
| C ABI | `cq_session_split_clip / remove_clip / remove_track` | remove 系此前内核已实现但未导出（RESEARCH-010 §4 缺口 2），本卡补齐导出 |

## 关键语义决策

1. **分割点两侧转场作废**：切线是媒体中段不是媒体边界，out（左）/in（右）置 kNone；
   transition_duration 不动（当前 setter 只产 kNone，非 kNone 引入时再补共享归属语义）。
2. **右半媒体引用联动**：source_in += Δ、source_duration −= Δ、duration = end − at
   （首版误写 duration = delta（左半时长），单测当场抓住 —— P119）。
3. **remove 走实体快照**：RemoveClip/RemoveTrack 命令沿用 MODEL-002 既有实现
   （单实体粒度快照），Undo 原位恢复原 id。

## 验证（本机实测，2026-10-11）

| 命令 | 结果 |
|---|---|
| `tools/build/build_core.sh --platform=apple` | ✅ 100%，-Werror 零告警 |
| `ctest -R "model_timeline\|model_command\|c_abi_edit\|editor_session\|c_abi_session\|^c_abi$"` | ✅ 6/6 |
| `ctest`（全量兜底） | ✅ **48/48**（Debug，134s） |

新增断言：模型级 11 项（SplitClip 边界/联动/邻居共存 + ReplaceClip 校验矩阵）、
命令级 12 项（split 往返含 redo 分支保全、LIFO 引用）、C ABI 级 26 项
（独立第二会话：split/trim_in/remove 全链 + undo 链 + 参数校验）。

## 剩余风险

- Swift 绑定未接（B1 出口标准止于 C ABI；绑定归 BIND/UIA 线，不在本写集）。
- 右缘 TrimClip 仍不收缩 source_duration（MODEL-002 既定语义，改动会碰既有测试口径，
  登记为 MODEL 线待决项，本卡不动）。
