# HANDOFF-023：UIA-042 编辑器 UIKit 布局迁移 SnapKit + 预览红框修复

> 会话交接（2026-10-14，WorkBuddy 集成机 → 后续接手方）
> 写集仅 `apps/apple/packages/ChuanqiCutEditor/**` + `ChuanqiCutEditor.podspec`，与 B0/B5.5 等内核批次**写集不相交**。

## 1. 本批做了什么

- **根因（用户原始日志 `Unable to simultaneously satisfy constraints`）**：
  `previewSelectionBorder`（U1 S11 预览选中红框）① 漏设
  `translatesAutoresizingMaskIntoConstraints=false` → 系统 mask 约束与手写 center/比例约束冲突；
  ② 只给 center+比例约束、无定尺约束 → 布局欠定解成 0×0 不可见（U1 S11 假功能）。
- **决策**：编辑器 UIKit 布局统一迁移 SnapKit（ADR-0041，已批准）。
- **改动**：
  - `ChuanqiCutEditor.podspec`：`s.ios.dependency 'SnapKit', '~> 5.7.0'`（iOS 专属，钉 5.7.1）。
  - `EditorViewController.swift` / `EditorTransportBarView.swift` / `EditorToolbarUIView.swift` /
    `EditorTimelineUIView.swift`：原生 `NSLayoutConstraint.activate` + 手动关 mask 全部改 SnapKit DSL；
    红框几何固定为 `center + 高满容器 + 宽=aspect×高`，画布比变化时 `snp.remakeConstraints` 整体重建。
  - iOS 端 `bundle exec pod install` 已落地 SnapKit 5.7.1；mac 端 mac 专属依赖不拉入、pod install 通过。

## 2. 验证（本机 macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / Intel x86_64，2026-10-14 实测）

| 验证项 | 结果 |
|---|---|
| iOS 壳构建 `-scheme ChuanqiCutApp -destination generic/platform=iOS` | **BUILD SUCCEEDED** |
| macOS 壳构建 `-scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES` | **BUILD SUCCEEDED** |
| `grep` UIKit/ 下 `NSLayoutConstraint` / `translatesAutoresizingMaskIntoConstraints` | 仅注释命中（0 代码） |
| `swift test`（Editor 包） | **未跑**：macOS SPM 跳过 `#if os(iOS)`（P129），不以之替代壳构建 |
| 全量 `run_gate.sh` | **未跑**（按约定需先询问） |

## 3. 剩余 / 待办（均已在卡面或池里挂号，不丢）

- **真机问卷未回收**：`docs/reviews/QUESTIONNAIRE-UIA-042-预览选中红框与布局保真.md` 已生成，
  **未回收前不得在 TASK-UIA-042 / 本交接标记完成**（ADR-0034）。
- SwiftUI 侧 `EditorTimelineView` 的同类布局未动（本批 Scope 仅 UIKit 路径）。
- 红框视觉尺寸/线宽仍 [E]，以真机走查校准为准。

## 4. 指针

- ADR：`docs/decisions/ADR-0041-编辑器UIKit布局统一用SnapKit.md`
- 任务卡：`docs/tasks/TASK-UIA-042.md`
- 问卷：`docs/reviews/QUESTIONNAIRE-UIA-042-预览选中红框与布局保真.md`
- 坑册：`.ai/memory/pitfalls.md` **P130**（忘关 mask 冲突 / 布局欠定 0×0）
- 台账：`docs/reports/LEDGER-W42.md` 补记七
- 依赖策略：`docs/COCOAPODS.md` §7
- 模块册：`.ai/modules/ui-apple.md` UIA-042 落地段
