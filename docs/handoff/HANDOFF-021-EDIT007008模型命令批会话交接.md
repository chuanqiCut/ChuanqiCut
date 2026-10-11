# HANDOFF-021：EDIT-007/008 模型层命令批会话交接（2026-10-11）

> 接手前提：读 `.ai/modules/model.md` 模块册 + RESEARCH-010 §5.2 批次表。
> 本轮 = 编辑线（B1）首个编码批；相机线（CAM-033）仍停在池 [15] 待真机，与本批无写集交集。

## 本轮做了什么（对着 commit 核，未提交前对着工作区核）

1. **EDIT-007**：`ChqTimeline::SplitClip` + `ChqTimeline::ReplaceClip`（模型层）、
   `ChqSplitClipCommand`（命令层）、`SubmitSplitClip/RemoveClip/RemoveTrack`（Session）、
   `cq_session_split_clip / remove_clip / remove_track`（C ABI，remove 系补导出）。
2. **EDIT-008**：`ChqTrimClipInCommand`（左缘裁剪，四字段联动右缘不动）、
   `SubmitTrimClipIn`、`cq_session_trim_clip_in`；cq_sdk.h 旧「左裁剪本期不提供」注记作废改写。
3. 测试：test_model_timeline / test_model_command / test_c_abi_edit 三处扩展
   （C ABI 段用独立第二会话现场，track id 空间独立必须重查——别抄会话一的句柄）。
4. 台账：TASK-EDIT-007/008、backlog §4.3 新号两行、model.md 模块册、pitfalls P119。

## ⚠️ 提交事故（接手者先读）

并行相机会话于 2026-10-11 23:18 提交 `d31e6b8`（CAM-035）时用全量 add 把本批
**内核主体卷入**（cq_sdk.* / chq_timeline.* / chq_command.* / chq_editor_session.* +
test_model_command / test_model_timeline）。因此：
1. **HEAD 上的内核 = 带两个缺陷的版本**（SplitClip 右半时长误用 delta、TrimClipIn
   未收缩 source_duration）——修复在工作区，**必须先收口提交修复**，否则干净检出
   HEAD 后 model_timeline / model_command / c_abi_edit 三测红（P119 两个根因）。
2. 收口提交清单：`engine/core/cq/command/chq_command.cpp`、
   `engine/core/cq/model/chq_timeline.cpp`、`tests/unit/test_c_abi_edit.c`、
   `docs/tasks/TASK-BACKLOG.md`、`docs/tasks/TASK-EDIT-007/008.md`、
   `docs/handoff/HANDOFF-021*`、`.ai/memory/pitfalls.md`、`.ai/modules/model.md`。
   **不得**捎带 `apps/apple/packages/ChuanqiCutCamera/**`（那是并行线的工作区残留）。
3. 防复发：全量 add 扫提交是 P84 明令禁止的姿势，本轮再次实锤（见 P120 待登记）。

## 验证数字（2026-10-11 本机实测）

- `build_core.sh --platform=apple`：100%，-Werror 零告警
- 窄检 `ctest -R "model_timeline|model_command|c_abi_edit|editor_session|c_abi_session|^c_abi$"`：6/6
- 全量 `ctest`：**48/48**（Debug，134s）

## 下一步（按 RESEARCH-010 §5.2 拓扑）

1. **B1 收口**：Swift 绑定接四个新 ABI（BIND/UIA 线，独立卡）→ 编辑页接「分割/删除」手势
   （UIA 线）。
2. **B0 渲染地基（RENDER-001）**：仍卡在范围拍板（RESEARCH-014 §5/§6 建议已给出：
   装配器三图同源 + 时钟源接口 + Push/Pull 分区）——**传哲拍板后**走 cq-task-planning；
   开工前置 = ADR 反转 `engine/core/CMakeLists.txt` 的「本期不做 RenderGraph」注记 + shader spike。
3. **B3 持久化（PROJ-001）**：写集独立可随时插；`RestoreTrack/RestoreClip` 就是载入入口，
   本轮的 ReplaceClip 也是序列化载入可复用的基座。

## 坑（详见 pitfalls P119）

- 分割/裁剪类联动字段：`delta` 一词多义导致右半时长首版写错 —— 时长变量按语义命名 +
  恒等式断言（右缘不动 / 总时长不变）兜底。
- `ReplaceClip` 现在校验 `source_in ≥ 0`：变速（retime）落地后此约束要按 TimeMap 重审。
