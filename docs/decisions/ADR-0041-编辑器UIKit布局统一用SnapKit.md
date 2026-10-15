# ADR-0041：编辑器 UIKit 布局统一采用 SnapKit

- **状态**：已批准
- **日期**：2026-10-14
- **相关**：UIA-042 / RESEARCH-017（S11 预览选中红框）/ ADR-0024（编辑页 UIKit 混合）/ pitfalls P129 / P130

## 背景

UIA-041 做 U1 视觉保真时，编辑页预览区「选中片段红框」（`previewSelectionBorder`，U1 S11）在真机
上不可见。根因有两层：

1. **`NSAutoresizingMaskLayoutConstraint` 冲突**：该子视图忘记设
   `translatesAutoresizingMaskIntoConstraints = false`，系统自动生成
   `minX==0 / width==0 / height==0` 的 mask 约束，与手写的 center/比例约束互相打架，
   每次布局都报 `Unable to simultaneously satisfy constraints`。
2. **布局欠定**：原代码只给红框 `centerX/centerY + width == 0.5625*height` 的比例约束，
   **没有定尺约束**——比例再对，系统仍把它解成 0×0，红框实为不可见（U1 S11 等于假功能）。

同时，编辑器 UIKit 目录下 4 个视图（`EditorViewController` / `EditorTransportBarView` /
`EditorToolbarUIView` / `EditorTimelineUIView`）全用手写 `NSLayoutConstraint.activate([...])`
+ 手动关 mask，样板冗长且每处都可能漏关 mask 重踩同类坑。

结论：与其逐处打补丁，不如把编辑器 UIKit 布局**统一迁移到 SnapKit DSL**，从机制上根除
「忘关 mask」整类 bug，并修正 U1 S11 的欠定几何。

## 决策

1. **引入依赖（iOS 专属）**：`apps/apple/packages/ChuanqiCutEditor/ChuanqiCutEditor.podspec`
   增加 `s.ios.dependency 'SnapKit', '~> 5.7.0'`。macOS 端不引入（SnapKit 只被 `#if os(iOS)`
   的 UIKit 布局代码 import）。
2. **统一 DSL**：编辑器所有 `#if os(iOS)` UIKit 视图的约束改走 SnapKit
   —— `snp.makeConstraints`（首装）/ `snp.remakeConstraints`（可变几何/比例重建）。
3. **不再手写 `translatesAutoresizingMaskIntoConstraints = false`**：`snp.*Constraints`
   会自动置 false，消除漏关 mask 的整类 bug（见 P130）。
4. **比例约束用 remake 重建**：`multiplier` 不可变，画布比例变化（UIA-040）时整体
   `remakeConstraints`，不尝试改旧约束。
5. **版本钉死**：iOS / 两端 `Podfile.lock` 钉 `5.7.1`（MIT，ARCH-002 §5 ALLOW 级）；
   `Package.swift` 不引 SnapKit（它只是 macOS `swift test` 宿主，iOS 文件被整文件跳过，P129）。

## 备选方案

| 方案 | 否决理由 |
|---|---|
| 继续手写 `NSLayoutConstraint.activate` + 手动关 mask | 已踩坑（P130）；样板冗长、易漏关 mask，每处都是复发点 |
| 自研轻量布局封装 | 重复造轮子，SnapKit 已覆盖需求且无额外维护成本 |
| 回退到纯 SwiftUI 编辑器布局 | 编辑页 UIKit 路径已由 ADR-0024 拍板（每帧驱动不经 SwiftUI），不回退 |

## 后果

**正面**
- 根除「忘关 mask → `NSAutoresizingMaskLayoutConstraint` 冲突」整类 bug（P130·a）。
- DSL 可读性/可维护性高于原生 `NSLayoutConstraint.activate` 样板。
- U1 S11 红框几何修正为 `center + 高满容器 + 宽=aspect×高`，画布比例变化时整体重建。

**负面 / 成本**
- 编辑器 Pod 多一个 iOS 第三方依赖（SnapKit，MIT，体量小）。
- podspec 变动后需确保两端 `pod install` 同步（iOS 已落地 5.7.1；mac 因依赖 ios 专属不拉入）。

**缓解**
- 依赖严格 iOS 作用域，macOS 构建/测试完全不感知 SnapKit。
- 任何 UIKit 改动的最小自证 = 两端壳构建（P129），本批已跑通。

## 反转条件

若 Apple 弃用 `NSLayoutConstraint` 体系，或编辑页整体迁移纯 SwiftUI（撤销 ADR-0024），则重评本决策。

## 落地任务

`TASK-UIA-042`
