# RESEARCH-004：拍摄与编辑 UI 视觉升级调研（iOS / macOS）

> 日期：2026-10-04
> 调研时点：2026-10-04，来源为公开网络资料 + 本仓代码现状（文末列来源）
> **数字纪律**：本文所有第三方数字均为公开资料转述或估算 **[E]**，未实测，不得作为验收阈值。
> 上游需求：用户命题「当前拍摄和编辑的 UI 界面比较丑，调研一下 iOS 和 Mac 上分别有哪些比较主流的做法，写个技术方案」
> 下游：建议 SPEC-UIA-014（设计系统）与 UIA-014~018 任务批次（§7）；**不新增 ADR**（不动架构红线；§5 的基线策略若拍板再立 ADR）

---

## 1. 调研要回答的问题

1. 「丑」的根源是什么——框架选错了，还是设计缺位？
2. iOS 上拍摄页 / 剪辑页的主流做法（设计语言、布局范式、依赖选型）是什么？
3. macOS 上呢？与我们现有布局差在哪？
4. 在 ADR-0010 基线（iOS 16 / macOS 15.4）与 ARCH-005（UI 不跨端共享）约束下，落到本仓怎么改？

---

## 2. 现状诊断：先定性，「丑」从哪来

逐屏过一遍现有实现（代码证据）：

| 症状 | 证据 | 定性 |
|---|---|---|
| 色彩/字号/间距全是手搓魔法数，无语义令牌 | `Common/Theme.swift` 全文件硬编码 RGB | 缺设计系统层 |
| iOS 首页 = 黑底 + 两块灰卡片 | `iOSApp/HomeView.swift` `entryCard` | 信息架构 OK，视觉单薄 |
| 相机页模式切换用系统 segmented control，浮在取景画面上非常突兀 | `CameraView.swift` `modePicker` | 控件形态错位（主流拍摄 App 用文字滑条） |
| 滤镜选择条是**纯文字胶囊**，看不到滤镜效果 | `CameraView.swift` `filterStrip` | 交互失能：选滤镜前无法预览 |
| 顶栏两个孤立圆钮、美颜面板是表单式 Slider 列表 | `CameraView.swift` `topBar`/`beautyPanel` | 布局散、层级弱 |
| 录制完成面板 = Alert 风格浮层 + 三个 bordered 按钮 | `CameraView.swift` `recordedPanel` | 关键时刻（产出物）最随意 |
| 编辑页 iOS 竖屏三区按 0.60/0.25/0.15 硬切 | `EditorLayout.swift` `verticalLayout` | **桌面范式搬进手机**：属性面板常驻但只有 15% 高，不可用 |
| 工具栏是 caption 小图标 +「Timeline」文字 + 调试版本号 `v12` | `TimelineZone.swift` | 调试残留直接进了界面 |
| 时间线片段是纯色矩形 | `Theme.swift timelineClip` 单色块 | 无缩略图/波形/选中态语义 |
| macOS 裸 WindowGroup，无工具栏、无菜单定制、无 Inspector | `MacApp/ChuanqiCutMacApp.swift` | 不符合 Mac 惯例，像「网页套壳」 |

**结论：「丑」不是框架问题。** 我们已经在用与主流完全相同的框架组合（SwiftUI + AVFoundation + Metal 自绘），主流剪辑 App 没有一个是靠第三方 UI 库变好看的。差距来自三层：

1. **没有设计系统层**（令牌 → 组件 → 屏幕，全是即兴）；
2. **布局范式错位**（iOS 竖屏塞了桌面三区；macOS 没吃 Mac 窗口惯例）；
3. **细节打磨为零**（无动效、无微交互、调试元素外露）。

所以技术方案的主轴是**设计 + 布局重构**，不是换框架、不是引库。

---

## 3. iOS 主流做法

### 3.1 设计语言：Liquid Glass（iOS 26 起，系统级）

- Apple 于 WWDC25 发布 **Liquid Glass** 新设计语言，随 iOS 26（2025-09 发布）落地：标准控件、sheet、toolbar 自动获得玻璃材质；系统据此重构了全部自带 App（含相机）。
- 官方采用指导（*Adopting Liquid Glass*）：**标准组件优先**（自动获得新材质）、**减少自定义背景**（会压住系统玻璃/scroll edge 效果）、**自定义控件少量使用** `glassEffect(_:in:)`，配 `GlassEffectContainer` / `glassEffectID` 做形变联动；按钮用 `.buttonStyle(.glass)`。
- 对我们的直接含义：**验证真机 iPhone 17 Pro 就是 iOS 26**（ADR-0010 §6）——玻璃质感在很大程度上是「白送」的，前提是**用 SDK 26（Xcode 26）构建**。构建机当前 SDK 为 iphoneos18.4（`.ai/modules/ui-apple.md` 验证段、pitfalls P39），这是先决条件（§5、§8）。

### 3.2 拍摄页范式（Apple 相机 / 抖音 / 剪映拍摄页的共同形状）

| 元素 | 主流做法 | 我们现状 |
|---|---|---|
| 取景 | 全屏铺满，控件**悬浮其上**（玻璃材质），画面即背景 | ✅ 已全屏，控件用 `.ultraThinMaterial` 圆钮（形态对，层级散） |
| 模式切换 | 文字滑条（照片 / 视频横向滑动），非 segmented control | ❌ 系统 segmented |
| 滤镜选择 | **缩略图预览卡**（同帧多滤镜渲染，圆角卡横向滑动），选中态外描边 | ❌ 纯文字胶囊 |
| 快门 | 双态（白圈拍照 / 红点录像）+ **录制进度环**，大圆钮居中 | 部分（双态有，进度环无） |
| 参数面板 | 半屏 sheet（detents），玻璃材质，滑杆即时生效 | 形态对（detents medium 已用），材质待升级 |
| 产物时刻 | 全屏结果页：大预览 + 明确主按钮（保存/下一步编辑） | ❌ Alert 风浮层 |

> **佐证**：iOS 26 系统相机 App 自身就完成了这次改版——全屏取景 + 悬浮 Liquid
> Glass 圆钮 + 精简模式切换，布局明显靠拢社交拍摄 App 的形状（MacRumors 评测；
> Apple 官方 iOS 26 新功能文档）。系统相机与抖音/剪映拍摄页趋同，等于该范式
> 已成为 iOS 用户的事实标准——跟它对齐没有教育成本。改版过程也有反面教训
> （控件收拢过狠引发争议、后续 beta 回调），印证走查清单制（§7）的必要性。

### 3.3 依赖选型结论：拍摄 UI 不引第三方库

调研了主流 iOS 相机库现状（2026-10 时点 [E]）：

- [NextLevel](https://github.com/NextLevel/NextLevel)：采集封装（AVFoundation 之上的 capture session 管理），活跃度一般；**不管 UI**。
- SwiftyCam：Snapchat 式采集封装，原 repo 多年无实质维护（社区 fork 续命）[E]。
- [Mijick/Camera](https://github.com/Mijick/Camera)：SwiftUI 原生较新的采集库；同样只解决采集，UI 仍要自己写。

**结论：引库零收益。** 采集层我们已按 ADR-0014 自研完成（CameraManager/Recorder/Renderer，CAM 系列任务），UI 丑与采集层无关；视觉升级是纯 SwiftUI 视图层重排。这与 ADR-0015 相册选型的逻辑同构：能力已在手，引三方只添治理成本（红线 #10 精神）。

### 3.4 iOS 剪辑页范式（剪映 / CapCut 移动端 = 行业默认形状）

- **单焦点 + 抽屉**模式：预览最大化（占屏幕上部 60–70% [E]）→ 时间线中部横条（双指缩放、可调高）→ **底部图标工具栏**（一级工具：剪辑/音频/文字/贴纸/特效/滤镜，图标 + 文字，单手拇指可达）→ 点工具后底部栏被**二级抽屉**替换（参数、素材选择在此完成）→ 属性调参一律底部弹出面板，**无常驻侧栏**。
- 对照我们现状：iOS 竖屏硬塞「桌面三区」（0.15 高度属性面板常驻），是典型的范式错位。**iOS 编辑页需要按剪映形状重构**，而非给现有三区刷漆。

---

## 4. macOS 主流做法

### 4.1 设计语言：Tahoe Liquid Glass + Mac 惯例

- macOS 26（Tahoe）同样引入 Liquid Glass：`NSToolbar` / `NSSplitView` / SwiftUI toolbar 与 split view 在 SDK 26 构建下**自动**获得新材质；Apple 官方指导：交互项玻璃化是自动的，**非交互项（自定义标题等）不要叠在玻璃上**；侧边栏实现**不要偏离 `NSSplitViewController`**（WWDC25 实验组结论）。
- SwiftUI 侧对应：`NavigationSplitView` / `Inspector` / `toolbar` / `toolbarSpacer`（WWDC25 *Build a SwiftUI app with the new design*）。

### 4.2 剪辑页范式：标准 NLE 五区

CapCut 桌面版 / FCP / Premiere / DaVinci 的共同骨架：**顶栏（项目名 + 导出主按钮）/ 左媒体库 / 中预览 / 下时间线 / 右检查器（Inspector）**。其中 CapCut 桌面版刻意比专业 NLE「更扁平」：不做浮动面板与深度定制，优先易学性 [E] —— 这正是我们目标用户（轻剪辑）的取向，值得对齐。

对照我们现状（`EditorLayout.swift` macLayout）：**布局同构 ✅**（左预览+时间线 / 右属性面板），缺的是三件事：

1. **Mac 窗口惯例**：没有工具栏（项目名/导出应进 NSToolbar 风格顶栏）、没有菜单栏定制（文件/编辑/播放）、没有 Inspector 折叠；
2. **可调布局**：时间线高度写死 220，分隔条不可拖；
3. **视觉打磨**：同 §2。

### 4.3 Mac 交互惯例清单（重构时的对齐项）

空格键播放/暂停、JKL 播放控制、I/O 打点（专业惯例，酌情）、Cmd+Z/Shift+Cmd+Z（✅ 已有）、双击全屏预览、检查器右栏可折叠、分隔条可拖拽。

---

## 5. 关键决策：设计基线策略（需要拍板）

Liquid Glass 需要 **SDK 26 构建 + iOS/macOS 26 运行**，而 ADR-0010 基线是 iOS 16 / macOS 15.4。三个选项：

| 选项 | 内容 | 评估 |
|---|---|---|
| A. 提基线到 26 | 放弃 iOS 16–25 / macOS 15 覆盖 | ❌ 与 ADR-0010 冲突，覆盖损失无必要 |
| B. **双轨适配（推荐）** | Theme 2.0 令牌先行（全版本统一的品牌层）+ SDK 26 构建后标准控件在 26+ 自动玻璃化、低版本自动回退系统材质；自定义玻璃效果一律 `#available(iOS 26.0, *)` 门控 | ✅ 增量成本最小；体验随用户系统升级免费变好；符合「能力运行时查询」红线精神 |
| C. 纯自绘设计系统 | 完全不看齐系统新设计，自造视觉 | 品牌可控，但每次 OS 大版本更新都会「显旧」，维护成本最高 |

**推荐 B，且分层清晰**：

- **令牌层（Theme 2.0）** = 品牌层，两端共享**令牌值**（对应 ARCH-005「共享会话状态，不共享 UI」——共享的是值表，不是组件）；
- **材质/组件层** = 平台层，各端各写，跟随系统（26+ 玻璃 / 低版本系统材质）。

**先决条件**：构建机升级 Xcode 26（SDK 26）。若短期升不了：Theme 2.0 + 布局重构（纯 SwiftUI，现有 SDK 可编译）先行，玻璃 API 留 `#available` 门控后补——顺序不影响方案成立。若拍板，建议补一条 ADR（「视觉基线双轨策略」），把 §5 固化。

---

## 6. 技术方案（落到本仓）

### 6.0 设计系统层（UIA-014，先行）

- **Theme 2.0**：语义令牌替代裸色值——`bg / surface / surfaceElevated / accent / accentSecondary / danger / success`、字号阶梯（caption→largeTitle）、间距阶梯（4/8/12/16/24/32）、圆角阶梯（8/12/16/capsule）、动效曲线（统一 0.2s ease-out 量级 [E]，≤300ms）。
- **合并 PickerTheme.accent**（UIA-013 引入）到统一 accent，消除两套主题。
- 深色唯一（行业剪辑 App 惯例），不做浅色主题。
- 全量 SF Symbols 语义图标；App 图标用 **Icon Composer** 分层产出（Liquid Glass 图标规格）。

### 6.1 iOS 相机页重构（UIA-015）

只动视图层，`CameraViewModel` / 权限态 / 降级态逻辑不动：

1. 布局重排：全屏预览 + 顶部浮动条（左美颜、右翻转，玻璃胶囊组）+ 模式文字滑条；
2. 滤镜条改**缩略图预览卡**：同一帧静态画面 + 各 LUT 预渲染小图（不需要实时链路，一次抽帧 + Core Image 离线出图即可）；
3. 快门加录制进度环；录制完成 → **全屏结果页**（大预览 + 存相册/去编辑主次按钮）；
4. 美颜面板升级为玻璃 sheet（detents medium 保留）；
5. 26+ 门控：控件底座用 `glassEffect`，低版本回退 `.ultraThinMaterial`。

### 6.2 iOS 剪辑页重构（UIA-016，§3.4 范式）

1. 竖屏布局改「单焦点 + 抽屉」：预览占上部、时间线中部固定高度（拖拽可调）、**底部工具栏**（图标 + 文字，一级工具位预留：剪辑/音频/文字/特效）；
2. 属性面板与素材库改 **bottom sheet**（半屏 detents），不再常驻 15% 条；
3. `EditorLayout.swift` 仅重写 iOS 分支，macOS 分支与纯函数几何（`TimelineLayout`）不动；
4. 播放控制上移到预览区（点预览即暂停，行业惯例）。

### 6.3 macOS 剪辑页惯例化（UIA-017）

1. 顶栏工具条：项目名 + 播放控制居中 + 导出主按钮（唯一主操作）；
2. 右侧面板改可折叠 Inspector（现有 PropertyPanelZone 内容平移）；
3. 分隔条可拖（时间线高度可调）；菜单栏补齐（文件/编辑/播放，Cmd+Z 已有）；
4. 空格播放/暂停、双击预览全屏。

### 6.4 时间线视觉（UIA-018）

1. 片段 = **缩略图条**（异步抽帧，遵守「主线程不解码」硬约束 #4，缓存复用 MetalPreviewView 链路）+ 圆角 + 选中描边；
2. 轨道色带语义：视频蓝 / 音频绿 / 文字紫（行业惯例 [E]）；
3. 波形渲染单列后续任务（依赖音频分析，勿与视觉混包）；
4. 「v\(version)」调试指示移入 `#if DEBUG`。

### 6.5 非目标（防范围膨胀）

- **不引任何第三方 UI 框架/组件库**（红线 #10；§3.3 已论证引库零收益）；
- 不做浅色主题、不做用户自定义皮肤；
- 不动 Command / EditorViewModel / Session 架构（本次纯视图层 + 令牌）;
- 不做转场动画编排等「内容型」功能，动效仅限微交互打磨；
- Android / 鸿蒙不在本轮（P1/P2，届时按对应平台惯例重做，共享的只有 Theme 令牌值）。

---

## 7. 任务拆分建议与验收

| 任务 | 范围 | 主要写集 | 验收（可判定） |
|---|---|---|---|
| UIA-014 设计系统 | Theme 2.0 令牌 + 图标梳理 | `Common/Theme.swift`、引用点替换 | 两平台编译通过；全仓无裸 RGB（grep 检查） |
| UIA-015 iOS 相机页 | §6.1 | `iOSApp/Camera/CameraView.swift`（视图层） | 编译 + 真机走查清单（§8 项 6） |
| UIA-016 iOS 剪辑页 | §6.2 | `Editor/EditorLayout.swift` iOS 分支、TimelineZone、新 BottomToolbar/sheet | 编译 + 走查；`TimelineLayout` 单测不回归 |
| UIA-017 macOS 惯例化 | §6.3 | `Editor/EditorLayout.swift` mac 分支、MacApp 入口 | 编译 + 走查；Cmd+Z/空格键功能不回归 |
| UIA-018 时间线视觉 | §6.4 | `Timeline/EditorTimelineView.swift`、Theme | 500 片段布局 ≤ 既有基线 0.663ms/帧（baselines）；缩略图异步（无主线程解码） |

- 顺序：UIA-014 → 015/016/017 可串行 → 018；共享文件 `Theme.swift` 由 UIA-014 一次改净，后续任务只读。
- 视觉验收的主观性处理：**走查清单制**（每屏列点：层级/对齐/间距/态完备），替代「变好看」这类不可判定表述（cq-spec-authoring 纪律）。
- 门禁现实：本机 P39 拒跑构建，编译门禁在构建机执行；真机项沿用 UIA-011 先例（延期非取消）。

## 8. 风险与开放问题

1. **[hypothesis]** 构建机 Xcode 26 升级时间未定 → 决定玻璃 API 是否本期可用；不阻塞 Theme 2.0 与布局重构先行。
2. 滤镜缩略图需要从取景流抽单帧 + LUT 离线渲染，需确认现有 `CameraFilter` API 可复用（小技术点，UIA-015 开工前 spike）。
3. UIA-016 把素材库/属性搬进底部 sheet 后，「从文件导入 / 从相册导入」入口去哪（一级工具位 or 「媒体」抽屉）——Spec 阶段定。
4. 26+ 玻璃与低版本材质两版观感差异，走查需双版本覆盖（低版本可用模拟器，仅视觉走查用）。
5. Liquid Glass 的可读性争议（透明工具栏在亮背景上对比度弱 [E]，社区已有批评）——剪辑 App 是深色内容为主，风险小，但走查清单需含「透明度设置开启后的可读性」项。

## 9. 来源

- [Apple：Adopting Liquid Glass（官方采用指南）](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Apple：All New Features in iOS 26（官方文档，2025-09）](https://www.apple.com/os/pdf/All_New_Features_iOS_26_Sept_2025.pdf)
- [MacRumors：iOS 26 相机 App 新设计与改版（全屏取景+悬浮玻璃控件）](https://forums.macrumors.com/threads/ios-26-camera-app-new-features-and-design-changes.2461556)
- [Mac O'Clock（Medium）：iOS 26 相机改版争议（反面视角）](https://medium.com/macoclock/did-anyone-ask-for-the-ios-26-camera-app-makeover-ae838ae4bdc2)
- WWDC25：Build a UIKit app with the new design（玻璃悬浮导航/工具栏自动分组）
- [Apple：Applying Liquid Glass to custom views（glassEffect / GlassEffectContainer / glassEffectID / .buttonStyle(.glass)）](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- Apple 新闻稿：[Introducing a delightful and elegant new software design（2025-06-09）](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)
- WWDC25：Build a SwiftUI app with the new design（toolbarSpacer、tab bar 行为等新 API）；Build an AppKit app with the new design（NSToolbar 玻璃规则）
- Apple Developer Forums AppKit 版：Tahoe 上 `NSSplitViewController` 侧边栏不建议偏离（WWDC25 UI Frameworks 实验组结论转述）
- [mjtsai：macOS Tahoe Liquid Glass 批评汇总（可读性反例视角）](https://mjtsai.com/blog/)
- [capcutguide.com：CapCut vs Filmora 桌面版界面对比（五区布局）](https://capcutguide.com)；Studocu：CapCut Basics 教学材料（面板功能划分）
- [NextLevel](https://github.com/NextLevel/NextLevel)、[Mijick/Camera](https://github.com/Mijick/Camera)、SwiftyCam（原 repo 停滞，社区 fork 续命）
- 本仓现状代码：`Common/Theme.swift`、`iOSApp/HomeView.swift`、`iOSApp/Camera/CameraView.swift`、`Editor/EditorLayout.swift`、`Editor/TimelineZone.swift`、`MacApp/ChuanqiCutMacApp.swift`
