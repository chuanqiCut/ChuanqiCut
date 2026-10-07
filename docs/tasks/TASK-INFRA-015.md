# TASK-INFRA-015：ChuanqiCutPlayer Pod 迁移（Player 全域 + 测试）

```yaml
id:          TASK-INFRA-015
layer:       基建
goal:        ADR-0031 阶段 1：SharedUI/Player（14 文件）+ 4 个测试文件迁入独立 Pod，SharedUI 同步删源，门禁数字不掉用例
input:       [ADR-0031, PLAN-壳工程与功能Pod, ADR-0022（AVPlayer 过渡）, HANDOFF-006 播放器域]
output:      [packages/ChuanqiCutPlayer/{podspec,Package.swift,Sources,Tests}, SharedUI 删 Player 源, 双壳 import 更新]
write_set:   apps/apple/packages/ChuanqiCutPlayer/**、apps/apple/packages/SharedUI/Sources/SharedUI/Player/**（迁出）、SharedUI/Tests/SharedUITests/Player{Tests,SubtitleTests,QueueTests,TestSupport}.swift（迁出）、SharedUI/Sources/SharedUI/Editor/MediaSheet.swift（解耦引用）、apps/apple/ios/iOSApp/{ChuanqiCutApp,HomeView}.swift、apps/apple/mac/MacApp/ChuanqiCutMacApp.swift
read_set:    docs/handoff/HANDOFF-006-播放器MVP会话交接.md
deps:        [TASK-INFRA-013]
acceptance:
  - 迁移前后 Player 域测试用例数一致（不掉用例）
  - SharedUI 包内 grep 零 Player 符号引用（MediaSheet 走注入器）
  - 双壳构建过（iOS 模拟器 + macOS）
verification:
  - (cd apps/apple/packages/ChuanqiCutPlayer && swift test --disable-sandbox)
  - (cd apps/apple/packages/SharedUI && swift test --disable-sandbox)
  - grep -rn "PlayerScreen\|PlayerController\|PlayerLauncherScreen\|PlayerMiniBar" apps/apple/packages/SharedUI/Sources | grep -v PlayerPreviewInjector  # 应为空
risk:    swift test macOS 分支与 iOS 分支行为差（#if os）；迁移前数字在 SharedUI 128 用例中，迁移后两包相加对齐
parallel:    false   # 同域业务任务与迁移不并行（PLAN §2 批次纪律）
```

## 背景
Player 是最成熟、测试覆盖最全的域（UIA-015~027），作为 Pod 拆分的**样板阶段**：验证
「pod-依赖-pod + 模块改名 + 测试随迁 + 壳层 import 更新」全链路，为 Import/Assets/Camera/
Editor 各阶段立范式。

## 实现要点
- Player 域零跨域引用（已核：不引 Theme/Editor/MediaPicker/Camera/Timeline，不 import
  ChuanqiCut）→ 新包无外部依赖，最简可行。
- MediaSheet 解耦：`PlayerPreviewInjector.makePlayerPreview` 由壳层注入
  `PlayerScreen(url:)/PlayerScreen(urls:)` 工厂；SharedUI 模块从此零 Player 符号。
- PlayerEngine 是 internal 协议、AVPlayerEngine internal 实现（无 public 前缀）——
  迁到新模块后对壳层不可见是否破坏装配？MacApp 只用 public 的 PlayerController/
  PlayerLauncherScreen/PlayerMiniBar/PlayerScreen；MediaSheet 只用 PlayerScreen（注入）。
  迁移时核 public 面，不足则最小化加 public（记进模块册）。

## 验收
双包 swift test 用例数对齐迁移前；双壳构建 SUCCEEDED；grep 无悬空引用。

## 回写
- `.ai/modules/ui-apple.md` 模块册；BACKLOG §14 两行 ✅；baselines 不涉及（无性能数字）。
