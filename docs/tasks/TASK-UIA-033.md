# TASK-UIA-033：Theme 令牌扩展（增量；全量清扫另立批次）

> **编号让位说明**：本卡原取号 **UIA-016**，与远端播放器线「系统级播控补完」撞号（UIA-015/016 撞号事件）。
> 2026-10-07 传哲裁定**编辑器线让位**，本卡改号 **UIA-033**；播放器线保留 UIA-016。

> **状态：✅ 已落地（2026-10-05，本集成机）**——门禁数字与走查证据见 `docs/reviews/REVIEW-2026-10-05-UIA032-编辑页走查.md`、`.workbuddy/memory/2026-10-05.md`。

```yaml
id:          TASK-UIA-033
layer:       UI
goal:        为编辑页重构补齐所需语义常量（播放条/工具栏底色、accent、间距圆角阶梯），不做全仓裸 RGB 清扫
input:       [docs/specs/UIA-032-编辑页重构.md §4.2, RESEARCH-004 §6.0]
output:      [Theme.swift 增量常量]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Common/Theme.swift
read_set:    apps/apple/packages/SharedUI/Sources/SharedUI/**（只读引用点）
deps:        []
acceptance:
  - 新常量编译通过；既有引用点零回归（两平台编译）
  - Editor 域新增视图文件中不出现裸 RGB（grep 检查）
verification:
  - grep -rn 'Color(red:' apps/apple/packages/SharedUI/Sources/SharedUI/Editor/ | grep -v Theme || echo clean
  - 双平台 xcodebuild（同 TASK-UIA-020）
risk:        与其他任务同时改 Theme.swift 冲突 → 本卡写集独占 Theme.swift，UIA-032 只读消费
parallel:    true
```

## 背景
RESEARCH-004 §6.0：Theme 2.0 全量令牌清扫应"一次改净"；本卡只交付 UIA-032 所需的**增量**（避免一次大扫除阻塞用户可见修复），全量清扫登记 BACKLOG 待批。

## 实现要点
新增：`transportBackground`、`toolbarBackground`、`accent`（与 timelineClip 同族蓝）、`accentText`、间距阶梯 `Space`（4/8/12/16/24/32）、圆角阶梯 `Radius`（8/12/16/capsule）。既有常量一律不动。

## 验收
acceptance 两条。

## 回写
Theme 段落增补进 `.ai/modules/ui-apple.md`（若形状变化）。
