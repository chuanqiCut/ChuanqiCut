> **状态：✅ 已落地（2026-10-07，本集成机；时间线主体）**——iOS/mac 双壳 BUILD SUCCEEDED；
> Editor 包 swift test 36/36 零回归；模拟器冒烟（CQ_AUTO_ROUTE=editor）四区渲染截图验证。
> 真机走查（播放头流畅度/拖拽手感/<16ms）= TODO-POOL 条目 [3]，攒趟执行。

# TASK-UIA-035：时间线 UIKit 自绘 + 手势 + CADisplayLink 播放头（卡顿修复主体）

```yaml
id:          TASK-UIA-035
layer:       UI
goal:       时间线从「SwiftUI 单 Canvas 全量重绘」改为 UIScrollView + 分层 CALayer（播放头独立层），播放头移动仅更新播放头层
input:       [ADR-0024, ADR-0012（交互期不提交命令）, TimelineLayout 纯函数]
output:      [packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorTimelineUIView.swift]
write_set:   packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorTimelineUIView.swift
read_set:    Timeline/EditorTimelineView.swift（ClipDrag/提交语义对照）、Timeline/TimelineLayout.swift（几何唯一真源，复用）
deps:        [TASK-UIA-034]
acceptance:
  - 播放头移动仅更新 playheadLayer.path（CADisplayLink 直驱，SwiftUI 零参与）
  - 片段拖拽/右缘裁剪语义与 SwiftUI 版逐字一致（ADR-0012：拖拽中不提交，松手一条命令 + refreshFromKernel）
  - 既有测试零回归；主线程单帧 <16ms（真机走查项 → TODO-POOL）
verification:
  - Editor 包 swift test（TimelineInteractionTests/TimelineLayoutTests 仍绿）
  - 真机走查（攒池趟）
risk:    UIScrollView 原生 pan 与片段拖拽 pan 的识别边界（空白处让位滚动）——gestureRecognizerShouldBegin 命中测试分流
parallel:    false
```

## 实现要点
- 层结构：滚动内容 = 轨道行底色层 + 标尺层（ticks+CATextLayer）+ 逐片段容器层
  （backgroundColor+cornerRadius+border+CATextLayer，拖拽中换 timelineClipDragging）
  + **播放头独立 CAShapeLayer**（2px 全高线）。
- 手势：内容视图 pan + `gestureRecognizerShouldBegin` 命中测试——命中片段→片段拖拽
  （move/trimEnd 区域复用 TimelineLayout.hitTest），空白→返回 false 让 UIScrollView 滚动。
- 几何唯一真源仍是 TimelineLayout（scrollSeconds=0、viewport=contentSize 的绝对坐标形态）。
