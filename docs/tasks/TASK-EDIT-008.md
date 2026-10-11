# TASK-EDIT-008：左缘裁剪 trim-clip-in 的 C ABI（B1 模型层命令）

- **状态**：✅ 编码完成（2026-10-11）⚠️ 同 EDIT-007：主体被 d31e6b8 卷入，修复与测试待收口提交
- **批次**：RESEARCH-010 §5.2 **B1 模型层命令**
- **依赖**：EDIT-007 引入的 `ChqTimeline::ReplaceClip`（同批落地）

## 范围

| 层 | 新增 | 说明 |
|---|---|---|
| 命令 | `ChqTrimClipInCommand(clip_id, new_start)` | 右缘（end = start + duration）不动；start / source_in / duration / source_duration 四字段联动推导；存单个实体前后快照（三增量耦合，分开存会留半更新窗口） |
| Session | `SubmitTrimClipIn` | 异步提交，校验在 session 线程 |
| C ABI | `cq_session_trim_clip_in(session, clip_id, start_value, start_timescale)` | 调用方只给新起点，媒体侧推导在内核 |

## 关键语义决策

1. **cq_sdk.h 旧注记作废**：原「左边缘裁剪本期不提供」（cq_sdk.h:172-174）已被
   RESEARCH-010 §5.2 B1 范围取代，注释同步改写。
2. **媒体窗口同步收缩**：source_duration −= Δ（与 SplitClip 同纪律）；右缘 TrimClip
   的「不动 source 系」是 MODEL-002 既有语义，本卡不改（口径差异已登记 EDIT-007 剩余风险）。
3. **边界即校验**：source_in < 0（拖过素材入点）与 duration ≤ 0（越过右缘）都在
   ReplaceClip 内拒绝，命令失败不入栈、不改模型、不清 redo。

## 验证（本机实测，2026-10-11）

- 模型级：`TestReplaceClip`（替换即左缘裁剪形态 + 校验矩阵 6 项）
- 命令级：`TestTrimClipInCommand`（往返 + 指纹回等 + 两个失败语义）
- C ABI 级：`test_c_abi_edit.c` EDIT-008 段（三字段联动 / 右缘不动 / 越界拒绝 / timescale=0 同步 7000）
- 汇总：构建 -Werror 零告警；窄检 6/6；全量 **48/48**（同 EDIT-007 台账）

## 剩余风险

- 变速（retime）引入后「duration ≠ source_duration」将成常态，届时 ReplaceClip 的
  source_in ≥ 0 校验与 source_duration 推导要按 TimeMap 重写（EDIT-001/002 相邻域）。
