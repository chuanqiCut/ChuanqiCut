# TASK-UIA-045：轨道区接入后的四项回归修复（返回键 / 播放中操作 / 同步 seek / iPad 统一）

```yaml
id:          TASK-UIA-045
layer:       UI
goal:        UIA-044 真机跑通后传哲提出的 5 项中的 4 项（第 1 项为排查，见下）：
             ① DEBUG 调试页入口排查；② 选中片段后底栏「返回」无反应；
             ③ 播放中操作轨道区应暂停；④ 拖轨道同步 seek；⑤ iPad 与 iPhone 统一（横屏也用 TimelineKit）
input:       [TASK-UIA-044, ADR-0042, ADR-0034, P135, P136, 用户 2026-10-15 追加要求]
output:      [改 AppEntry.swift, 改 TrackInteraction.swift, 改 UIKit/EditorViewController.swift, 改 EditorLayout.swift,
             pitfalls +P135 +P136, QUESTIONNAIRE-UIA-045]
write_set:   apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/{AppEntry,TrackInteraction,EditorLayout}.swift、
             .../UIKit/EditorViewController.swift
read_set:    /Users/zhuning/Documents/ChatGPT/zui/Sources/TimelineKit/**（只读）
deps:        [UIA-044, UIA-040, UIA-041]
blocked_by:  [UIA-044 问卷未回收 —— 本批为同域回归修复，与 UIA-044 同批交付]
merge_note:  与 UIA-044 同域（同一批改动），不单独发号给他人
acceptance:
  - iOS 壳构建 BUILD SUCCEEDED（generic/platform=iOS）
  - macOS 壳构建 BUILD SUCCEEDED（x86_64 ONLY_ACTIVE_ARCH=YES）
  - 底栏 clipSelected 条「返回」= 退出选中 → 一级工具条（不再是「重设成自己」）
  - 播放中拖轨道 = 先暂停再定位（不再被播放循环覆盖）
  - 播放中提交编辑 Intent（move/trim/跨轨）= 先暂停
  - iOS 不分尺寸类：iPhone 与 iPad 同一 UIKit 容器，轨道区只有 TimelineKit 一条实现
verification:
  - cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build
  - cd apps/apple/mac && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build
  - 真机问卷 QUESTIONNAIRE-UIA-045（传哲实测）
risk:        iPad 取消 regular 分支后不再有常驻右栏 MediaLibraryPanel（素材库改走「媒体」抽屉，与 iPhone 同路径）——
             传哲若要求保留右栏，需先把 EditorViewController 的轨道接线抽成共享宿主对象，否则又变成两套轨道区（ADR-0014 同款坑）；
             播放中暂停属于行为变更，需真机确认「拖一下就停」的手感是否符合预期
parallel:    false
```

## ① DEBUG 调试页入口排查（结论：入口在，是被自动路由绕过了）

- 证据（不是推测）：`Debug-iphoneos/ChuanqiCutApp.app/ChuanqiCutApp` 二进制里
  `grep -a "TimelineKit 调试"` / `"TimelineKit 集成预览"` **均命中 1 次** → 首页卡片与调试页
  都已编进 Debug 包；`ChuanqiCut.xcodeproj` 工程级 Debug 有 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`
  → `#if DEBUG` 生效；Pods 工程里 `TimelineKitIntegrationPreview.swift` 有 4 处引用 → 已编入
  `ChuanqiCutEditor-TimelineKitTrack`。
- 真因：上一轮真机是用 `CQ_AUTO_ROUTE=editor` 启动的 —— 该分支**直进 EditorScreen**，
  根本不经过 `HomeView`，所以「TimelineKit 调试」卡片不可能出现。
- 本轮已改为**不带** `CQ_AUTO_ROUTE` 启动 → 落在首页，卡片可见。
- 另一条直达入口：`CQ_AUTO_ROUTE=timelinekit`（`ChuanqiCutApp.swift` 已支持）。

## ② 底栏「返回」无反应（P135）

- 根因不在按钮、不在手势：是 `closePanel()` 把**目标态由业务状态推导**。
  详见 pitfalls P135。
- 修法：`closePanel()` 改为按**当前层**逐层退出（`switch toolbarMode`）。

## ③④ 播放中操作轨道区 + 同步 seek（P136）

- 新增 `EditorViewModel.pausePlayback()`（幂等），`togglePlayback()` 的暂停分支复用它 ——
  两处同一条路径，不复制实现。
- `onScrub`：去掉 `guard !isPlaying`，改为「先 `pausePlayback()` 再 `setPlayhead`」。
- `apply(intents:)`：含 `.commitEdit` 时先暂停；`.selectClip` 不暂停（选中是 UI 本地态，
  播放中点片段不打断播放）。判定用新增的 `TrackIntent.isEditing`。

## ⑤ iPad 与 iPhone 统一

- `EditorLayoutContainer.iosLayout` 取消 `horizontalSizeClass` 分支，一律 `compact()`
  （UIKit 三件套容器）。原 `regular` 分支走 macOS 同构布局 + SwiftUI 自绘轨道区
  → iOS 侧两套轨道区实现（TimelineKit / 自绘），两套交互语义两套 bug（ADR-0014 同款坑）。
- macOS 不受影响（`macLayout` 一字未动，仍是 SwiftUI 轨道区 —— 传哲说「macOS 可以按这个去优化」，另开）。

## 补：尺寸 / 性能 / 轨道头（2026-10-15 传哲追加，同批）

### 尺寸（传哲：「轨道区变大，至少跟剪映对齐；底栏固定大小就行，不要太大」）

| 项 | 原 | 现 | 依据 |
|---|---|---|---|
| `EditorChrome.timelineHeight` | 140 | **220** | 标尺 24 + 主轨 68 + 副轨 52 ≈ 一屏三条轨；**[E]** 对标 App 截图判读（P128：我没实际看到图） |
| `TimelineKitAdapter.primaryRowHeight` | 56 | **68** | 随轨道区一起放大 |
| `TimelineKitAdapter.secondaryRowHeight` | 48 | **52** | 同上 |
| `EditorChrome.toolbarHeight` | 84 | **64** | 传哲：「固定大小就行，不要太大」；定值，不自适应 |
| `toolbarIconPointSize / IconLabelSpacing` | 22 / 6 | **20 / 4** | 元素总高 34，在 64 里居中不挤 |

预览区余量（iPhone 17 Pro，852pt）：852 − 顶安全 59 − 导航 44 − 传输 44 − 轨道 220 − 底栏 64 − 底安全 34 ≈ **387pt**（9:16 画布 → 宽 218pt，两侧留黑，与对标 App 同）。

### 性能（传哲：「集成进去之后有点卡」）—— 有实测，不是估算

新增 DEBUG stderr 通道 `[tk:perf]`（`EditorTimelineKitView`，每 2s 一行），真机实测
（iPhone 17 Pro / iOS 26.6.1 / Debug / `CQ_AUTO_PLAY=1` + `CQ_DEMO_VIDEO`，1 条主视频轨、5s 素材）：

| 阶段 | 推进次数 | avg | max | 主线程占用 |
|---|---|---|---|---|
| 优化前（每帧推进） | **84 次/s** | 2.31ms | 3.47ms | **≈19%** |
| 优化后（播放中 30Hz） | **26 次/s** | 3.81ms | 5.27ms | **≈10%** |

- 根因：`TimelineView.setCurrentTime` → `scrollToTime` → `scrollViewDidScroll` →
  **`layoutTrackHeaders + layoutVisibleContent + positionPlayhead` 三套布局全跑**
  （旧自绘版每帧只画一条线，成本差一个量级）。
- 改法：`EditorViewController.updatePlayheadUI` 里**仅播放中**把轨道播放头节流到 30Hz
  （`trackPlayheadInterval = 1/30`）；暂停 / seek / 播放结束一律立即推终值，不会停在旧值。
  时间码与预览画面仍是满帧。
- `rebuild` 单次 1.6ms，全会话仅 1 次（无反复重建）。
- ⚠️ 样本极小（1 条轨、1 个 5s 素材），**不得作产品阈值**；avg 在两次运行间波动
  2.3→3.8ms，属噪声量级，不作结论。

### 轨道头（传哲：「轨道区左边显示的是啥；没用的话可以去掉」）

- 那一段是 TimelineKit 的 **`TimelineTrackHeaderView`**：类型图标 + 轨道名 + **L（锁定）**
  + **M（静音）** + 长按排序手势（默认 `headerWidth = 78`）。**不是调试用的**，是组件的正式能力。
- 但在我们的接入里它是**一排假开关**：锁定 / 静音 / 轨道排序内核**全无写 ABI**（池 [19]）
  → 点了组件自我变更 → 走 `handle(command:)` 的 default 分支 → **整条时间线按内核重灌**
  （既没用，又是卡顿来源之一）。剪映的轨道区左侧也没有常驻轨道头。
- 处理：给组件加 `TimelineStyle.showsTrackHeader`（默认 `true`，向后兼容），
  `false` 时 `headerWidth` 按 0 落、轨道头一条不创建、`headerScrollView` 隐藏；
  正式接入传 `showsTrackHeader: false`。
  ⚠️ 本批**动了组件源码**（`/Users/zhuning/Documents/ChatGPT/zui`，3 处：
  `TimelineStyle` +1 字段 / `TimelineView.layoutTrackHeaders` 包一层 `if` /
  `applyStyle` 隐藏 headerScrollView）。调试预览页用默认值 → **仍显示轨道头**（便于对照）。

## 补二：DEBUG 浮层不显示 + 轨道区滑动无惯性（2026-10-15 传哲追加，同批）

### ① `DebugOverlayView` 不在编辑页展示（P138，已修，真机已验证）

- 浮层挂在 `EditorView` 的 **`preview:` 槽位**；iOS 走的是 `compact()` 槽位（UIKit 容器）→
  `preview/transport/timeline/toolbar` 四个槽位在 iOS 上**一个都不渲染**。
  iPhone 从来没显示过；2026-10-15 把 iPad 统一到 compact 之后 iPad 也没了。
- 修法：浮层改挂 **`EditorViewController`**（`UIHostingController` 承载 `DebugOverlayView`），
  只钉 top/leading + 宽度 ≤320，**高度交给 SwiftUI intrinsic**（钉四边会压成 0，P130·b 同款）。
- 开关：`CQ_DEBUG_OVERLAY=1`（`DebugCenter.isVisible`）。⚠️ iOS UIKit 传输条**还没有**天线按钮，
  即 macOS 侧那个开关入口在 iOS 上没有对应 —— 本批未加（传输条已挤），登记为待办。
- 真机验证（2026-10-15，iPhone 17 Pro / iOS 26.6.1 / Debug 包）：`CQ_DEBUG_OVERLAY=1` +
  `CQ_AUTO_ROUTE=editor` 启动，stderr 命中 `[dbg] overlay mounted intrinsic=(296.0, 104.0)`，
  浮层已挂载、无崩溃（DebugCrashDumper 已装、无 SIGSEGV）→ **P138 闭环**。视觉外观由传哲在设备上看。

### ② 轨道区滑动没有惯性（P139，已修，需真机手感确认）

- 反馈环：用户滑 → 组件 `scrollViewDidScroll` → `store.setCurrentTime(userScrub)` →
  宿主 `onScrub` → `VM.setPlayhead` → `$playhead` → `updatePlayhead` →
  `kitView.setCurrentTime` → 组件 `scrollToTime` → **`setContentOffset`** → **惯性动画被取消**。
  调试页不回推（只 `describe(event)`）→ 调试页有惯性，正式接入没有 —— 差异点就是线索。
- 修法：`EditorTimelineKitView.isUserScrubbing`，scrub 期间（含减速）**不回推**；
  由 `.timeChanged(final: true)` / `.timeScrollEnded` 解除，并配**独立超时上界 0.5s**
  （结束事件没来也不能把播放跟随永久吞掉）。结束时用终值对齐一次（组件同值守卫会 return）。
- 惯性**无法脚本化验证**（devicectl 无模拟手势子命令）→ 已为传哲在设备前台以
  `CQ_DEBUG_OVERLAY=1` + `CQ_AUTO_ROUTE=editor` 启动，待真机手感确认（拖动后松手有无减速惯性、
  松手后播放跟随是否对齐到终值）。
