# TASK-UIA-015：独立视频播放器 MVP（伞任务）

```yaml
id:          TASK-UIA-015
layer:       UI
goal:        交付独立文件播放器 MVP——SharedUI/Player 新域：PlayerEngine 接缝 + AVPlayerEngine + 自研控制层，iOS/macOS 双端装配
input:       [docs/specs/UIA-020-独立视频播放器.md, docs/decisions/ADR-0022-独立播放器AVPlayer过渡与内核演进接缝.md, docs/research/RESEARCH-006-独立播放器内核与交互调研.md, .ai/modules/ui-apple.md]
output:      [SharedUI/Player/ 7 文件, Tests/SharedUITests/PlayerTests.swift, HomeView 入口, MacApp 窗口, ios/project.yml 后台模式, HANDOFF-006]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/**, apps/apple/packages/SharedUI/Tests/SharedUITests/PlayerTests.swift, apps/apple/ios/iOSApp/HomeView.swift, apps/apple/mac/MacApp/ChuanqiCutMacApp.swift, apps/apple/ios/project.yml, docs/research/RESEARCH-006*, docs/specs/UIA-020*, docs/decisions/ADR-0022*, docs/tasks/TASK-UIA-015.md, docs/tasks/TASK-BACKLOG.md, docs/tasks/README.md, docs/handoff/HANDOFF-006*, .ai/modules/ui-apple.md, .ai/memory/baselines.md, .workbuddy/memory/2026-10-05.md, .workbuddy/memory/MEMORY.md
read_set:    [docs/CODESTYLE.md, .ai/memory/pitfalls.md, .ai/modules/preview.md, bindings/swift/Sources/ChuanqiCut/Player.swift, SharedUI/AppEntry.swift, SharedUI/Editor/MetalPreviewView.swift]
deps:        []   # UIA-014 已收口；与在飞任务写集不相交
acceptance:
  - swift test（SharedUI）PlayerTests 全绿：拖动不 seek/松手一次零容差 seek 且恢复静音；skip 越界钳制；倍速透传；播完停止；时间码格式化；逐帧步进帧时长
  - 构建机 xcodebuild iOSApp + MacApp 0 error、项目代码 0 警告（Swift 6 严格并发）
  - 行为清单（SPEC-UIA-020 §6.4）真机/构建机逐项可观察通过
  - 既有 SharedUI 测试套（PlaybackTests/AlbumPickerTests 等）不回归
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox        # 构建机
  - xcodegen generate && xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp  # 构建机
  - tools/ci/run_gate.sh                                                   # 构建机全量
  - for f in Player/*.swift; do swiftc -parse "$f"; done                   # 本机静态（Swift 5.5 仅语法）
  - python3 tools/ai/linkcheck_docs.py                                     # 本机
risk:       AVAssetImageGenerator async API 的 Swift 6 Sendable 标注完整性未在本机验证（hypothesis）→ 构建机编译确认；AVPlayer seek 精度/起播延迟未实测 → 真机回填 baselines；iOS 专属分支（PiP/亮度/转屏）是 macOS 验证盲区（P49）→ 人工 iOS 视角审查 + 构建机 typecheck
parallel:   false   # 伞任务一次成域，子步骤串行（同文件族）
```

## 背景

支线任务（用户 2026-10-05 提出当晚交付 MVP）：独立播放器，预览导出成片 + 播放任意本地视频。自研预览线无声（PALA-030 未实现），MVP 内核走 AVPlayer 过渡 + 协议接缝（ADR-0022）。媒体管线分析见本文末尾。

## 子步骤

| # | 内容 | 状态 |
|---|---|---|
| 1 | RESEARCH-006 + SPEC-UIA-020 + ADR-0022 | ✅ |
| 2 | PlayerEngine 接缝 + AVPlayerEngine 实现 | ✅ |
| 3 | PlayerViewModel 状态机 + PlayerScreen/Controls 界面 | ✅ |
| 4 | VideoThumbnailLoader（LRU ≤120 + 按秒去重） | ✅ |
| 5 | 平台接线：HomeView 入口 / MacApp 窗口 / project.yml 后台音频 | ✅ |
| 6 | PlayerTests（stub 引擎测状态机纯逻辑） | ✅ |
| 7 | 本机静态验证 + 回写（modules/baselines/workbuddy/HANDOFF） | ✅（门禁数字待构建机） |

## 实现要点

- 接缝：`@MainActor protocol PlayerEngine`；KVO/通知一律 `Task { @MainActor }` 跳线程（同 AppEntry 手法）。
- 画面 sink 临时与 `AVPlayer` 类型耦合（ADR-0022 已登记）；控制层/VM/App target 禁 import AVFoundation。
- 缩略图按秒取桶 + LRU 上界 120 张；失败静默降级为纯时间气泡。
- macOS 键盘走 `.onKeyPress`（macOS 14+，域内 `#if os(macOS)`）；iOS 亮度/音量分区上下滑、`requestGeometryUpdate` 转横屏、PiP 均 `#if os(iOS)`。
- 进度条无障碍：`.accessibilityAdjustableAction` ±10s + 中文 value 播报。

## 媒体管线分析（cq-media-pipeline 六问）

1. **线程**：解码/音频全在 AVPlayer 内部线程；我们的代码全部 @MainActor，无自建播放线程；主线程零阻塞（缩略图 async 生成、时长 async load）。不触碰音频采样路径（无锁、无分配——没有自写音频代码）。
2. **时序**：UI 边界用 TimeInterval 秒（同绑定层惯例，文件播放器无时间线模型，RationalTime 不引入——已在 SPEC §4.1 声明）；引擎内 CMTime 由 AVFoundation 管理。
3. **内存**：缩略图缓存上界 120 张（LRU 驱逐），生成尺寸钳制 maximumSize 480；无帧缓存新增。
4. **取消**：`onDisappear → deactivate()` 取消自动隐藏 Task、缩略图 in-flight Task、移除时间观察者/KVO/通知，释放 security scope。
5. **错误码**：播放失败经 `PlayerEngineState.failed(String)` 上抛，UI 显示中文横幅 + 重试；能力缺失（如不支持的容器）不崩溃不静默。
6. **一致性**：与 RenderGraph 无交集（文件播放器，不渲染时间线）——成片画面一致性属 C++ session 阶段目标（ADR-0022 反转条件）；三端：MVP 仅 Apple，Android P1 按 ADR-0022 §5 同构。

新增单测：状态机（seek 时机/钳制/倍速/播完/步进）+ 时间码格式化（时序、内存、取消由 VM 逻辑与缓存上界覆盖；golden 不适用——无渲染产物）。

## 验收

见 YAML acceptance；行为清单见 SPEC-UIA-020 §6.4。

## 回写

- `.ai/modules/ui-apple.md`：新增"播放器域（UIA-015）"节 ✅
- `.ai/memory/baselines.md`：播放器节（全部"未实测"，待构建机/真机） ✅
- pitfalls：本轮无新坑（本机未编译，无踩坑现场；构建机编译后如有，下一轮记 P60+）
- workbuddy 日志 + MEMORY（AVFoundation 域边界长期规则） ✅
