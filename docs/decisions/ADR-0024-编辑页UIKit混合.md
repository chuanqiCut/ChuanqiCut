# ADR-0024：编辑页核心三件套采用 UIKit（SwiftUI 外壳混合装配）

> **编号让位说明（2026-10-07）**：本 ADR 原取号 **ADR-0022**，与播放器线「独立播放器 AVPlayer
> 过渡」撞号（播放器侧 2026-10-05 先入库）。传哲裁定编辑器线让位，本 ADR 改发 **ADR-0024**；
> 播放器线保留 ADR-0022。

- 状态：已接受（2026-10-05，用户授权「SwiftUI 比较难实现就改 UIKit」+ RESEARCH-008 论证满足该条件）
- 关联：RESEARCH-008、ARCH-005（共享状态与命令，不共享 UI）、ADR-0012（交互期不提交命令）、ADR-0021
- 影响面：`apps/apple/packages/SharedUI/Sources/SharedUI/Editor/**`（新增 UIKit 域）、`apps/apple/ios/iOSApp/**`（装配）

## 背景

用户真机走查：播放卡顿 + 界面丑，要求复刻剪映移动端范式；询问 SwiftUI 难实现是否改 UIKit。
RESEARCH-008 诊断：播放卡顿的 UI 侧根因 = ① 30Hz `playhead` @Published 触发整树 body
重算（EnvironmentObject 粒度过粗）；② 时间线单 Canvas 全量重绘（含逐次文字 resolve）；
③ 60Hz Timer+Task 驱动链。三者要在 SwiftUI 内修到剪映级流畅 = TimelineView 行为约束 +
状态大拆分 + 手势细节对抗，成本高于直接使用 UIKit 的原生设施。

## 决定

1. **编辑页核心三件套用 UIKit 实现**：时间线（UIScrollView + 自绘 CALayer +
   CADisplayLink 播放头）、预览浮层（播放钮/时间码/单击手势）、底部工具栏（一级 +
   二级替换条）。经 `UIViewControllerRepresentable` 挂进现有 SwiftUI `EditorScreen`。
2. **外层保持 SwiftUI**：导航、首页、相机、相册、智能成片向导不动——不在卡顿路径上，
   且是既有资产。**不做全量 UIKit 化**。
3. **EditorViewModel / Command / Undo 链路零改动**：UIKit 层与 SwiftUI 层同样只经
   `submit()` 变更模型（红线 #5 不变）；`TimelineLayout` 纯函数几何与 ADR-0012
   交互期不提交命令的语义原样复用。
4. **每帧驱动不经 SwiftUI**：播放头 position、时间码 label 由 CADisplayLink 在
   UIKit 层内直接更新；`playhead` 的 @Published 发布降频为「状态同步」（10~15Hz
   或仅在暂停/交互结束时），不再承担逐帧渲染职责。
5. macOS 编辑页维持 SwiftUI（惯例化另行立项）；Android/鸿蒙按对应平台惯例，不共享 UI。

## 后果

- 正向：播放/scrub 流畅度由 display-link 保证；缩略图/波形异步层获得细粒度失效控制；
  与剪映同构的手势体系。
- 代价：编辑页出现两套 UI 栈并存（SwiftUI 壳 + UIKit 内容），团队需同时掌握；
  SharedUI 的「纯 SwiftUI」事实被打破（pitfalls/模块文档同步修订）。
- 反转条件：若 CADisplayLink + 图层方案在真机仍不达预算（<16ms），问题在渲染管线
  （单帧取帧耗时），届时拆「预览分辨率缩放」任务而不是回退 SwiftUI。

## 编号

集成机发号：原发 ADR-0022（当时已用至 0021），后因与播放器线同号撞车，2026-10-07 撞号裁定让位改发 **ADR-0024**（0022 归播放器线 AVPlayer 过渡）。
