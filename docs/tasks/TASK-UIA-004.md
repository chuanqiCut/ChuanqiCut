# TASK-UIA-004：时间线自绘视图（Canvas，非组件堆叠）

```yaml
id:          TASK-UIA-004
layer:       UI
goal:        SharedUI 内用单 Canvas 自绘时间线（轨道/片段/标尺/播放头），数据来自 Session 真实模型
input:       [docs/tasks/TASK-BACKLOG.md §3.5 UIA-004, docs/tasks/TASK-MODEL-002.md, docs/tasks/TASK-UIA-009.md（读路径契约）, .ai/modules/ui-apple.md]
output:      [SharedUI/Timeline/TimelineView.swift（Canvas 自绘）, EditorViewModel 时间线状态, bindings/swift 查询封装, 测试]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Timeline/ + Editor/EditorView.swift + Editor/AppEntry.swift（ViewModel 扩展） + bindings/swift/Sources/ChuanqiCut/Session.swift（读查询封装） + bindings/swift/Sources/ChuanqiCut/Timeline.swift + 两侧测试
read_set:    core/include/cq/cq_sdk.h, core/include/cq/model/timeline.h, .ai/modules/{session,model}.md
deps:        [UIA-002 ✅, UIA-009 子步骤 1（读路径 C ABI，先行实施）]
acceptance:
  - 时间线显示 Session 真实 Timeline（提交命令后视图刷新显示片段；非静态假数据）
  - 单 Canvas 绘制全部实体（无「一片段一视图」的组件堆叠）
  - 布局计算 500 片段 < 16ms（XCTest measure，拖拽性能的静态部分；交互性能验收归 UIA-005）
  - 播放头随 viewModel.playhead 移动；标尺刻度随缩放自适应
  - macOS/iOS 双平台编译通过
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - cd bindings/swift && swift test --disable-sandbox
  - macOS App xcodebuild build + 启动冒烟
risk:  Canvas 的 draw 闭包在 SwiftUI 渲染管线内执行，帧耗时无法在 XCTest 稳定测量 ——
       验收只测布局纯函数耗时，滚动/拖拽实帧率归 UIA-005 真机验证；
       横向缩放/滚动的手势协商在 SwiftUI 里容易与系统手势打架，留调试余量。
parallel:    true（与 UIA-009 子步骤 2/3 串行：读路径契约先行；与内核侧无交集）
```

## 状态：已完成（2026-10-03，与 UIA-009 子步骤 1 同轮交付）

- 布局 500 片段 **0.663 ms/帧**（< 16ms 预算）；macOS App 编译 SUCCEEDED +
  启动冒烟（演示素材时间线/预览双可见，进程 7s 存活干净退出）
- 双门禁 36/36（含新 c_abi_session）；Swift 绑定 16/16；SharedUI 10/10
- 读路径依赖（UIA-009 子步骤 1）同轮完成：EditorModelState + 查询 ABI

## 背景

- BACKLOG §3.5：时间线**自绘**（非组件堆叠），验收「数百片段拖拽不掉帧」。
  拖拽交互在 UIA-005；本任务交付自绘底座 + 渲染性能的静态部分。
- 数据来源：UIA-009 子步骤 1 已提供 Session 级 Timeline 快照与查询 C ABI
  （`cq_session_query_tracks/clips`，无锁读不可变快照）——视图不造假数据。

## 实现要点

- **绘制**：SwiftUI `Canvas`（iOS 16+/macOS 可用）单次绘制：轨道背景行 → 片段圆角矩形
  （asset 标签截断）→ 标尺 → 播放头。几何计算抽成**纯函数** `TimelineLayout`
  （时间↔像素、clip→CGRect），可单测、可 measure。
- **缩放**：`pixelsPerSecond` 状态；滚轮/捏合手势改缩放（Mac 滚轮 + iOS Magnification）。
- **刷新**：EditorViewModel 订阅快照 observer（已有）→ 版本推进时重查询 → `@Published`
  时间线状态；Canvas 从状态数组绘制。
- **不做**：拖拽/裁剪/选择交互（UIA-005）、多轨合成显示语义（等 RENDER-001）、
  波形/缩略图（媒体分析任务）。

## 验收

1. SharedUI 测试：布局纯函数（时间↔像素往返、可见裁剪）+ 500 片段布局 < 16ms
2. 绑定测试：查询封装返回真实结构（含异步命令提交后的最终一致）
3. macOS App 冒烟：DEBUG 演示素材在时间线可见、播放头显示
