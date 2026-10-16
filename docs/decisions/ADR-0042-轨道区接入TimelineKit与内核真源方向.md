# ADR-0042：iOS 轨道区接入本地 TimelineKit，内核保持唯一数据真源

- **状态**：已批准（传哲 2026-10-15 命题：早期自绘轨道区作废，以 TimelineKit 这版为主，现有项目按它适配）
- **日期**：2026-10-15
- **相关**：UIA-044 / ADR-0024（编辑页 UIKit 混合）/ ADR-0034（不做临时方案、不做假功能）/ ADR-0041（SnapKit）/ pitfalls P134

## 背景

早期自绘轨道区（`EditorTimelineUIView` + `TimelineContentView`，UIA-035/037/038 累积）手写
CALayer 自绘、手写命中与手势、手写缩略图槽，功能与对标 App 差距大且每次改动都要动几何层。
本机另有独立演进的本地 CocoaPods 组件 `TimelineKit`（`/Users/zhuning/Documents/ChatGPT/zui`，
UIKit-only），已具备多轨道、标尺/播放头、吸附、移动/跨轨/裁剪、缩略图与波形 provider。

用户裁定：**以 TimelineKit 这版为主**，现有项目按它适配；轨道区与预览区、操作面板有联动，
三区必须统一。同时给出硬约束：内核仍是唯一数据真源，TimelineStore 的快照不得另行持久化，
不得改调试预览页冒充正式接入。

## 决策

1. **真实编辑页的轨道视图换成 TimelineKit**（iPhone 竖屏实际路径：
   `EditorScreen → EditorView → EditorLayoutContainer(compact) → EditorCompactEditorView
   → EditorViewController`）。原自绘 `EditorTimelineUIView.swift` **删除**（不保留第二套渲染
   路径，避免 ADR-0014 同款「两套渲染」坑）。iPad 横屏 / macOS 的 SwiftUI `EditorTimelineView`
   本轮**不动**（TimelineKit 是 UIKit-only，macOS 端物理上不可用），列为后续。
2. **新增适配层** `UIKit/TimelineKitAdapter.swift`：内核 `TrackInfo/ClipInfo/AssetInfo` + 帧率
   → `TimelineProject`；`UInt64 ⇄ String` ID 稳定互转；`RationalTime ⇄ TimelineTime` 有理数直搬。
3. **真源方向单向**：灌入 = 内核快照 → 重建 `TimelineStore` + `TimelineView`；
   回写 = `TimelineStore` 的 `.projectChanged` 是**唯一**回写入口，翻译成既有 `TrackIntent`
   → `TrackIntentApplier`（VM 命令 + `refreshFromKernel`）。**不做** Kit → 内核的反向持久化。
4. **翻译不了的命令一律回滚**：轨道排序 / 静音 / 锁定 / 轨内重排 / 增删轨 / 转场 / 关键帧等内核
   暂无对应 ABI 的命令，组件自我变更后立即按内核快照重灌（不留下「UI 变了内核没变」的假编辑）。
5. **缩放/选中/播放头由容器带走**：`TimelineStore` 没有「整体替换 project」入口、也没有新增媒体
   资产的命令，故按快照整体重建；zoom 由 `.zoomChanged` 记录并在重建时回填，避免每次模型变化
   把用户缩好的比例弹回默认。
6. **依赖隔离用子 spec**（见 P134）：`ChuanqiCutEditor` 拆 `Core`（默认，两端共用）与
   `TimelineKitTrack`（iOS 专属，含适配层/容器/调试预览 + TimelineKit 依赖）。iOS Podfile 引
   `ChuanqiCutEditor/TimelineKitTrack`，macOS Podfile 引默认 `Core`。

## 备选方案

- **增量 apply 命令逼近内核快照**：写不出来（媒体资产没有对应命令），且轨道顺序/片段增删
  组合极易漏 → 否决。
- **保留旧自绘轨道区做「备用」**：两条渲染路径（ADR-0014 已两次踩坑）→ 否决，直接删。
- **把 TimelineKit 依赖直接写进根 spec**：实测 macOS 端仍会解析 `s.ios.dependency`，导致
  mac `pod install` 整体失败 → 否决，改子 spec。
- **组件内部状态当真源（Kit → 内核 反向持久化）**：违背用户硬约束与红线 #5 → 否决。

## 影响与边界

- 三区联动**保持原链路不变**：选中 → `.selectClip` Intent → VM → 底栏分割/删除可用性 + 预览红框；
  播放头 → `onScrub` → `VM.setPlayhead` → 取帧泵 → 预览；播放中 VM 反向 `updatePlayhead` 推组件。
- 本轮**未做**：转场/关键帧/画布 item/蒙版映射；轨道静音/锁定/排序（内核缺写 ABI，池 [19] 同源）；
  额外手势与视觉优化；iPad 横屏与 macOS 轨道区统一。
- 组件每帧 `setCurrentTime` 会触发滚动 + `layoutVisibleContent`，播放期的实际开销**未实测**，
  列为真机问卷项（不得据此给阈值）。
