> **状态：编码完成（2026-10-07，本集成机）——验证未执行（用户指示跳过）**。
> swift test（含 TimelineLayoutAnchorTests/TimelineZoomMathTests）+ iOS 模拟器构建 +
> 真机走查 = TODO-POOL 条目 [6]（与 UIA-037 同批）。未经编译与测试，勿引用任何"通过"结论。

# TASK-UIA-038：时间线居中播放头 + 捏合缩放 + 帧精度标尺（剪映式交互定版）

```yaml
id:          TASK-UIA-038
layer:       UI
goal:       红条恒在时间线视口中央（拖时间线 = 拖播放头）；轨道区捏合缩放（下界=全时长入视口，
            上界=一帧一槽宽）；时间轴精度下限=一帧；每片段至少展示三帧画面
input:       [ADR-0024（UIKit 时间线）, ADR-0012（片段拖拽语义不变）, 用户命题 2026-10-07]
output:       [packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/{TimelineLayout.swift, TimelineThumbnails.swift(TimelineZoomMath), EditorTimelineView.swift, UIKit/EditorTimelineUIView.swift, UIKit/EditorViewController.swift}]
write_set:   同 output（与 UIA-037 同批同线，串行修改）
read_set:    AppEntry.swift（setPlayhead/isPlaying）、Theme（playhead 色）
deps:        [TASK-UIA-035]
acceptance:
  - 红条恒在视口中央：播放/seek 程序化 contentOffset 跟随；拖动时间线 = scrub
    （scrollViewDidScroll → onScrub → VM.setPlayhead，帧栅格取整）；播放中不抢播放头
  - 捏合缩放以播放头为锚（时间不跳变）；界限 = TimelineZoomMath（纯函数，可单测）
  - 标尺刻度候选含帧级（1f/2f/5f），只在帧级间距下胜出，常规缩放行为不变（零回归锚）
  - 每片段缩略图 ≥3 帧（窄片段压缩槽宽保证三帧铺满）
  - 片段拖拽/右缘裁剪语义与 UIA-005 逐字一致（ADR-0012 不动）
verification:
  - Editor 包 swift test（新增 TimelineLayoutAnchorTests/TimelineZoomMathTests）
  - iOS 模拟器构建（UIKit 路径 macOS 不可见，P49）；真机走查 = TODO-POOL [6]
risk:    捏合期间几何全量重建的主线程开销（500 片段布局 0.663ms 量级 [E]，真机走查定案）；
         超短时间线 minPPS > maxPPS 的反向区间（clamp 以较小值封底）
parallel:    false
```

## SwiftUI 可行性定案（用户问询 2026-10-07）

**结论：纯逻辑一套共享，展示层双端分写。**

- **居中播放头**：iOS 上需要绑定 ScrollView contentOffset —— `onScrollGeometryChange`
  要 iOS 18、`scrollPosition` 要 iOS 17，部署目标 iOS 16 做不干净；UIKit
  `setContentOffset` 零障碍。macOS 侧本就是 Canvas + 手势（无 ScrollView），
  居中锚定只需把布局取 `scrollSeconds=播放头时刻、anchorX=视口宽/2` 形态。
- **捏合缩放**：SwiftUI MagnificationGesture 双端可用，但与拖拽/滚动并存的手势
  仲裁脆弱；UIKit UIPinchGestureRecognizer + 手动 offset 精确可控。
- **落法**：共享 = TimelineLayout（含 anchorX）+ TimelineZoomMath + ClipFrameSampler +
  TimelineThumbnailStore；分写 = iOS UIKit（EditorTimelineUIView，ADR-0024 既有方向）、
  macOS SwiftUI Canvas（EditorTimelineView）。正合 ARCH-005「共享状态与命令、
  不共享 UI」与用户「可以分开去写」的授权。

## 实现要点

- **TimelineLayout.anchorX**（默认 0 = 既有行为，零回归锚）：x(s) = anchorX +
  (s − scrollSeconds)·pps；visibleRange 按 anchor 两侧折算；playheadX ≡ anchorX。
  UIKit 形态 = 内容坐标（scrollSeconds=0、anchorX=LEAD=视口宽/2、viewport=contentSize）；
  SwiftUI 形态 = 视口坐标（scrollSeconds=播放头时刻、anchorX=视口宽/2）。
- **UIKit**：播放头从滚动内容**移出**为固定覆盖层（红条不再每帧改 path，播放中
  每帧开销 = 一次 setContentOffset）；scrollViewDidScroll → onScrub（isSyncingOffset
  抑制程序化回环；宿主在 isPlaying 时忽略 scrub）；UIPinchGestureRecognizer
  → clamp → reload（状态快照重建）→ syncOffset 重新居中。
- **SwiftUI**：pan 未命中片段 = scrub（锚定拖动起始播放头时刻）；Magnification 以
  simultaneousGesture 并入；`.task(id: SyncKey(version, pps, width, assetCount))`
  驱动缩略图请求；store.revision 读入 body 建立重绘依赖。
- **帧精度**：scrub 值 snapToFrame（30fps [E]，MEDIA 线透传真实帧率后替换）；
  标尺候选前置 1f/2f/5f。
