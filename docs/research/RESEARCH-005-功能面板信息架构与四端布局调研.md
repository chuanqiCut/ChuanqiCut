# RESEARCH-005：功能面板信息架构与四端布局调研（iPhone / iPad / Mac / 折叠屏）

> 日期：2026-10-04
> 调研时点：2026-10-04，来源为公开网络资料 + 本仓代码现状（§10 列来源）
> **数字纪律**：本文所有第三方数字均为公开资料转述或估算 **[E]**，未实测，不得作为验收阈值；无法核实处标 `[hypothesis]`。
> 上游需求：用户命题「当前拍摄编辑的滤镜、美颜、裁剪等面板采用哪种方式管理，当前的 UI 是否合理和现代化；吸取主流编辑器的优点，在 Mac、iPad、iPhone、以及折叠屏如何布局更好，发挥各自优势；产出调研结果和技术方案」
> 上游调研：**RESEARCH-004**（页面级视觉范式 / 设计系统 / Liquid Glass 基线策略，本文直接继承其结论，不重复论证）
> 下游：**SPEC-UIA-019-统一面板框架与四端布局**（`docs/specs/UIA-019-统一面板框架与四端布局.md`）；**不新增 ADR**（理由见 §7.2）

---

## 1. 调研要回答的问题

1. 滤镜、美颜、裁剪等面板**现在是怎么管理的**？（管理方式审计）
2. 现状是否合理、是否现代化？差距在哪一层？
3. 主流编辑器（视频 + 照片、手机 + 平板 + 桌面）的面板信息架构有什么**共同规律**值得吸收？
4. Mac / iPad / iPhone / 折叠屏各自应该**怎么布局面板**，如何发挥各自形态优势？

---

## 2. 现状审计：面板管理方式（代码证据）

### 2.1 面板清单

| 面板 | 域 | 状态 | 位置 | 呈现方式 | 管理者 |
|---|---|---|---|---|---|
| 相机美颜（磨皮/美白滑杆 + 美型禁用占位） | 拍摄 | 已实现 | `CameraView.swift:200-244` | `.sheet` + `presentationDetents([.medium])` | View 内 `@State showBeautyPanel` 布尔 |
| 相机滤镜选择条（8 预设，**纯文字胶囊**） | 拍摄 | 已实现 | `CameraView.swift:127-150` | ZStack 常驻内联横滑条 | `CameraViewModel.filter`（@Published didSet→renderer） |
| 录制产物面板（存相册/去编辑/放弃） | 拍摄 | 已实现 | `CameraView.swift:248-274` | ZStack 条件 overlay | `@Published recordedURL` |
| 素材库面板（导入 + 列表） | 编辑 | 已实现 | `PropertyPanelZone.swift:29-182` | 常驻三区之一；内挂 fileImporter 与相册浏览器两个 sheet | `@State` 布尔 ×2 + `PhotoLibraryImporter` |
| 自研相册浏览器 | 编辑 | 已实现（UIA-013 v1.1） | `MediaPicker/AlbumPickerScreen.swift` | `.sheet`，detents medium/large；macOS 固定 720×560 窗 | `MediaPickerViewModel` |
| 属性面板（变换/调色/滤镜参数） | 编辑 | **桩**（三行占位文字） | `PropertyPanelZone.swift:115-138` | 常驻三区之一 | —（UIA-006 未开工） |
| 滤镜 / 调节 / 裁剪 / 贴纸 / 文字面板 | 编辑 | **不存在** | — | — | 前置：MODEL-003（EffectBinding）、COLOR-003、UIA-006 |
| 相机贴纸选择条 | 拍摄 | 规划（CAM-014） | TASK-CAM-014 | 计划「与滤镜条同款横滑条」 | — |

全仓呈现机制盘点：3 个 `.sheet` + 2 个 `navigationDestination` + 1 个 ZStack overlay + 常驻分栏区。**没有 fullScreenCover、没有自研 bottom sheet 组件、没有 NavigationSplitView、没有多 Scene**。

### 2.2 管理方式：三种范式并存，无统一状态机

- 面板的开关状态全是 **View 内散落的 `@State` 布尔**（`showBeautyPanel`、`showImporter`、`showAlbumPicker`……），没有面板路由/状态机；「当前打开了哪个面板」「能否再开第二个」无人负责。
- **同一屏两种入口范式并存**：美颜 = 顶栏圆钮 → sheet；滤镜 = 常驻横滑条直选。CAM-014 贴纸若照计划「与滤镜条同款」将继续第三种混排。
- 页面路由（HomeView `Route` enum、CameraView `showEditor` 布尔）只管页面跳转，与面板正交，没有复用关系。

### 2.3 参数路径：两条互不相通的通道

- **相机域**：`@Published beauty/filter` 的 `didSet` → `renderer.setBeauty/setFilter`（主线程写锁，渲染线程按 美颜→滤镜 顺序消费）；**无 Undo**；录制时锁定参数（WYSIWYG 语义）。ADR-0014 代价：相机特效与编辑器特效是两套实现。
- **编辑器域**：UI → `EditorViewModel.submit(Command)` → session 线程 → 快照回流刷新；但内核 C ABI **只有素材/轨道/片段/撤销类命令，无任何效果参数命令** —— 编辑器面板参数化（实时预览路径 vs 提交路径）目前**零先例**，Undo 覆盖完全取决于未来 UIA-006 的 Command 化设计。
- 可复用的既有范式：ADR-0012 时间线拖拽——**交互期间只改本地预览态，松手提交一条 Command，提交后回内核真值**。

### 2.4 控件层：没有组件库，每个面板各写一套

`Common/Theme.swift` 只是 51 行颜色/尺寸常量表。美颜滑杆是手写 `HStack + Slider + 标签`（CameraView 内），滤镜条是私有 `filterStrip`，素材库列表内联 ForEach；唯一可复用的呈现修饰符 `pickerSheetFrame` 是**文件私有**。每新增一个面板，滑杆/横滑条/参数行都要重写一遍。

### 2.5 多设备适配现状

- 唯一收敛点 `EditorLayout.swift`：macOS = HSplitView（左预览+时间线 / 右 280pt 面板）；iOS 用 `horizontalSizeClass` 分支——compact 走 0.60/0.25/0.15 三段 VStack，regular 与 macOS 同构。**iOS 分支自带注释：从未被编译过**（真机不可用，INFRA-009 首次暴露）。
- iOS 工程 `TARGETED_DEVICE_FAMILY: "1,2"`（可装 iPad）、plist 声明三向横竖屏，但**没有任何 iPad/横屏专项适配**；相机页按竖屏沉浸式写死，横屏表现未定义。
- SPEC-UIA-002 承诺的 iOS 竖屏属性面板「上拉展开至 50%」手势**未实现**。
- 折叠屏（Android P1 / HarmonyOS P2）：`ui-android.md` 为占位骨架，零适配代码。

---

## 3. 判定：哪些合理、哪些欠现代化

### 3.1 合理、应保留的

1. **半屏 sheet + detents 的面板形态**与主流一致（美颜面板选型是对的）；
2. **平台差异收敛在 EditorLayout、UI 不跨端共享**的架构原则正确（红线 #1、ARCH-005）；
3. **Command → session → 快照回流**的地基为面板参数化预留了正确通道（等 MODEL-003）。

### 3.2 欠现代化（按层定性）

| 层 | 症状 | 证据 |
|---|---|---|
| 管理层 | 面板无状态机、@State 布尔散落、同屏多范式并存 | §2.2；新增面板成本与不一致风险随面板数线性放大 |
| 组件层 | 无共享控件库；滑杆无双击重置/长按对比/触觉反馈 | §2.4；对比 Lightroom 官方交互（§4.7） |
| 布局层 | 编辑页把**桌面三区搬进手机**（15% 常驻属性条不可用）；滤镜条**选前无法预览**（纯文字胶囊）= 交互失能；iPad/横屏未定义 | `EditorLayout.swift:64-81`；RESEARCH-004 §2 已诊断页面级症状，此处补面板级 |
| 细节层 | 调试版本号 `v12` 露在时间线工具栏；空态/加载态随意 | `TimelineZone.swift` |

**总判定：形态雏形（sheet/detents/常驻区）方向正确，但管理方式不现代（无框架）、组件不复用、编辑器面板整体缺位、iPad 与折叠屏空白。** 页面级视觉与布局重构已由 RESEARCH-004 → UIA-014~018 承接；本文聚焦**面板级信息架构与跨形态布局**。

---

## 4. 主流编辑器面板信息架构（逐家分析）

### 4.1 CapCut / 剪映（手机 / iPad / 桌面三端）

- 桌面版经典四区：左媒体池、中预览、下多轨时间线、**右属性检查器**（位置/缩放/速度/音量/色彩/AI 工具分栏），右上导出。刻意比专业 NLE「更扁平」：无浮动面板、不搞深度定制，优先易学性 [E]（capcut.com、cursa.app）。
- 手机版：预览在上、时间线在中、**一级底部工具栏**（剪辑/音频/文字/贴纸/特效/滤镜…图标+文字）→ 点选后底部栏被**二级抽屉/参数面板替换**，参数在下半屏完成，**无常驻侧栏**（cursa.app）。
- iPad 有独立「CapCut Pad」：桌面式多轨布局，强化触控与 Pencil（capcut.com）。
- **对我们的意义**：手机端「单焦点+抽屉」与桌面端「四区+Inspector」是两端各自的行业标准答案；平板介于两者之间按大屏惯例重排，而非放大手机 UI。

### 4.2 VN Video Editor

- 多端（iOS/Android/Mac/Win），多轨时间线、Main Track Mode、关键帧曲线、滤镜+即时调色（vlognow.me）；iPad 版口碑好于手机版 [E]（apps.apple.com）。
- **对我们的意义**：验证「同一产品线可跨三端」，但其面板容器细节无可靠官方来源，不作依据。

### 4.3 InShot

- 纯手机单屏：上预览 + 底部工具栏（Canvas/Music/Text/Filter/Sticker…），Filter 菜单内含 Adjust（inshot.com、elegantthemes.com）。
- **对我们的意义**：最简形态参照——一级工具栏 + 二级面板的两层入口即可覆盖轻剪辑需求。

### 4.4 LumaFusion（iPad 专业范例）

- 四区：侧边媒体库、顶部 viewer、底部时间线；点选片段进入 **clip editor**，内含四个编辑器：**Frame & Fit（裁剪/画面）**、Audio、Speed、**Color & Effects**——裁剪是「接管式」专属编辑器，色彩滑杆在编辑器内下钻展开；预设点选后显示对应滑杆组（luma-touch.com 官方 Reference Guide）。
- **对我们的意义**：**裁剪应从「滑杆面板」独立为全屏手势接管操作**，这是专业软件与消费软件的共同选择；参数面板按「功能域」组织编辑器而非平铺。

### 4.5 iMovie（三端梯度）

- Mac：三栏可调窗口（浏览器/预览/时间线），浏览器可隐藏；iPhone：仅预览+时间线，媒体浏览器以浮层弹出；iPad 介于两者（support.apple.com、macworld.com）。
- **对我们的意义**：Apple 自家产品的三端梯度证明——**信息架构分层按形态裁剪，而不是全功能平移**。

### 4.6 Final Cut Pro / DaVinci Resolve（桌面 + iPad）

- FCP Mac：右侧 Inspector 按 **Video / Audio / Color** 分区，效果可从 Inspector 拖到片段（help.apple.com）；FCP iPad（2023.5）：touch-first，viewer + 磁性时间线 + 底部情境工具行，browser/inspector **可显隐**，色彩控制较 Mac 简化（support.apple.com、mjtsai.com）。
- Resolve：**pages 页面化信息架构**（Media/Cut/Edit/Fusion/Color/Fairlight/Deliver 一级页签），iPad 版首发仅 Cut+Color，后续补齐（provideocoalition.com）。
- **对我们的意义**：①桌面 Inspector 的**分区分组**惯例值得照抄；②FCP iPad 证明「底部工具行 + 可显隐 Inspector」的混合式在平板成立；③大功能域可以做一级页面切换，但我们的轻剪辑规模还用不到 Resolve 级 pages。

### 4.7 Adobe Lightroom / Photoshop Express（滑杆交互的官方基准）

- 手机端 Presets 与 Edit 双入口；Edit 内**分组滑杆**（Light/Color/Effects/Detail…组可折叠）；**长按图片显示原图、松开恢复**（before/after）为官方交互；**双击滑杆圆点恢复默认值**；桌面端右侧 Edit+Presets 面板堆叠、组可开合（helpx.adobe.com、adobe.com/learn、lightroomqueen.com）。
- **对我们的意义**：**双击重置 + 长按对比 + 分组滑杆**是唯一有官方文档背书的滑杆交互三件套，直接采纳为本仓 `ParamSlider`/`PanelSection` 组件规范。

### 4.8 Pixelmator Pro（Mac 原生现代范例）

- 单窗口：右侧 contextual Tools sidebar（随选中对象切换面板）+ 图层栈；2.0 起侧栏与工具栏可自定义（support.apple.com）。
- **对我们的意义**：Mac 面板的「情境化」（选中什么显示什么参数）是 Inspector 的正确形态，避免一个面板塞所有参数。

### 4.9 中文生态补充

- 剪映 Pad 专业版：已完成鸿蒙平板适配（跨窗拖拽、键鼠穿越，体验接近桌面级）[E]（news.zol.com.cn、post.smzdm.com）；美图秀秀有独立 HD（iPad）版（apps.apple.com）；醒图未见平板/折叠屏专项适配的可靠来源。
- **对我们的意义**：头部中文编辑器同样走「平板/大屏=桌面化或混合化」路线，且折叠屏专项适配**普遍缺位**——这是差异化机会（§5.4）。

### 4.10 模式提炼

**A. 面板容器只有四种原型**（所有产品的容器都可归入）：

| 原型 | 形态 | 适用 | 例证 |
|---|---|---|---|
| P1 bottom sheet | 半屏抽屉（detents 可拖拽） | 手机/compact 的参数与选择面板 | CapCut 手机、我们美颜面板 |
| P2 Inspector | 常驻右侧栏（可折叠、推开内容） | 桌面/regular 宽度的参数面板 | FCP、Lightroom CC、Pixelmator、CapCut 桌面 |
| P3 常驻区 | 固定布局槽位 | 媒体库/素材库等「内容型」面板 | 我们素材库、iMovie 浏览器 |
| P4 全屏接管 | 覆盖全屏的专属操作态 | 裁剪/画面调整等强手势操作、结果页 | LumaFusion Frame & Fit |

**B. 入口层级规律**：一级 = 功能**域**（剪辑/音频/文字/滤镜…），二级 = 域内面板；**参数控件永不遮挡预览主线**（手机在下半屏、桌面在右栏）。

**C. 滑杆/选择交互惯例**：双击重置、长按对比原图（Lightroom 官方）；滤镜 = 缩略图预览卡 + 选中描边 + 强度滑杆（RESEARCH-004 §3.2 同结论）；裁剪 = P4 全屏 + 角手柄 + 网格 + 比例 chips（行业通用 [E]）。

**D. 端规律**：手机 = 底部 sheet；桌面 = 右 Inspector；平板/大屏 = **按 size class 在两者间切换**（同一面板内容、两种容器——FCP iPad 的混合式验证了可行性）。

---

## 5. 四端布局方案（发挥各自优势）

### 5.1 iPhone（compact）——单手拇指优先

继承 RESEARCH-004 §3.4「单焦点+抽屉」页面范式，面板归属：

| 面板 | 容器 | 要点 |
|---|---|---|
| 滤镜选择 | 常驻横滑缩略图卡（P3 变体）+ 长按面板内强度滑杆 | 缩略图预渲染，选中描边（UIA-015 落地视觉） |
| 美颜/调节 | P1 sheet（detents medium/large 可拖拽） | 分组滑杆，双击重置，长按对比 |
| 裁剪 | **P4 全屏接管** | 角手柄+网格+比例 chips+旋转，完成/取消入底部 |
| 贴纸/文字 | P1 sheet + 预览画布直操 | 选中后参数就地浮层 |
| 素材库 | 一级「媒体」抽屉（P1 large） | UIA-016 定入口去向（RESEARCH-004 §8.3） |

要点：一切参数控制在下 40% 拇指区 [E]；sheet 半屏时预览仍至少露出上部（滑杆调参需看到画面变化）。

### 5.2 iPad（regular）——触控优先 + 大画布 + Pencil 精修

- **保持与 iPhone 相同的一级 IA**（底部工具栏，触控优先、降学习成本——FCP iPad 同款选择），但**参数面板升格为右侧 Inspector（P2）**：SwiftUI `inspector()` 在 regular width 自动呈现为 trailing column 并**推开内容**（预览不被遮挡），compact 下自动降级为 sheet——**同一份面板代码，两种容器**。
- 媒体库 = 左 sidebar 或底部媒体抽屉（P3），UIA-016 统一定夺。
- **发挥 iPad 优势**：Pencil 用于裁剪角手柄与曲线细调（低延迟手绘）；pointer hover 用于滑杆微调与滤镜预览悬停；键盘快捷键与 Mac 同表（§5.3）；Stage Manager 分屏下靠 size class 自适应不塌布局。
- 拍摄页非主战场 [hypothesis]：沿用沉浸式取景 + 安全区锚定浮动控件，控件组限制最大宽度。

### 5.3 Mac（桌面）——NLE 五区 + 情境 Inspector + 键鼠效率

继承 RESEARCH-004 §4「标准 NLE 五区 + Mac 窗口惯例」（UIA-017 落地），面板归属补全：

| 面板 | 容器 | 要点 |
|---|---|---|
| 素材库 | 左 sidebar（P3） | 惯例三栏：侧栏-内容-检查器 |
| 属性（变换/速度/音量） | 右 Inspector 分区 | 情境化：选中片段才显示（Pixelmator 式） |
| 滤镜/调节 | 右 Inspector 独立分组 | 对齐 FCP Video/Color 分区惯例 |
| 裁剪 | Inspector + 预览画布手柄**双联动** | 桌面用户不爱全屏接管，画布直接拖角 + 右栏数值精调 |
| 导出 | 工具栏主按钮 + sheet | 唯一主操作放顶栏（RESEARCH-004 §6.3） |

**发挥 Mac 优势**：快捷键（空格/JKL 播放、Cmd+Z 已有，C=裁剪、F=滤镜可议）、菜单栏命令（文件/编辑/播放）、`InspectorCommands` 集成、分隔条可拖、双击全屏预览、触控板双指 scrub 滑杆 [hypothesis：行业常见，未逐家核实]。

### 5.4 折叠屏（Android P1 / HarmonyOS P2 —— 设计契约，本期不实现）

Google 官方 canonical layouts（list-detail / supporting pane / feed）+ posture API（`FoldingFeature`：FLAT / HALF_OPENED；铰链 VERTICAL=书型 / HORIZONTAL=翻盖型）是官方推荐路径（developer.android.com）。落到我们的面板框架：

| 姿态 | 布局 | 说明 |
|---|---|---|
| 折叠态（外屏） | = iPhone 布局（5.1） | **App continuity**：折叠/展开触发配置变更，播放进度、面板路由、半调参数必须保持不丢 |
| 展开平放（FLAT） | = iPad 布局（5.2）：底部工具栏 + 右侧参数栏（supporting pane 形态） | Compose 侧对应 `NavigationSuiteScaffold` / `SupportingPaneScaffold` |
| 半开立起（HALF_OPENED，桌面姿态） | 拍摄页 = **FlexCam 范式**：取景器上半 + 控制下半（免手持拍摄，官方 table-top 相机范例）；编辑页 = 预览上半 + 面板下半（天然的大号抽屉布局） | Samsung Flex mode 已验证该交互（samsung.com）；**铰链区禁止放置触摸目标** |

**差异化判断**：中文头部编辑器普遍未做折叠屏 hinge-aware 适配（§4.9），而「半开免手持拍摄 + 实时美颜」恰是我们相机域能力与该形态的天然契合点 [hypothesis，需 P1 立项时验证真机]。

### 5.5 面板 × 端归属矩阵（总表）

| 面板 | iPhone | iPad | Mac | 折叠屏（P1 契约） |
|---|---|---|---|---|
| 滤镜选择 | 常驻缩略图条 | 常驻条 + Inspector 强度 | Inspector 分组 | 随姿态 5.1/5.2 |
| 美颜/调节 | sheet | Inspector | Inspector 分组 | sheet→侧栏随姿态 |
| 裁剪/画面 | 全屏接管 | 全屏接管 + Pencil | 画布手柄 + Inspector 双联动 | 上半屏画布/下半屏比例 |
| 贴纸/文字 | sheet + 画布直操 | 同左 + Pencil | Inspector + 画布直操 | 随姿态 |
| 素材库 | 媒体抽屉 | sidebar/媒体抽屉 | 左 sidebar | list-detail 双栏 |
| 属性（变换/速度…） | 选中浮层 sheet | Inspector | Inspector 情境化 | supporting pane |
| 录制产物页 | 全屏结果页 | 全屏结果页 | sheet（窗口内） | FlexCam 下半屏 |

---

## 6. 面板管理的技术结论（交给 Spec 的六条）

1. **面板路由状态机**：每域一个 `PanelRoute`（none/滤镜/美颜/裁剪/…），面板开关由状态机管理，禁止新增散落 `@State` 布尔；同屏至多一个一级面板。
2. **自适应容器**：面板内容与容器解耦——compact→sheet（detents）、regular→`inspector()`（iOS 17+/macOS 14+，`#available` 门控；iOS 16 回退 sheet，因基线 ADR-0010 为 iOS 16）。容器归 EditorLayout 收敛点扩展，不破坏「业务视图不写条件编译」。
3. **面板控件组件库（PanelKit）**：`ParamSlider`（双击重置/长按对比/触觉/值气泡——Lightroom 三件套）、`SwatchRow`（缩略图卡+选中描边）、`ChipGroup`、`PanelSection`（分组折叠）、`CropCanvas`（全屏接管容器）。组件归 SharedUI，符合 ARCH-005（共享组件值表与行为，不共享页面）。
4. **能力门控**：面板入口可见性走 `cq_query_capability()`（红线 #3）——无美型能力时入口置灰并解释，不编译期推断。
5. **参数双路径维持现状分域**：相机域快路径（didSet→renderer，无 Undo，WYSIWYG 锁定）；编辑器域一律 Command（滑杆拖动期间不提交命令，松手提交——ADR-0012 范式），落地依赖 MODEL-003/COLOR-003。
6. **呈现四原型即框架 API**：sheet / inspector / 常驻区 / 全屏接管四种容器由框架提供，业务面板只声明内容与归属（§4.10 A）。

---

## 7. 与 RESEARCH-004 的关系、编号与 ADR 说明

### 7.1 分工边界

- RESEARCH-004 管**页面级**：设计系统（Theme 2.0）、视觉基线（Liquid Glass 双轨）、页面布局范式（单焦点+抽屉 / NLE 五区）、任务批次 UIA-014~018。
- 本文管**面板级**：面板管理框架（状态机/容器/组件库）、滑杆与滤镜条交互规范、iPad 与折叠屏布局（RESEARCH-004 §6.5 明确不在其范围）。
- 页面范式不冲突：UIA-016（iOS 剪辑页抽屉化）与 UIA-017（macOS 惯例化）是本文框架的**消费方**。

### 7.2 为什么不新增 ADR

- 不动任何既有架构约束：面板框架是 ui-apple.md「平台差异收敛在 EditorLayout」与 ARCH-005「共享会话状态与组件值，不共享 UI」的**顺势延伸**；参数提交沿用 ADR-0012 既有决策；能力门控执行红线 #3 既有规定。
- 唯一潜在的决策点「视觉基线双轨策略」已在 RESEARCH-004 §5 标注「若拍板再立 ADR」，编号应为 ADR-0017，与本文无关。
- 折叠屏为 P1/P2 设计契约，未发生本仓代码/架构变更；届时 Android 立项若引入 posture 驱动的新惯例，再立 ADR。

### 7.3 编号

- RESEARCH-004 已占用「拍摄与编辑 UI 主流方案调研」，本文为其面板级续篇，取号 **RESEARCH-005**。
- RESEARCH-004 建议批次占用 UIA-014~018，本文 Spec 取 **UIA-019**（不与批次冲突；建议执行序：UIA-014 → **UIA-019** → UIA-015/016/017 → UIA-018，019 为 015/016/017 提供面板容器与控件）。

---

## 8. 风险与开放问题

1. `inspector()` 需 iOS 17+：iPad 在 iOS 16 基线上回退为 sheet，观感与最终形态有落差（基线覆盖期有限，可接受；走查需双版本覆盖——同 RESEARCH-004 §8.4）。
2. 裁剪「全屏接管」与时间线选中态的关系（裁剪对象=当前选中片段）需 UIA-006 Spec 细化，本文只定容器原型。
3. 自研相册浏览器（UIA-013 v1.1 刚落盘）是否迁入 PanelRoute：**建议延后**至 UIA-016 一并处理，避免与 UIA-013 后续迭代在高冲突文件上相撞。
4. 折叠屏契约未经真机验证 [hypothesis]；FlexCam 半开姿态的取景裁切、美颜检测框在折叠态的行为需 P1 立项时专项验证。
5. iPad 底部工具栏 + 右 Inspector 的混合式在「轻剪辑」用户中的接受度无一手数据 [E]；走查清单应含「首访用户能否在 30 秒内找到滤镜」类任务项 [hypothesis]。
6. Mac 裁剪「画布手柄 + Inspector 双联动」要求预览层支持手势覆盖，与「MTKView 直绘」硬约束的叠加方式需 UIA-017 设计时确认。

---

## 9. 后续任务建议

| 任务 | 内容 | 依赖 |
|---|---|---|
| **UIA-019 统一面板框架与四端布局** | Spec 已写：`docs/specs/UIA-019-统一面板框架与四端布局.md` | UIA-014（Theme 令牌） |
| UIA-015/016/017 | 作为框架消费方执行（RESEARCH-004 批次不变） | UIA-019 提前于三者 |
| UIA-006 属性面板 | 消费 PanelHost regular 态；依赖 MODEL-003/COLOR-003 | 内核前置 |
| CAM-014 贴纸选择条 | 贴纸横滑条接入 `SwatchRow` | UIA-019 |
| Android P1 折叠屏立项 | 按 §5.4 契约 + Compose adaptive 落地，届时评估 ADR | ARCH-004 排期 |

BACKLOG 登记行随 UIA-019 立项时补（TASK-BACKLOG.md 当前由智能成片会话修改中，避免写集冲突）。

---

## 10. 来源

**产品调研**
- CapCut 官方与使用指南：capcut.com；cursa.app（桌面/手机工作区对比）
- CapCut Pad：capcut.com（iPad 版产品页）
- VN：vlognow.me（官网功能清单）；apps.apple.com（iPad 版评价）
- InShot：inshot.com；elegantthemes.com（功能走查）
- LumaFusion：luma-touch.com 官方 Reference Guide（PDF，clip editor 四编辑器）；filmora.wondershare.com（调色面板分析）
- iMovie：support.apple.com；macworld.com；techjourneyman.com（三端梯度）
- Final Cut Pro：help.apple.com（Inspector 分区）；support.apple.com（FCP iPad Edit screen）；mjtsai.com
- DaVinci Resolve：provideocoalition.com；liftgammagain.com（pages 与 iPad 版）
- Lightroom / Photoshop Express：helpx.adobe.com（滑杆重置、Show Original）；adobe.com/learn（Presets 分层）；lightroomqueen.com（桌面面板堆叠）
- Pixelmator Pro：support.apple.com（单窗口侧栏）
- 中文生态：news.zol.com.cn、post.smzdm.com（剪映 Pad/鸿蒙适配 [E]）；apps.apple.com（美图秀秀 HD）

**平台官方指南**
- Android 大屏/折叠屏：developer.android.com（canonical layouts、fold-aware、posture、app continuity）；developer.samsung.com（app continuity）；samsung.com ANS10003223 与 samsungmobilepress.com（Flex mode/FlexCam）
- Jetpack Compose adaptive：developer.android.com（NavigationSuiteScaffold、ListDetailPaneScaffold、SupportingPaneScaffold、currentWindowAdaptiveInfo）
- Apple HIG：developer.apple.com/design/human-interface-guidelines（Layout/Sheets/Multitasking/Inputs）
- SwiftUI API（原文已核实）：`inspector(isPresented:)`（iOS 17+/macOS 14+；regular=trailing column 推开内容，compact=自动退化为 sheet，presentation 状态自动恢复，配 InspectorCommands）— developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)；`presentationDetents`（iOS 16+，.height detent 在 16–18 有行为不一致报告 — hackingwithswift.com）；`@Observable`（iOS 17+）— developer.apple.com/documentation/observation；Liquid Glass 自定义（glassEffect/GlassEffectContainer）— developer.apple.com、WWDC25 session 323

**本仓代码与文档**
- `CameraView.swift`、`EditorLayout.swift`、`PropertyPanelZone.swift`、`MediaPicker/AlbumPickerScreen.swift`、`Common/Theme.swift`、`TimelineZone.swift`、`AppEntry.swift`、`bindings/swift/.../cq_sdk.h`、`CameraViewModel.swift`、`CameraRenderer.swift`
- RESEARCH-004、SPEC-UIA-002、TASK-BACKLOG.md、TASK-CAM-014、ADR-0010/0012/0014/0015、`.ai/modules/ui-apple.md`
