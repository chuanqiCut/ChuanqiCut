> **状态：✅ 已落地（2026-10-07，本集成机；传输条+工具栏）**——iOS/mac 双壳 BUILD SUCCEEDED；
> Editor 包 swift test 36/36 零回归；模拟器冒烟（CQ_AUTO_ROUTE=editor）四区渲染截图验证。
> 真机走查（播放头流畅度/拖拽手感/<16ms）= TODO-POOL 条目 [3]，攒趟执行。

# TASK-UIA-036：预览浮层/传输条 + 底部工具栏（UIKit）

```yaml
id:          TASK-UIA-036
layer:       UI
goal:        传输条（播放/暂停 + 时间码）与底部工具栏（撤销/重做 + 一级工具位）的 UIKit 版；预览空态引导 + 点按播放
input:       [ADR-0024, RESEARCH-008 §2, TASK-UIA-032 走查清单]
output:      [packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/{EditorTransportBarView,EditorToolbarUIView}.swift, 预览空态/点按（并入 EditorViewController）]
write_set:   packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorTransportBarView.swift、UIKit/EditorToolbarUIView.swift
read_set:    EditorTransportBar.swift / EditorBottomToolbar.swift（SwiftUI 版形状对照）
deps:        [TASK-UIA-034]
acceptance:
  - 形状对齐 SwiftUI 已验收版（UIA-032 走查清单）：播放钮 32 圆/accent、时间码等宽、
    工具位图标+文字竖排、音频/文字/特效置灰占位、媒体开抽屉
  - 时间码由 CADisplayLink 直更（SwiftUI 零参与）
verification:
  - 双平台编译；模拟器冒烟（CQ_AUTO_ROUTE=editor）
risk:    无（纯搬运；二级替换条在音频/文字/特效实装时引入）
parallel:    false
```
