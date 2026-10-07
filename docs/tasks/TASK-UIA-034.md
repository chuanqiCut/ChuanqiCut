> **状态：✅ 已落地（2026-10-07，本集成机；骨架）**——iOS/mac 双壳 BUILD SUCCEEDED；
> Editor 包 swift test 36/36 零回归；模拟器冒烟（CQ_AUTO_ROUTE=editor）四区渲染截图验证。
> 真机走查（播放头流畅度/拖拽手感/<16ms）= TODO-POOL 条目 [3]，攒趟执行。

# TASK-UIA-034：EditorViewController 骨架（三区 UIKit 容器 + SwiftUI 装配）

```yaml
id:          TASK-UIA-034
layer:       UI
goal:        ADR-0024 落地：iOS 竖屏编辑页核心三件套换 UIKit 容器（预览/传输条/时间线/工具栏竖排），SwiftUI 壳经 UIViewControllerRepresentable 挂载；macOS 维持 SwiftUI
input:       [ADR-0024, RESEARCH-008, TASK-UIA-032（SwiftUI 版布局基线）]
output:      [packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/**（新）, EditorCompactEditorView 装配, EditorLayout compact 槽位]
write_set:   packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorViewController.swift、UIKit/EditorCompactEditorView.swift、EditorLayout.swift（compact 槽位）、EditorView.swift（装配行）、docs/tasks/TASK-UIA-03{4,5,6}.md
read_set:    AppEntry.swift（EditorViewModel 公开面，只读）、MetalPreviewView.swift（PreviewMTKView 契约）、Timeline/*（几何纯函数）
deps:        []
acceptance:
  - 双平台编译零错误；既有 Editor 包测试零回归（测试不引用 UI 视图，已核）
  - VM 零改动（ADR-0024：命令链路不变；playhead 发布维持 15Hz，UIKit 每帧直读）
  - iOS 模拟器冒烟：CQ_AUTO_ROUTE=editor 进编辑器，四区渲染 + 空态引导可点
verification:
  - (cd packages/ChuanqiCutEditor && swift test --disable-sandbox --scratch-path <root>/build/spm/ChuanqiCutEditor)
  - iOS/mac 双 xcodebuild
risk:    PreviewMTKView 直嵌的 sync 时序（Combine 订阅 vs 首帧）——viewDidLoad 后先 sync 一次
parallel:    false
```

## 实现要点
- `EditorViewController`：UIStackView 竖排 [预览容器(弹性) / 传输条 44 / 时间线 140 / 工具栏 58]；
  全部新文件 `#if os(iOS)`（ADR-0024 决定 5：macOS 编辑页维持 SwiftUI）。
- 每帧驱动：CADisplayLink（播放中才跑）直读 `viewModel.playhead` → 播放头层 + 时间码，
  **不经 SwiftUI**；暂停态由 `$playhead` 订阅兜底更新（seek/单步）。
- 命令链路零改动：togglePlayback/moveClip/trimClip/undo/redo/refreshFromKernel 原样调用。
