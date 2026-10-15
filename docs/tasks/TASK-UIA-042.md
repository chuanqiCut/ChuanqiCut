# TASK-UIA-042：编辑器 UIKit 布局迁移 SnapKit + 修复预览红框约束冲突

> 模板。缺任一项不得进入编码。

```yaml
id:          TASK-UIA-042
layer:       UI
goal:        编辑器 UIKit 布局统一迁移 SnapKit，修复预览选中红框（U1 S11）约束冲突与 0×0 不可见
input:       [RESEARCH-017（S11 预览选中红框）, ADR-0024, ADR-0041, 用户原始 Auto Layout 冲突日志]
output:      [ChuanqiCutEditor.podspec 增依赖, 4 个 UIKit 文件 SnapKit 化, 双壳 BUILD SUCCEEDED]
write_set:   apps/apple/packages/ChuanqiCutEditor/** + ChuanqiCutEditor.podspec
read_set:    apps/apple/{ios,mac}/Podfile, Podfile.lock
deps:        [UIA-041]
acceptance:
  - iOS 壳构建 BUILD SUCCEEDED（编译 UIKit 改动）
  - macOS 壳构建 BUILD SUCCEEDED（podspec ios 专属依赖不泄漏）
  - apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/ 下零 NSLayoutConstraint.activate、零手写 translatesAutoresizingMaskIntoConstraints
verification:
  - cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build
  - cd apps/apple/mac && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build
  - grep -rnE 'NSLayoutConstraint|translatesAutoresizingMaskIntoConstraints' apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit
risk:        比例约束 multiplier 不可变（用 remakeConstraints 重建）；SnapKit 仅 iOS 引入，mac 不得 import（podspec 已 ios 作用域限定）
parallel:    false
```

## 背景

用户贴出运行时 `Unable to simultaneously satisfy constraints` 日志（涉及 `previewSelectionBorder` 的
center/比例约束与 `NSAutoresizingMaskLayoutConstraint` 冲突），要求：① 分析根因；② 布局改用
SnapKit 重写并优化；③ 项目无 SnapKit 则「在 pod 加一下」。根因见 ADR-0041：红框既漏关 mask、
又无定尺约束 → 既冲突又可解为 0×0 不可见（U1 S11 假功能）。本卡把编辑器 UIKit 布局整体迁移到
SnapKit，从机制上根除该类问题。

## 实现要点

- `ChuanqiCutEditor.podspec`：`s.ios.dependency 'SnapKit', '~> 5.7.0'`（iOS 专属，MIT，钉 5.7.1）。
- `EditorViewController.swift`：`import SnapKit`；`setupStack`/`setupPreview` 改 DSL；
  `applyCanvasAspect()` 用 `snp.remakeConstraints`——MTK：`top/bottom + centerX + width=height×aspect`；
  红框：`center + height=容器 + width=height×aspect`（修正 0×0）。
- `EditorTransportBarView` / `EditorToolbarUIView` / `EditorTimelineUIView`：原生
  `NSLayoutConstraint.activate` + 手动 `translatesAutoresizingMaskIntoConstraints=false` 全部替换为 SnapKit。
- iOS 端已 `bundle exec pod install`（SnapKit 5.7.1 落地）；mac 端 mac 专属依赖不拉入、pod install 通过。

## 验收

逐条对应 acceptance：
- iOS 壳 `BUILD SUCCEEDED` ✅（2026-10-14 实测）
- macOS 壳 `BUILD SUCCEEDED` ✅（2026-10-14 实测；ios 专属依赖未泄漏）
- UIKit/ 目录 `grep` 仅剩注释命中 ✅（2026-10-14 实测）
- ⚠️ `swift test` **不跑**（本机 macOS SPM 跳过 `#if os(iOS)`，P129 伪证，不以之替代壳构建）
- ⚠️ 全量 `run_gate.sh` 未申请

## 回写

- 架构事实 / 接口变更 → `docs/decisions/ADR-0041`（新）
- 故障与排障 → `.ai/memory/pitfalls.md` **P130**（两条：忘关 mask 冲突 / 布局欠定 0×0）
- 模块册 → `.ai/modules/ui-apple.md` 追加 UIA-042 落地
- 依赖策略 → `docs/COCOAPODS.md` 追加功能 Pod 第三方依赖说明
- 交付节奏 → `docs/reviews/QUESTIONNAIRE-UIA-042-预览选中红框与布局保真.md`（**未回收，不得标记完成**）
- 台账 → `docs/reports/LEDGER-W42.md` 补记七
