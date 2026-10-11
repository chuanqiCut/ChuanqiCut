# RESEARCH-013 — 开源轨道/时间轴 UI 盘点 + 本项目轨道操作与面板管理优化路线

> 命题（传哲 2026-10-11）：调研开源的视频编辑轨道（timeline/track）UI 实现，重点看阿里云开源的那套"轨道区"，并给出本项目（iOS + macOS）轨道操作与面板管理的优化方案。
> 归属：A 线（编辑器/UI）；登记指针见 `.ai/modules/ui-apple.md`「调研·决策·池指针」。
> 关联：RESEARCH-004（UI 方案）/ RESEARCH-005（面板信息架构）/ RESEARCH-007（操作逻辑）/ RESEARCH-008（对标 App范式）/ RESEARCH-010（编辑功能对齐）/ **RESEARCH-012（商用 SDK 竞品：该厂商 其创作 SDK × 阿里云 UGSV，已核验源码）**。
> 数字纪律：未实测项标 [E]/[hypothesis]，引用基线带环境。

---

## 1. 先纠正一个前提：阿里云"轨道区开源"到底是什么

传哲印象"阿里云的轨道区也开源了，之前还行"——需要被校准，因为 **RESEARCH-012 已在 2026-10-10 对阿里云 UGSV 开源 UI 源码做了文件名级核验**：

| 项目 | 事实 |
|---|---|
| 开源位置 | `MediaBox-Demos/amdemos-ios-ugsv`（阿里云短视频 SDK 的 Demo UI 源码，**MIT**） |
| 实际形态 | **录制 + 单层编辑 + 裁剪 + 上传**，**不是多轨重编辑器** |
| 缺失项（核验） | **无 split（分割）/ 无 undo·redo / 无草稿箱 / 无复制片段** |
| 云剪辑 Web SDK | 另一条产品线（云端渲染，编辑器本体为 CDN 闭源 JS），只能看布局，不能对齐实现 |

**结论**：传哲印象里"还行"的是它的**单层裁剪交互手感**（拖拽把手、缩放），但把它当作"多轨轨道区范式"来对齐是错的——它根本没有多轨。而且它**没有命令栈撤销重做**，而我们在 ADR-0012 下已有现成的 `CommandHistory` + `cq_session_undo/redo`，**这是我们的既有优势，不能反向对齐到阿里云的开源版**。该厂商（该厂商 其创作 SDK）那边才是真正值得抄的设计（见 §3）。

---

## 2. 开源轨道/时间轴 UI 横向盘点

| 项目 | 平台/语言 | 多轨能力 | 轨道操作 | 面板机制 | 可借鉴点 |
|---|---|---|---|---|---|
| **阿里云 UGSV Demo** | iOS / ObjC | ❌ 单层 | 裁剪/移动 | 代码写死 | 单层裁剪手感；但**别反向对齐**（缺 undo/多轨） |
| **字节 该厂商 其创作 SDK** | iOS / 配置驱动 | 多轨 | 全 | **`Panel_configs/<panel_key>.json` 全配置驱动**（tabs→subItems，多语言标题/图标/资源/业务参数 + 色卡 Key + 文案 Key 换皮三件套） | **面板配置驱动**是我们最大 gap，优先抄 |
| Aamirali86/VideoTimeline | iOS / UIKit MVVM | ✅ 多轨 | 缩放/交换轨/trim 把手 | 无 | 纯 UIKit 多轨手势实现参考（程序化布局、无 storyboard） |
| codewithhera/VideoEditTimeline-and-TrimView | iOS / UIKit+AVF | 多 clip | 波纹 trim / 吸附 / 多 clip | 无 | 对标 App 式 trim + **ripple + snapping** 实现 |
| ymsying/VideoTimelineView | iOS / UIKit | 单 clip | 捏合缩放/scrub/trim | 无 | 最简 trimmer 原型 |
| **Shotcut** | 桌面 / Qt(C++) + MLT | ✅ 无限轨 | 增删轨、clip/track 滤镜、转场拖拽 | **dockable + floating panels**、可重排 | 桌面 NLE 面板范式（Mac 端参考）；可重排布局 |
| **Olive** | 桌面 / C++/Qt | 多轨 | 节点合成 | 标签页 | 节点化滤镜（超纲，仅思路） |
| **Flowblade** | Linux / Python+GTK | 多轨 | **磁吸时间线（Magnetic）/ Insert vs Overwrite 双模式** | 简洁 | **轨道操作语义**：插入/覆盖、磁吸防空隙 |
| OpenShot | 桌面 / Python | 多轨 | 吸附/波形/帧精 | 模块面板 | 通用参考 |
| RoughCut | Web / React+TS | 多轨 | 拖拽/吸附 | 组件化 | Web 端多轨交互参考（非原生，仅借鉴） |

> 注：原生 iOS/macOS 真正"开源且多轨"的成熟项目极少，上面几个 对标 App 式仓库都是**教学/原型级**（单/少轨、无 undo、无渲染），只能借鉴手势与布局，**不能当架构蓝本**。架构蓝本应来自：该厂商的面板配置化（产品面）+ Flowblade 的轨道语义（操作面）+ Shotcut/FCP/Resolve 的桌面面板范式（Mac 面）。
> 仓库存在性核验（2026-10-11，本机）：Aamirali86/VideoTimeline ✅（7 star，纯 UI 模拟无媒体播放）、codewithhera/VideoEditTimeline-and-TrimView ✅（README 确认 ripple-trim/snapping/多 clip）、ymsying/VideoTimelineView ✅（系 Tomohiro-Yamashita/VideoTimelineView 的 fork）。

### 2.5 其轨道 UI 组件库 轨道区交互机制 — 头文件级深挖（2026-10-11 第二轮）

> 应传哲指示补挖：其轨道 UI 组件库（该厂商 VE SDK 的编辑器轨道区模块，Flutter 架构图原文标注 "Track area in the editor"）正是本章主题。RESEARCH-012 §1.5.4 已核验过文件名分类与色卡 JSON，本轮**往下钻一层：读交互核心头文件的内容**。来源：CDN 直链重新下载 `其轨道 UI 组件库@0.3.3`（6,041,770 B，HTTP 200，与 0.1 同链），解包后**只读头文件与资源，未链接未运行未反汇编**（合规边界同 RESEARCH-012 §1.5.6）。0.3.3 共 120 个头文件；缩略图组件 7 个头文件在 0.3.3 已公开（0.1 里是二进制隐藏类）。

**轨道区装配形状（实证）**：

- `其轨道组件`（**UIScrollView 子类**，delegate 四回调：didChangeTime / didEndScroll / willBeginDragging / didZoom，含 `centerY`/`centerY2` 单轨/多轨两种对中基线）→ `其多轨视图`（contentView + CollectionView + `segmentClipView` 把手浮层 + `keyFrameView` + `attacher`）→ Cell 内嵌 `其轨道组件`（**trim 把手是独立浮层**，PanPosition 仅 Left/Right，带 mode/arrowStyle/showWithAnimated）。
- 主控制器 = `其多轨控制器` + **8 个按片段类型划分的 ViewModel**（combination/audio/sticker/textSticker/video/effect/filter/adjust；`其轨道组件` 10 枚举），`registerCellInTrackView` 把各 VM 的 `registerCellClass` 注册进 trackView —— **片段类型是轨道 UI 一等公民**（类型 → ViewModel → Cell → color.json 着色，四处一致切分，与 RESEARCH-012 §1.5.4 色卡互证）。
- 编辑态集中在 `其轨道组件`：主轨/副轨/音轨**选中段分三个属性**、currentTime / timeScale / timelineOffsetX / isZooming / inPreview / `currentLockSegmentId`；`notifyEditorChangedWithCommit:` **显式带 commit 参数** —— 与我们 ADR-0012「交互期不提交、松手提交」同构，也印证 §5.1 把交互态收敛为一个纯逻辑容器的方向。

**交互机制逐条（全部 `其多轨视图.h` 头文件实证）**：

| 机制 | 头文件证据 | 对本项目的意义 |
|---|---|---|
| 长按拿起 + pan 双动作 | `其轨道组件{Pan, LongPress}`、longPressStartRect / longPressSnapCell | 印证 §5.4 iOS「长按拿起」范式 |
| **四向拖拽（跨轨）** | `其轨道组件{Left, Right, Up, Down}`、h/vMovePoint 分离记录 | 多轨跨轨拖动是上下向手势；§5.1 reducer 事件需带方向维度 |
| **边缘自动滚动** | 3 个 CADisplayLink（h/v/pan）+ hEdgeRange/vEdgeRange + `moveSpeedWithOffset:` 速度曲线 + `detectPanEdgeWithPosition:` | **§5 原方案完全遗漏的专业编辑器必备交互**：拖片段到时间线边缘自动滚动，速度随偏移渐进 |
| 吸附三要素 | `其轨道组件`：`attachablePoints[CMTime]` 点集 + `attachPoint:direction:`（方向枚举 L/R）+ `attachThreshold` 类常量；拖拽侧配套 `其轨道组件{minX,maxX}` 与 `getIntersectionRect:searchDirection:` | §4.2「吸附 = 纯 UI 几何」判定被该厂商实证；接口形态可直接对齐——候选点集 + 方向 + 阈值，纯函数可单测，正合 §5.1 `TimelineLayout.snapCandidates` 设计 |
| 双击片段 | doubleTapInterval / lastTapCellTime / lastClickIndexPath | 片段级二级操作入口（进属性/精修） |
| 触觉反馈 | `triggerFeedback` | 手感细节，UIA 侧排期时带上 |
| 尾部插入提示 | `tailInsertTipView` | 拖素材到时间线尾部的落点提示 |
| **分割不在轨道区** | 全部头文件无 split 手势语义（`splitSpace` 只是 cell 间距常量） | 分割走底部编辑条（对标 App同款），印证 §5.4「播放头处一键分割（底部编辑条）」 |

**关键帧 UI（4 头文件实证）**：`其关键帧视图` 挂在片段 slot 上，item = UIButton + offsetTime；随片段 trim 用 `updateKeyFrameWithLeftLimit:/RightLimit:` **收缩帧点范围**；选帧回调 `keyFrameItemDidSelect:offsetTime:`。本期不做关键帧，但「帧点画在片段内、随边缘 trim 联动收缩」的形态记入 UIA-030 之后的设计池。

**缩略图管线（0.3.3 公开 7 头文件）**：Manager 按 slot 分 Loader；Loader = 内存缓存（`getImageForKey`）+ 磁盘（`pathForThumbnail`）+ **最近邻缓存命中**（`closestThumbnailInCache`）+ **按 speed/scale 取缩略图组**（`thumbnailsOfSpeed:scale:`）+ `cancelAllTasks`。对照我们 `TimelineThumbnailStore`（并发上限 3、in-flight 去重、LRU 240、失败记账不重试）：**差「变速后按 speed/scale 重取」与「最近邻命中」两条能力**——若做变速，缩略图必须跟随 speed 维度，这条进 TimelineThumbnailStore 的能力池。

**一个实战坑（头文件注释原文）**：`其轨道组件`——「这里需要使用 UI 上的时间，实际的 context.currentTime 与 UI 时间可能存在 1 帧的时间差」。吸附/选中判定用 UI 时间而非引擎当前时间。我们 timescale=60000 做手势 ↔ RationalTime 换算时同理：**取整方向与帧对齐纪律要写进 `TimelineLayout` 换算约定**（pitfalls 候选）。

**自研路线确认（传哲 2026-10-11）**：借鉴思路 + 自研实现，不走反汇编。边界维持 RESEARCH-012 §1.5.7 分级：**公开头文件 / 资源 JSON / 符号表元数据层可继续挖（已饱和），反汇编还原实现逻辑不做**。依据：① 思路层证据已够——该厂商把手势状态字段全写进了公开头文件（panSelectedCell / longPressSnapCell / 3 个 DisplayLink / edgeRange / attachThreshold…），机制设计无需求助反汇编；② 反汇编多拿到的只有算法常数与实现细节，而手感参数本就要按自家产品调、且双方架构不同（其 RAC+OC+静态库 vs 我们 C++ core+Command 栈+SwiftUI）逐行还原的逻辑搬不过来——性价比趋零；③ 法律上交互机制/架构思路属思想层不受版权保护，代码表达受保护，独立自研是安全侧，反汇编产出再"照着写"会把独立开发变成衍生风险。本文 §2.5 的机制清单即自研的需求规格输入，实现归 `TrackInteraction` reducer 与 `TimelineLayout`（§5.1）。

---

## 3. 提炼：对本项目最有价值的几条经验（不照抄）

1. **面板配置驱动（字节 其创作 SDK）** —— RESEARCH-012 已判定这是"我们当前面板是代码写死"的**最大 gap**。建议落 LIB/Editor 域 SPEC：面板 = 值类型 `PanelDescriptor`（id + 标题 i18n Key + 图标 Key + 子项列表 + 宿主形态偏好），由注册表装配，换肤/增删面板不改业务视图。
2. **命令栈撤销重做（我们有，阿里云开源版没有）** —— 守住 ADR-0012，别为"对齐开源"砍掉它。
3. **轨道操作语义（Flowblade）** —— 插入(Insert)/覆盖(Overwrite) 双模式 + 磁吸防空隙；clip↔clip 吸附/对齐是专业编辑器标配，当前项目完全缺失。
4. **必备轨道操作清单** —— 删片段、删轨、分割(split)、左边缘 trim（改 source_in）、锁定/静音/可见、多选、clip↔clip 吸附。当前项目这 7 项里**删/分割/锁定静音/多选/吸附全缺**，删片段与删轨的 core `ICommand` 已写好却**未暴露 C ABI**（能力下沉未接线）。
5. **桌面 NLE 面板范式（Mac 面）** —— 常驻 Inspector（按 Video/Audio/Color/Transform 域分组）+ 顶部工具栏 + 菜单命令 + 可拖分隔条 + 多窗口 + 快捷键全表；布局可重排/可持久化（Shotcut dockable 思路）。

---

## 4. 本项目现状核对（基于代码探查 + 模块册）

### 4.1 两套时间轴实现的"真问题"
- 现状：Mac/横屏 = `EditorTimelineView`（SwiftUI 单 Canvas）；iOS 竖屏 = `EditorTimelineUIView`/`TimelineContentView`（UIKit，`ADR-0024`）。
- **几何（`TimelineLayout`）与缩略图（`TimelineThumbnails`）已共享** —— 这部分是对的。
- **真问题：手势解析 / 命中后本地预览 / commit 逻辑是两份**（`EditorTimelineView.commit` vs `EditorViewController.commitDrag`），注释反复强调"语义逐字一致"恰恰说明维护负担。
- 纪律判定：ARCH-005 允许"UI 不跨平台共享，共享会话状态与命令"——**两个薄展示层 OK**；但 ADR-0034「严禁两套渲染路径」指的是**两套发散的渲染/交互逻辑**。当前"两份交互实现"正踩在这条红线边缘（记忆：已第二次踩此坑，ADR-0014 代价）。**必须收敛为"一个交互纯逻辑 + 两薄展示层"**。

### 4.2 轨道操作能力缺口（UI 可用 vs core 现状）
| 操作 | UI 可用 | core 命令 | C ABI | 缺口性质 |
|---|---|---|---|---|
| 增轨 | 间接（导入自动） | ✅ | ✅ | — |
| 增片段 | ✅ | ✅ | ✅ | — |
| 移动 | ✅ | ✅ | ✅ | — |
| 右边缘 trim | ✅ | ✅ | ✅ | 只改 duration |
| 左边缘 trim（改 source_in） | ❌ | ❌（任务卡 D2） | — | 需新命令 |
| 删片段 | ❌ | ✅ RemoveClipCommand | ❌ **未接线** | 接线即可 |
| 删轨 | ❌ | ✅ RemoveTrackCommand | ❌ **未接线** | 接线即可 |
| 分割 split | ❌ | ❌ 不存在 | — | 需新命令 |
| 锁定/静音/可见 | ❌ | 模型 `enabled/muted` 已有（timeline.h:65-66），ABI `CQTrackInfo` 已回读（cq_sdk.h:202-203）| — | 需新 set 命令 + `locked` 字段（模型与 ABI 均缺）；`hidden` 与 `enabled` 语义疑似重叠，待拍板是否合并 |
| clip↔clip 吸附 | ❌ | — | — | 纯 UI + 几何 |
| 多选 | ❌ | — | — | 纯 UI 状态 |
| 缩放/帧栅格 scrub | ✅（UI 态） | — | — | 不进模型、不跨端 |

> 结论：先**接线**（remove clip/track ABI）即可解锁删片段/删轨；split/左trim/锁静音可见需新 core 命令 + 模型字段 + ABI；吸附/多选是纯 UI 状态机（不碰 core）。

### 4.3 面板体系
- 仅 `MediaLibraryPanel`（Mac 右栏 / iOS 底部 sheet）。Inspector、特效/转场/字幕/滤镜/音频面板**均未做（置灰占位）**。
- **零持久化**：`showMediaSheet`、`pixelsPerSecond`(缩放)、右栏宽度都是 `@State`，不跨会话、不跨端同步。专业软件应记忆工作区布局。
- 桌面范式（顶部工具栏/菜单命令/Inspector/多窗口）基本未落地（仅系统自动把 Cmd+Z 收进 Edit 菜单）。

---

## 5. 优化方案（iOS + Mac 分述）

### 5.1 交互逻辑统一（消除双份手势/commit）— P0
- 抽 **`TrackInteraction` 纯状态机**（值类型 reducer）：输入 = 归一化手势事件（tapAt(x,y)/dragDelta/pinch(anchor)/longPress）；输出 = 渲染态（`ClipDrag`/`ClipPreviewOverride`/scrub/缩放）+ 待提交命令。
- 两个展示层只做：①把平台手势翻译为归一化事件喂入 reducer；②照 reducer 的渲染态自绘。几何换算仍走共享 `TimelineLayout`，缩略图走 `TimelineThumbnails`。
- **事件形态对齐 其轨道 UI 组件库 实证（§2.5）**：拖拽三相 begin/changed/end（Cell 的 clipPanBegin/Changed/End 同构）+ 位置语义（左把手/右把手/中间）+ **方向维度（含跨轨上下）**；吸附输出采用「候选点集 + 方向 + 阈值」三要素（`其轨道组件` 同构），纯函数可单测。
- 收益：加 split/多选/吸附只改一份逻辑；彻底消除"语义逐字一致"的漂移风险；满足 ADR-0034 单一渲染/交互逻辑。
- 文件落点：`Timeline/TrackInteraction.swift`（新，纯逻辑可单测，参照 `TimelineLayout` 的纯函数纪律）。

### 5.2 补齐轨道操作 + ABI 接线 — P0/P1
- **接线（P0，不动 core）**：在 `cq_sdk.h` 增加 `cq_session_remove_clip` / `cq_session_remove_track`（绑定层 `Timeline.swift` 加 `removeClip/removeTrack` → `EditorViewModel`），解锁删片段/删轨。属热点文件改动，**走集成机统一落 `cq_sdk.h`**（PLAN-三线并行 §3）。
- **新命令（P1）**：`SplitClipCommand`（播放头处分割，应为**单条原子命令**以对齐 ADR-0012 命令栈一致性）、`TrimClipLeftCommand`（改 source_in；Spec 时需辨析"改 source_in = 内容窗滑动（slip）"vs"改 start = 边缘推移"两种语义，对标 App/对标 App的左 trim 属前者）、`SetTrackStateCommand`（locked/muted/visible）。**模型字段现状已核（2026-10-11）**：`Track.enabled/muted` 已在 core（timeline.h:65-66）且 `CQTrackInfo` 已回读（cq_sdk.h:202-203），真正要新增的只有 `locked` 字段（core + ABI）+ set 命令；`hidden` 建议与 `enabled` 合并（enabled=false 即不参与合成/不可见），避免同义双字段。
- **纯 UI 状态（P1，不碰 core）**：多选（`Set<ClipID>` 本地态）、clip↔clip 吸附（`TimelineLayout` 加 `snapCandidates`，拖拽结束前高亮吸附点）。

### 5.3 面板框架（配置驱动 + 三宿主形态 + 持久化）— P1

> **与既有 spec 的关系（2026-10-11 补，防撞车）**：`docs/specs/UIA-019-统一面板框架与四端布局.md`（v1.0，2026-10-04）已定义了运行时层——`PanelRoute` 状态机（唯一开关入口、同屏至多一个一级面板）、`PanelHost` 自适应容器（sheet ⇄ inspector 门控）、`PanelKit` 控件库。本节的 `PanelDescriptor`/`PanelRegistry` 不是另起炉灶，而是 UIA-019 之上的**数据声明层扩展**：Registry 产出 descriptor（含宿主偏好），PanelRoute 的开关门控与 PanelHost 的容器装配从 descriptor 读取——"面板是什么"（数据，本节新增）与"面板怎么开、怎么摆"（行为，UIA-019 已定）分层。UIA-019 立项时两者应合并为一份设计，避免本项目已发生两次的撞号/撞设计代价（P80/P81）。
- 引入 **`PanelDescriptor`**（值类型）+ **`PanelRegistry`**（注册表）：每个面板声明 id / 标题 i18n Key / 图标 Key / 子项 / 宿主偏好（`.inspectorRight` / `.bottomSheet` / `.contextBar`）。视图工厂按 id 返回 SwiftUI 视图。
- 三宿主形态（对齐 RESEARCH-007「编辑页八律」+ ARCH-005 两端不共享 UI）：
  - **Mac**：右栏常驻 Inspector（按 Video/Audio/Color/Transform 分组），顶栏工具 + 菜单命令 + 快捷键；轨道头含 锁/静音/可见 开关。
  - **iOS 竖屏**：对标 App 定式——**一级工具栏 ↔ 片段编辑条同槽替换**（选中片段→底部编辑条：分割/删除/静音/复制/音量/速度）；素材/更多走底部 sheet（detents）。
  - **iOS 横屏**：同构右栏（与 Mac 共用 PanelDescriptor，视图分写）。
- **持久化（P1）**：工作区布局（右栏宽度、面板开关、缩放级别 `pixelsPerSecond`、选中面板）写入 `UserDefaults`（独立 suite 便于测试，参照 Player 域 `cq.player.*` 做法）；多窗口下以主窗口为准。
- 配置驱动换肤/增删面板不改业务视图 —— 直接对齐字节 其创作 SDK 的最大 gap。

### 5.4 平台差异化轨道操作 UX
- **iOS（单焦点抽屉范式，ADR-0034 §6）**：长按"拿起"片段（其轨道 UI 组件库 同款 Pan/LongPress 双动作）、双指缩放时间线、边缘 trim、空白平移 scrub；多选=长按进入多选模式批量拖拽/删除；分割=播放头处一键分割（底部编辑条，其轨道 UI 组件库 头文件证实分割不在轨道区手势里）。**补三条该厂商实证的必备手感（§2.5）**：拖片段至时间线边缘自动滚动（速度随偏移渐进）、双击片段进属性、吸附命中与模式切换给触觉反馈。不堆常驻侧栏。
- **macOS（桌面专业范式）**：常驻 Inspector + 顶部工具栏 + 菜单命令（Edit/View/Clip/Track）+ 多窗口（编辑器 + 独立播放器已存在）+ 快捷键全表（Space 播放、⌘Z/⇧⌘Z、⌘X/⌘C/⌘V 片段、⌘L 锁定、⌘M 静音、←→ 逐帧、⌥←→ 跳片段边界）+ 拖拽导入（已有 Player 域 `dropDestination` 先例）；轨道头锁/静音/可见开关。

---

## 6. 落地顺序（地基先行，分批；与既有卡对齐）

> 不与既有占号冲突：UIA-030（多轨时间线 UI：增删/排序/静音锁定，Z序=轨序，依赖 UIA-035+RENDER-011）、UIA-028/029（素材/草稿页）、UIA-031（导出面板）、RENDER-011（多轨合成）、PROJ-001（草稿序列化）。

| 优先级 | 内容 | 依赖 | 备注 |
|---|---|---|---|
| **P0** | 抽 `TrackInteraction` 纯逻辑，收敛双份手势/commit | 无 | 解 ADR-0034 红线，先动逻辑不动 UI 形态 |
| **P0** | 接线 remove clip/track ABI + ViewModel | 集成机落 `cq_sdk.h` | 解锁删片段/删轨，零 core 改动 |
| **P1** | 面板框架 `PanelDescriptor`+`PanelRegistry` + 三宿主 + 持久化 | UIA-019 状态机扩"工具栏槽位"（descriptor 作为其数据声明层，见 §5.3） | 对齐该厂商配置驱动 gap |
| **P1** | 新 core 命令：split / 左trim / track 状态 + ABI | 仅 `locked` 字段需新增（enabled/muted 已在，见 §5.2） | 里程碑：可分割/可锁静音 |
| **P1** | 纯 UI：多选 + clip↔clip 吸附 | 5.1 reducer | 不碰 core |
| **P2** | UIA-030 多轨 UI（增删/排序/静音锁定，Z序=轨序） | RENDER-011 多轨合成 | 多轨真正可见的前提 |
| **P2** | Mac 桌面范式收口（Inspector 分组/菜单/快捷键全表） | 面板框架 | 与 iOS 只共享 ViewModel+Command |
| **P2** | 素材库/草稿箱面板（UIA-028/029）+ 导出面板（UIA-031） | LIB/PROJ/EXPORT 域 | 面板框架的天然首个消费者 |

---

## 7. 风险与未决
- **双机/多 agent 写集**：`cq_sdk.h`、`TimelineLayout`、`AppEntry.swift` 是热点文件；ABI 改动+交互重构**必须集成机统一落**，开发机只提池条目（PLAN-三线并行 §3、ADR-0029/0030）。
- **RENDER-001 未落地**：多轨合成/预览收口是 UIA-030 的前置（PLAN §1 已记）；在 RENDER-011 前做多轨 UI 只是"能增删轨道但只画第一轨"，属半残，需同步排期。
- **验证债务**：UIA-037/038（缩略图/居中播放头/捏合缩放）的 `swift test` + iOS 构建**用户指示跳过未跑**（池 [6]），新交互逻辑上线前必须先补这套门禁。
- **手势时间 ↔ 引擎时间的帧对齐**：其轨道 UI 组件库 注释实证「context.currentTime 与 UI 时间可能存在 1 帧差」（§2.5）。我们 timescale=60000 下手势换算的取整方向与帧对齐纪律须写进 `TimelineLayout`，否则吸附/选中在拖拽中会出现 1 帧级跳动 [hypothesis，待 UIA 实测]。
- 阿里云/该厂商开源 UI 的"还行"印象需校准为：单层裁剪手感可借鉴，多轨范式不可对齐（见 §1）。
- 精确控件排布/手势手感待真机走查截图核对（RESEARCH-007 §6.2 遗留）。

## 8. 引用调研清单
- RESEARCH-004 拍摄与编辑 UI 主流方案 / RESEARCH-005 功能面板信息架构 / RESEARCH-007 顶级 App 操作逻辑 / RESEARCH-008 对标 App移动端范式 / RESEARCH-010 编辑功能对齐 / **RESEARCH-012 商用 SDK 竞品（该厂商 其创作 SDK × 阿里云 UGSV，源码核验，含 Panel_configs 字段级结构）** / **RESEARCH-012 §1.5.4 + 本文 §2.5（其轨道 UI 组件库@0.3.3 头文件级：轨道区交互机制 / 吸附三要素 / 缩略图管线 / 关键帧 UI）**
- **SPEC-UIA-019 统一面板框架与四端布局**（§5.3 PanelDescriptor 的运行时层前置：PanelRoute/PanelHost/PanelKit）
- ADR-0012（拖拽不提交/松手一条命令）/ ADR-0022（AVFoundation 域边界）/ ADR-0024（iOS 竖屏 UIKit）/ ADR-0034（严禁两套渲染路径、Mac/iOS 分端形态）
- 模块册 `ui-apple.md`（UIA-004/005/009/011/012/013/032/033/034~038 落地记录）
- PLAN-素材库草稿混排多轨（UIA-028~031、LIB/PROJ/EXPORT 占号）
