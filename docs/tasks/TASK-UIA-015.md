# ⚠️ 编号撞号告警（2026-10-06 双线同步时发现，待传哲拍板）

> **本文件当前混合了两个不同任务的卡**，因为它们各自独立占用了同一个 ID：
> 本机线（编辑器/媒体线）与远端线（播放器线）长期分叉，取号时未能核对对方已用号。
> 这是 ADR-0019 §4「取号前必须 `git fetch` 核对远端已用号」要防的情形，
> 本次因双线长期未同步而实际发生。
>
> **处置原则（既定）**：改动面小的一侧让位。本文件保留两侧内容，
> **不擅自重命名**——重命名会波及代码注释、README 登记与 BACKLOG，需人工裁定。
>
> 上半部分 = 本地线内容；下半部分 = 远端（播放器线）内容。裁定后请拆成两张卡并更新登记。

---

# TASK-UIA-015：iOS 编辑页重构（剪映式单焦点 + 抽屉）

> **状态：✅ 已落地（2026-10-05，本集成机）**——门禁数字与走查证据见 `docs/reviews/REVIEW-2026-10-05-UIA015-编辑页走查.md`、`.workbuddy/memory/2026-10-05.md`。

```yaml
id:          TASK-UIA-015
layer:       UI
goal:        iOS 竖屏编辑页改为"预览最大化 + 播放控制条 + 时间线 + 底部工具栏 + 媒体抽屉"，消除桌面三区与调试元素外露
input:       [docs/specs/UIA-015-编辑页重构.md, RESEARCH-004 §3.4/§6.2, RESEARCH-005（上位面板框架，仅参考）]
output:      [Editor 域视图重组 + MediaSheet/TransportBar/BottomToolbar 三新文件 + DEBUG 直进钩子]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Editor/EditorView.swift、EditorLayout.swift、
             PreviewZone.swift（空态/点按增强）、TimelineZone.swift、PropertyPanelZone.swift（删）、
             MediaSheet.swift（新，含 PhotoLibraryImporter 胶水迁移）、
             EditorTransportBar.swift（新）、EditorBottomToolbar.swift（新）、
             apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift（增量：timecode 只读计算）、
             apps/apple/ios/iOSApp/ChuanqiCutApp.swift（DEBUG 钩子）
read_set:    Common/Theme.swift（UIA-016 产出，只读）、AppEntry.swift（只读）、Timeline/*（只读）、
             MediaPicker/*（只读，AlbumPickerScreen 挂载迁移）
deps:        [TASK-UIA-020, TASK-UIA-016]
acceptance:
  - iOS 竖屏走查清单（SPEC §5-4/5-5）：预览弹性满/播放条/时间线 140pt/底部工具栏/媒体抽屉半屏/点按预览切换播放/空态引导/导出置灰/无 v\d+ 调试文本 —— 模拟器截图存 docs/reviews/
  - macOS 布局行为等价（HSplitView 三区保留，右栏嵌媒体库内容），既有 Cmd+Z/Cmd+Shift+Z 不回归
  - 既有 SharedUI 全量测试零回归（TimelineInteractionTests/PhotoImportTests 等）
  - 双平台编译零错误
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - 双平台 xcodebuild（同 TASK-UIA-020）
  - xcrun simctl launch（CQ_DEMO_VIDEO + CQ_AUTO_ROUTE=editor）+ 截图走查
risk:        HomeView.swift 是 AIEDIT-008 高冲突文件 → 本卡不碰 HomeView，DEBUG 直进钩子放 ChuanqiCutApp.swift（未列热点，AIEDIT-008 开工时若冲突让位）；新文件后必须 pod install（P34）
parallel:    false  # 串行于 020/016 之后
```

## 背景
SPEC-UIA-015 §1 症状 1/3/4/5：桌面三区硬切、播放入口弱、调试元素外露、无时间码/空态引导。布局范式对齐剪映（RESEARCH-004 §3.4）。

## 实现要点
1. **EditorView**（iOS compact）：`VStack{ PreviewZone(弹性) / EditorTransportBar / 时间线(140pt) / EditorBottomToolbar }`；regular 宽度沿用现 macOS 同构横排（UIA-017 再惯例化）。平台差异仍收敛在 `EditorLayout.swift`。
2. **PreviewZone**：加点按手势 → `viewModel.togglePlayback()`；空时间线显示引导视图（标题 + 「导入素材开始创作」+ 主按钮开媒体抽屉）。
3. **EditorTransportBar**：播放/暂停（复用 `togglePlayback`）+ 时间码 `当前/总时长`（ViewModel 新增 `timecodeText`，有理数→字符串换算在 VM，红线 #4）。
4. **EditorBottomToolbar**：撤销/重做（迁移自 TimelineZone）+ 工具位「媒体/音频/文字/特效」——媒体开抽屉，其余 disabled + 标注；DEBUG 版本号移入 `#if DEBUG`。
5. **MediaSheet**：PropertyPanelZone 的素材库能力整体迁移（fileImporter + AlbumPickerScreen sheet + 列表/失效标记/错误汇总）；detents `[.medium, .large]`；macOS 固定窗口（UIA-013 同款处理）。PropertyPanelZone 删除，macOS 右栏改嵌 MediaSheet 内容（行为等价）。
6. **DEBUG 直进钩子**：ChuanqiCutApp `init` 读 `CQ_AUTO_ROUTE=editor`（DEBUG only）→ WindowGroup 直挂 `EditorScreen()`，绕过首页 —— 供模拟器截图走查与未来冒烟（与 CQ_DEMO_VIDEO 同模式）。
7. 红线对照：#1 无业务逻辑进 UI；#4 时间码换算用 RationalTime；#5 点按暂停走既有 togglePlayback；#8 批量导入条间 yield 语义原样保留。

## 验收
acceptance 四条；走查截图归档 `docs/reviews/REVIEW-2026-10-05-UIA015-编辑页走查.md`。

## 回写
`.ai/modules/ui-apple.md` 增补 UIA-015 落地段（结构图 + 文件清单）；pitfalls 记录新坑；HANDOFF 或工作日志登记真机走查待办（开放问题 §7-1）。

---

<!-- ====== 以下为远端（播放器线）同号内容，待拆分 ====== -->

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
  - swift test（SharedUI）PlayerTests 全绿（MVP 8 + V1 批次 6 + V1 收尾 3 = 17 用例）：拖动不 seek/松手一次零容差 seek 且恢复静音；skip 越界钳制；倍速透传；播完停止；时间码格式化；逐帧步进帧时长；长按倍速松手恢复；循环续播；A-B 回跳/短区间取消/区间外清除；倍速记忆；换片复位
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
| 8 | **第二轮（V1 批次，同日）**：长按倍速 2x（PickerFeedback 触觉）、单片循环 + A-B 循环（三态轮转/区间标记/区间外自动清除/播完回 A）、倍速跨会话记忆（UserDefaults 注入）、缩略图批量预热（≤24 桶错峰）、换片 swapMedia + macOS 拖放打开 | ✅ |
| 9 | 第二轮测试（+6 用例：boost 恢复/循环续播/AB 回跳/AB 短区间取消/区间外清除/倍速记忆/换片复位） | ✅ |
| 10 | **第三轮（V1 收尾，同日）**：音轨/字幕选择（PlayerEngine 协议扩展 +4 属性 +2 动作；AVMediaSelectionGroup 装载后发布、组内下标为 id、nil=默认/关闭；moreMenu 子菜单）、双击步长可设 5/10/15/30s（持久化，skip 按钮图标随步长变） | ✅ |
| 11 | 第三轮测试（轨道列表同步/选择透传/步长持久化） | ✅ |

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
