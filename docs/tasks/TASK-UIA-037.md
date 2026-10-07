> **状态：编码完成（2026-10-07，本集成机）——验证未执行（用户指示跳过）**。
> swift test（新增 22 用例）+ iOS 模拟器构建 + 真机走查 = TODO-POOL 条目 [6]（第一优先）；
> 实现要点见本卡与模块册 UIA-037/038 段。未经编译与测试，勿引用任何"通过"结论。

# TASK-UIA-037：时间线缩略图（异步抽帧 + 抽帧缓存）

```yaml
id:          TASK-UIA-037
layer:       UI
goal:       时间线片段显示素材源画面的胶片条（filmstrip）；抽帧全异步，主线程不解码（红线 #4 同族约束）
input:       [ADR-0024（UIKit 时间线）, ADR-0022 决策 4 先例（UI 域系统 API 豁免：AVFoundation 只许进抽帧加载器单文件）, VideoThumbnailLoader 模式（Player 域，按桶+LRU）, ClipInfo.sourceIn/sourceDuration]
output:       [packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/TimelineThumbnails.swift, Tests/ChuanqiCutEditorTests/TimelineThumbnailTests.swift]
write_set:   packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/{TimelineThumbnails.swift, UIKit/EditorTimelineUIView.swift, EditorTimelineView.swift, UIKit/EditorViewController.swift}
read_set:    TimelineLayout.swift（几何唯一真源）、AppEntry.swift（mediaLibrary/assetId→path）
deps:        [TASK-UIA-035]
acceptance:
  - 主线程不解码：抽帧经 AVAssetImageGenerator 异步 API（内部队列解码，同 Player 域 VideoThumbnailLoader 先例），完成回调才落主线程
  - 缩略图随片段可见：UIKit 路径（iOS 竖屏）逐片段胶片槽层；SwiftUI 路径（macOS/横屏）Canvas 同源绘制
  - 抽帧缓存：按 (assetId, 源秒桶) LRU，跨片段去重（同素材共享桶），上界钳制内存；并发解码有上限（不重建 AVURLAsset 风暴）
  - 采样几何为纯函数（可单测）：槽位数按片段宽换算、采样点在 [sourceIn, sourceIn+duration) 内单调、槽位→采样映射单调
  - 既有测试零回归（Editor 36 用例基线）
verification:
  - Editor 包 swift test --disable-sandbox（新增 TimelineThumbnailTests）
  - iOS 模拟器构建（UIKit 路径 macOS 侧编译不可见，P49）
  - 真机走查（攒池趟）：滚动/拖拽中缩略图出现、无主线程卡顿
risk:    长片段槽位数爆炸（>60 样本钳制 + 槽位复用样本图）；同 URL 并发请求风暴（并发上限 3 + in-flight 去重）
parallel:    false
```

## 实现要点

- **域边界**：AVFoundation 只许出现在 `TimelineThumbnails.swift`（对照 ADR-0022 决策 4
  的 Player 域先例；代码审查按此检查）。视图层只消费 `CGImage`。
- `ClipFrameSampler`（纯函数）：`thumbnailCount(forWidth:thumbnailWidth:)`（上界
  `maxSamplesPerClip = 60`）、`sampleSourceSeconds(sourceIn:span:count:)`（均匀采
  样，中点偏移，闭区间钳制）、`slotSampleIndex(slot:slots:samples:)`（槽位多于采样
  时相邻槽位复用同图）。
- `TimelineThumbnailStore`（@MainActor ObservableObject）：
  - 键 = `(assetId, bucket)`，bucket = 源秒 floor（1s 桶，同 Player 域粒度）——
    同素材多片段天然共享缓存；
  - in-flight 去重 + 失败记账（失败桶不重试，防风暴）；LRU 上界 240 张；
  - 并发解码上限 3（pending 队列 + 完成泵下一发）；
  - 抽帧 seam = 注入闭包（测试桩不碰 AVFoundation），默认实现按请求建
    AVURLAsset + AVAssetImageGenerator（maximumSize 钳制单张内存，tolerance 放宽换
    速度——胶片条不需帧精确，语义同 VideoThumbnailLoader §4.2）。
- **UIKit 接入**（EditorTimelineUIView/TimelineContentView）：片段容器层内铺槽位
  CALayer（masksToBounds 裁剪），完成回调 `applyThumbnails` 只写对应槽位
  `contents`（`contentGravity = resizeAspectFill`），素材名文字层压在最上层。
- **SwiftUI 接入**（EditorTimelineView）：同一 Store 经 `@StateObject` 持有；
  `revision` 变化驱动 Canvas 重绘；槽位图经 `Image(decorative:)` resolve 绘制。
