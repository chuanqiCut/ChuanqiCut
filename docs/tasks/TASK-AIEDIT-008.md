# TASK-AIEDIT-008：智能成片向导 UI（首页入口 + 三步向导）

```yaml
id:          AIEDIT-008
layer:       UI
goal:        首页新增「智能成片」入口卡，向导三步（选素材→分析→结果预览）接通 ABI，结果页双出口（导出[置灰]/进编辑器）
input:       [AIEDIT-007 ABI, SPEC §9, UIA-013（AlbumPickerScreen 复用）, .ai/modules/ui-apple.md]
output:      [HomeView 入口, SmartCut 向导三屏, ViewModel, 单测, macOS 适配]
write_set:   apps/apple/ios/iOSApp/HomeView.swift(高冲突——本批次独占)、
             apps/apple/packages/SharedUI/Sources/SharedUI/SmartCut/Wizard/*(新)、
             apps/apple/packages/SharedUI/Tests/SharedUITests/SmartCutWizardTests.swift(新)
read_set:    apps/apple/packages/SharedUI/Sources/SharedUI/**, bindings/swift/*, docs/specs/UIA-013
deps:        [AIEDIT-007]
acceptance:
  - 首页出现「智能成片」入口卡；点击进入向导；返回不泄漏 observer（析构断言）
  - 选素材复用 AlbumPickerScreen 多选模式，交付 URL 列表汇入既有 importMedia 链（asset_id 就绪后进分析）
  - 分析页逐素材进度可见、可取消；取消后无残留任务（取消回调断言）
  - 结果页：预览自动播放（复用 cq_player 模式）+ 结构时间条 + 每段 reason 抽屉 + 双出口；「导出」按钮置灰且标注（EXPORT-001 未落地）；「进编辑器精修」push 现有 EditorView 且时间线/素材原样带过去（快照一致性断言）
  - 纯逻辑（向导状态机/进度聚合）单测全绿；SwiftUI 手势冒烟
  - macOS `xcodebuild build` 通过；iOS legacy 链编译通过；write_set 外零改动
verification:
  - swift test --disable-sandbox（SharedUI）
  - xcodebuild build（macOS App）
  - 真机端到端走查（随 UIA-011 真机恢复决策一并执行，不阻塞门禁）
risk:        HomeView.swift 高冲突（Route enum 共享）→ 本批次独占；半屏 detents 沿用 UIA-013 v1.1 既定手法
parallel:    false（批次 5）
```

## 背景

SPEC §9。差异化卖点的承载面：结构时间条 + reason 抽屉 = "决策透明"（RESEARCH-003 §4.4，学 Opus）；双出口 = 学剪映闭环。

## 实现要点

1. 目录组织照 MediaPicker：`SmartCut/Wizard/`（Home+Steps）+ `SmartCut/Result/`；纯逻辑抽可测类型（SmartCutFlowState 等）。
2. 结果页与编辑器共享同一 CQSession——"进编辑器"只是 push，不是重建会话（素材与 plan 批次原样在撤销栈）。
3. 分析页文案明示"特征在本机提取，仅上传统计摘要，不上传视频"（隐私卖点 UI 化）。
4. 开放问题 §12.6（macOS 入口形态）在本任务内定：保留入口 + fileImporter 双路。

## 回写

.ai/modules/ui-apple.md 增补 SmartCut 域；HANDOFF 记录状态机形状。
