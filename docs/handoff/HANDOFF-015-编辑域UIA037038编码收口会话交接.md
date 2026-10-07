# HANDOFF-014：编辑域 UIA-037/038 编码收口会话交接（2026-10-07 深夜）

> 接手人开第一步前**必读本文件 + `.ai/modules/ui-apple.md` UIA-037/038 段**。
> 本轮特殊性：编码与提交发生在**同机双会话并行**窗口（见 pitfalls P86）——
> 本轮源码已随并行轮 ced6a00..8c726c9 入库，回写收口 = 04f2ef3。

## 当前状态（对着 commit 历史核过）

- **UIA-037（时间线缩略图）+ UIA-038（居中播放头/捏合缩放/帧精度）：编码完成，
  验证未跑**（用户 2026-10-07 指示跳过）——"编码完成"≠"验证通过"，任何性能说法
  都没有实测数字。
- 代码位置（全在 `ChuanqiCutEditor` Pod，HEAD 已含）：
  - 新域 `Sources/ChuanqiCutEditor/TimelineThumbnails.swift`（ClipFrameSampler /
    TimelineThumbnailStore / TimelineZoomMath）
  - `TimelineLayout.swift` 增 `anchorX`（默认 0 = 旧行为零回归锚）+ 标尺帧级候选
  - `UIKit/EditorTimelineUIView.swift` 重做（红条固定覆盖层 / scrub / pinch / 胶片槽）
  - `UIKit/EditorViewController.swift`、`EditorTimelineView.swift`（SwiftUI/macOS 同步重写）
  - `Tests/.../TimelineThumbnailTests.swift`（22 用例，**未执行**）

## 下一步（按序）

1. **池 [6] 第一优先**：Editor 包 `swift test --disable-sandbox`（22 新用例；Swift 6
   并发标注如 @Sendable 闭包捕获 CGImage 可能报错，报错按提示修）→ iOS 模拟器构建
   （UIKit 路径 macOS 侧不可见，P49）。
2. 真机并趟（池 [3]/[5]/[6]，iPhone 17 Pro，传哲操作）：scrub 跟手/捏合界限/帧级刻度/
   缩略图 ≥3 帧/主线程不卡；数字回填 baselines「UIA-037/038」段。
3. 池 [4] 全量门禁（**执行前先问传哲**，2026-10-07 规则）。
4. 更远（A 线）：UIA-028~031 / LIB 域（PLAN-素材库草稿混排多轨 §13）、AIEDIT 线
   （12 卡未开工，关键路径 001→005→007→008→009）。

## 装配形状（改时间线前必读）

- **居中播放头模型**：红条 = 固定覆盖层（不随内容滚动，播放中每帧开销 = 一次
  setContentOffset）；拖时间线 = scrub（scrollViewDidScroll → onScrub →
  VM.setPlayhead，isSyncingOffset 抑制程序化回环，isPlaying 时宿主忽略）；
  捏合 = 播放头为锚 → 状态快照 reload → 重新居中。片段拖拽语义不变（ADR-0012）。
- **双端分工**（UIA-038 定案，用户认可"可以分开写"）：共享纯逻辑 = TimelineLayout
  （anchorX 两形态：UIKit 内容坐标 anchorX=LEAD / SwiftUI 视口坐标
  scrollSeconds=播放头时刻）+ TimelineZoomMath + ClipFrameSampler +
  TimelineThumbnailStore；展示 = iOS UIKit / macOS SwiftUI Canvas。
- **AVFoundation 域边界**：只许出现在 `TimelineThumbnails.swift`（ADR-0022 决策 4
  Player 域先例的 Editor 域应用）——代码审查按此检查，视图层只消费 CGImage。
- **帧时长 = 30fps 常数 [E]**（`TimelineZoomMath.defaultFrameDuration`）：MEDIA 线
  透传真实帧率后替换；引用一切帧精度说法须带 [E]。
- SwiftUI Canvas 重绘依赖：`thumbnails.revision` 必须读进 body（Canvas 闭包不是
  view body，不建立依赖）。

## 坑（本轮新增/相关）

- **P86（新）**：同机双会话提交互吞——本轮案底；并行会话开工先 `git status` 甄别
  在途变更归属，提交前 staged diff 逐文件核对。
- P49（iOS 专属代码 macOS 不可见）、P45/P46（旧环境记录，注意甄别时点）、
  P22（SwiftUI 撞名，本视图仍叫 EditorTimelineView）。

## 记录索引

- 模块册：`.ai/modules/ui-apple.md`（任务表矫正 + UIA-037/038 段 + 门禁记录"未执行"）
- 任务卡：`docs/tasks/TASK-UIA-037.md` / `TASK-UIA-038.md`（038 含 SwiftUI 可行性定案）
- 池：`docs/tasks/TODO-POOL-门禁真机待办池.md` [4][5][6]
- baselines：`.ai/memory/baselines.md`「UIA-037/038」未实测段（本轮新增）
