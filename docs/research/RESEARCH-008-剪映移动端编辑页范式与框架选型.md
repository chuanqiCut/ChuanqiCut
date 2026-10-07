# RESEARCH-008：剪映移动端编辑页范式复刻 + SwiftUI/UIKit 框架选型

> **编号让位说明**：本文原取号 **RESEARCH-006**，与播放器线「独立播放器内核与交互调研」撞号
> （RESEARCH-006 于 2026-10-05 同日被双线各自占用）。2026-10-07 传哲裁定**编辑器线让位**，
> 本文改号 **RESEARCH-008**；播放器调研保留 RESEARCH-006。

> 日期：2026-10-05 深夜
> 上游命题：用户真机走查反馈「播放很卡顿；界面依然丑；调研剪映移动端界面看能不能复刻；SwiftUI 难实现就改 UIKit」
> 上游调研：RESEARCH-004（§3.4 剪映范式骨架）、RESEARCH-005（面板 IA）
> 下游：ADR-0024（编辑页 UIKit 混合，已按用户授权立）、TASK-UIA-034（下一步）、播放流畅度验收
> **数字纪律**：第三方事实为公开资料转述 [E]；性能根因标注代码证据；真机占比未实测的标 hypothesis

---

## 1. 播放卡顿的根因（代码证据，按置信度排序）

| # | 根因 | 证据 | 定性 |
|---|---|---|---|
| 1 | **30Hz 全树重算**：`playhead` 是 EditorViewModel 的 @Published，播放时每秒发布 30 次；四个 Zone 全部 `@EnvironmentObject` 观察 → 每次发布**整个编辑器视图树 body 重算** | `AppEntry.tickPlayback`（`tickCount % 2 == 0 { playhead = now }`，文件头注释自证「变一次 SwiftUI 就要重算整个编辑器 body（时间线画布会跟着重绘）」） | 确定存在，真机占比 **hypothesis（大概率主因）** |
| 2 | **时间线 Canvas 全量重绘**：播放头移动 1px 也会重绘轨道/标尺/片段/文字（`context.resolve(Text)` 每次重解析） | `EditorTimelineView.draw` 单 Canvas 结构；布局 0.68ms/帧（500 片段，baselines）仅是几何，绘制+resolve 另计 | 确定存在 |
| 3 | **Timer+Task 驱动链**：60Hz `Timer` 每 tick 生成一个 `Task { @MainActor }`（分配 + actor hop ×60/s） | `startPlaybackLoop` | 确定存在，次要 |
| 4 | 解码管线单帧耗时 > 帧间隔（4K/HDR 素材 BGRA 转换 ~33MB/帧；60fps 素材需 60 帧/秒） | baselines：模拟器 1s 播放 requested=64 **rendered=17** coalesced=45（Intel 宿主）；真机数字未测 | **hypothesis，需真机 Instruments 剖面** |
| 5 | 首帧起步延迟（play→seek+解码 ~百 ms 才出画） | 泵异步语义 | 次要，观感问题 |

**结论**：#1/#2/#3 是 UI 层结构问题，随本次 UIKit 重建一并消除（display-link 驱动 + 分层重绘 + 传输状态隔离）；#4 必须真机剖面后再定（可能需要预览分辨率缩放管线，独立任务）。

## 2. 剪映移动端编辑页范式（复刻目标形状）

> 来源：RESEARCH-004 §3.4 + 本轮检索（华为云社区拆解、Influencer Marketing Hub、CapCut 官方教程、2025 改版讨论），详见 §8 来源。

```
┌─────────────────────────────┐
│ ✕ 关闭/存草稿   分辨率  ⏏导出 │ 顶栏（导出 = 唯一主按钮）
├─────────────────────────────┤
│                             │
│        预 览 区（~45%）      │ 单击=播放/暂停；播放时浮现
│                             │ 大播放钮+时间码，停止后隐去
├─────────────────────────────┤
│ ▂▄▆ 时间线（~25%）▂▄▆ 主轨   │ 主轨=缩略图条；下方音/字/贴纸轨行
│    ┃红色播放头（可拖）        │ 双指捏合=时间密度缩放；横滑=平移
├─────────────────────────────┤
│ ↩︎ ↪︎ │媒体 音频 文字 贴纸 画中画│ 一级工具栏（图标+字，横滑）
│  ↑选中片段时整条替换为二级：   │ 分割/变速/音量/动画/删除…
└─────────────────────────────┘
```

关键交互契约（复刻的最小集合）：
1. **单焦点 + 抽屉**：无常驻属性栏；二级功能一律底部替换条或半屏 sheet；
2. **时间线三手势**：横滑平移、捏合缩放（以双指中点为锚）、长按/点按选中片段 → 拖拽移动 / 右缘裁剪；
3. **预览单击播放暂停**（播放时浮现控件、空闲时隐去——「沉浸优先」）；
4. **播放头即真相**：拖时间线 = 拖播放头 = 预览逐帧跟随（scrub）；
5. 选中态语义：白色描边 + 底栏整体替换为二级操作。

## 3. 框架决策：SwiftUI vs UIKit（用户问「SwiftUI 难就改 UIKit」）

逐组件评估（针对**编辑页**，不是全 App）：

| 组件 | SwiftUI 现状/可行性 | UIKit |
|---|---|---|
| 布局/工具栏/抽屉 | 成熟（UIA-032 已落） | 成熟 |
| 预览 + MTKView | ✅ UIViewRepresentable 已封装 | ✅ 原生 |
| 播放驱动 | ⚠️ Timer+Task churn（根因 #3）；TimelineView(.animation) 受 iOS16 行为约束 | ✅ CADisplayLink 标准做法，60/120Hz 自适应 |
| 时间线显示 | ✅ Canvas 已有 | ✅ CALayer/自绘等价 |
| 时间线**手势** | ⚠️ 长按拖拽/捏合/轻扫互斥、velocity、吸附——能做但与框架对抗，回归成本高 | ✅ UIGestureRecognizer + UIScrollView 语义原生 |
| 每帧状态分发 | ❌ @Published 整树重算（根因 #1）——要修必须状态大拆分，等于跟框架对抗 | ✅ CADisplayLink 层内直接 setNeedsDisplay 指定 layer，零 SwiftUI 参与 |
| 缩略图/波形异步层（UIA-018） | ⚠️ 无细粒度失效控制 | ✅ 图层预取/降级可控 |

**结论（ADR-0024）：编辑页核心三件套换 UIKit，外层保持 SwiftUI。**
- 剪映/CapCut 本体即 UIKit [E]；上表 4 个 ⚠️/❌ 全部是「为流畅要跟 SwiftUI 对抗」的点，满足用户预设的「SwiftUI 比较难实现」条件；
- **不做全量 UIKit 化**：Home/相机/相册/智能成片向导保留 SwiftUI（既有资产，且不在卡顿路径上）；
- **EditorViewModel/Command 链路零改动**（ARCH-005：共享的是状态与命令，不是 UI 框架；红线 #5 在 UIKit 层同样成立：只 submit，不直改模型）；既有 TimelineLayout 纯函数几何直接复用（UIA-005 手势语义/ADR-0012 提交时机不变）；
- 装配：`EditorViewController`（UIKit）经 `UIViewControllerRepresentable` 挂进现有 `EditorScreen`。

## 4. 方案（第一期复刻范围）

### 4.1 目标结构

```
EditorScreen（SwiftUI 壳保留：初始化/错误页/DEBUG 钩子）
└ EditorViewController（UIKit，UIA-034）
   ├ PreviewContainerView：MTKView（既有 PreviewMTKView 复用）
   │   + 浮层控件（播放钮/时间码，播放态浮现）+ 单击手势
   ├ TimelineScrollView（UIScrollView + 自绘 CALayer，UIA-035）
   │   · 内容层 CALayer：轨道/片段/标尺（仅模型变化时重绘）
   │   · 播放头独立 CALayer：CADisplayLink 驱动 position（每帧只动一层）
   │   · 捏合缩放/长按拖拽/右缘裁剪（UIGestureRecognizer，几何=TimelineLayout 复用）
   ├ TransportView：时间码（CADisplayLink 内刷新 label，不经 SwiftUI）
   └ BottomToolbarView：一级工具 + 二级替换条（UIA-036）
```

### 4.2 性能预算（可判定验收）

- 播放期间主线程单帧 < 16ms（Instruments Time Profiler 走查，真机 iPhone 17 Pro）；
- 播放头移动只重绘播放头层（逻辑断言 + Reveal 走查）；
- 预览帧率 ≥ 泵渲染帧率（UI 不再是瓶颈）；
- 真机剖面（阶段 0）：泵 stats（requested/rendered/coalesced/nonOk）+ 单帧取帧耗时，回填 baselines，决定是否立「预览分辨率缩放」任务。

### 4.3 任务拆解建议（线 A，领号）

| 任务 | 范围 | 依赖 |
|---|---|---|
| UIA-034 | EditorViewController 骨架 + 三区 UIKit 容器 + SwiftUI 装配 | — |
| UIA-035 | 时间线 UIKit 自绘 + 手势 + display-link 播放头（卡顿修复主体） | UIA-034 |
| UIA-036 | 预览浮层/传输条 + 底部工具栏/二级条 | UIA-034 |
| UIA-037 | 时间线缩略图（原 UIA-018 内容并入，异步抽帧） | UIA-035 |

（macOS 惯例化、时间线视觉保留登记；时间线视觉被本方案吸收时在 BACKLOG 标注让位。原编号 UIA-021~024 已让位播放器线，2026-10-07 裁定改 034~037。）

## 5. 非目标

- 不复刻剪映的内容能力（转场库/特效库/素材市场/关键帧曲线）——只复刻**骨架与交互范式**；
- 不动 Command/Undo/Session 架构与内核；
- macOS 编辑页本轮不动（UIA-017 另行）；
- 不引第三方 UI 库（RESEARCH-004 §3.3 论证沿用）。

## 6. 开放问题（开工前定）

1. 真机性能剖面（阶段 0）做不做在 UIA-034 前？建议：做——半天工作量，决定 4K 素材是否需要预览缩放管线；
2. 缩略图抽帧的缓存策略（内存上界/预取窗口）——UIA-037 开工前定；
3. 二级工具栏第一批上哪些操作（建议：分割/删除/音量/变速，配合内核既有命令——**分割需要内核新命令，跨线提案给集成机**）。

## 7. 数字纪律声明

- 剪映行为细节来自公开教程/评测转述 [E]，验收以「复刻形状走查清单」为准，不承诺逐像素一致；
- 播放卡顿的真机占比未实测 [hypothesis]，阶段 0 剖面前不得把 #4 当结论。

## 8. 来源

- [Influencer Marketing Hub：What is CapCut（四组件结构）](https://influencermarketinghub.com/what-is-capcut/)
- [WikiHow：Edit Videos with CapCut（主工具栏移动端在底部）](https://www.wikihow.com/Edit-Videos-with-CapCut)
- [华为云社区：剪映App的界面与功能（轨道/播放头/缩放滑块拆解）](https://bbs.huaweicloud.com)
- [CapCut 官方新手教程（时间线选中→编辑选项交互）](https://www.capcut.com/resource/capcut-tutorial-for-beginners)
- 2025 移动端改版（新增 bottom menu）社区讨论 [E]（Facebook 用户帖，未逐一核verify）
- 本仓：RESEARCH-004 §3.4/§6.2、RESEARCH-005、baselines.md（sim 播放 stats）、AppEntry/EditorTimelineView 代码证据
