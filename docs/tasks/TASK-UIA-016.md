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

# TASK-UIA-016：Theme 令牌扩展（增量；全量清扫另立批次）

> **状态：✅ 已落地（2026-10-05，本集成机）**——门禁数字与走查证据见 `docs/reviews/REVIEW-2026-10-05-UIA015-编辑页走查.md`、`.workbuddy/memory/2026-10-05.md`。

```yaml
id:          TASK-UIA-016
layer:       UI
goal:        为编辑页重构补齐所需语义常量（播放条/工具栏底色、accent、间距圆角阶梯），不做全仓裸 RGB 清扫
input:       [docs/specs/UIA-015-编辑页重构.md §4.2, RESEARCH-004 §6.0]
output:      [Theme.swift 增量常量]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Common/Theme.swift
read_set:    apps/apple/packages/SharedUI/Sources/SharedUI/**（只读引用点）
deps:        []
acceptance:
  - 新常量编译通过；既有引用点零回归（两平台编译）
  - Editor 域新增视图文件中不出现裸 RGB（grep 检查）
verification:
  - grep -rn 'Color(red:' apps/apple/packages/SharedUI/Sources/SharedUI/Editor/ | grep -v Theme || echo clean
  - 双平台 xcodebuild（同 TASK-UIA-020）
risk:        与其他任务同时改 Theme.swift 冲突 → 本卡写集独占 Theme.swift，UIA-015 只读消费
parallel:    true
```

## 背景
RESEARCH-004 §6.0：Theme 2.0 全量令牌清扫应"一次改净"；本卡只交付 UIA-015 所需的**增量**（避免一次大扫除阻塞用户可见修复），全量清扫登记 BACKLOG 待批。

## 实现要点
新增：`transportBackground`、`toolbarBackground`、`accent`（与 timelineClip 同族蓝）、`accentText`、间距阶梯 `Space`（4/8/12/16/24/32）、圆角阶梯 `Radius`（8/12/16/capsule）。既有常量一律不动。

## 验收
acceptance 两条。

## 回写
Theme 段落增补进 `.ai/modules/ui-apple.md`（若形状变化）。

---

<!-- ====== 以下为远端（播放器线）同号内容，待拆分 ====== -->

> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
# TASK-UIA-016：播放器系统级播控补完（章节 + PiP 占位态 + AirPlay）

> **状态**：✅ 代码落地（2026-10-05，Batch D；章节 API 形状已在本机 SDK 头文件
> 验证——`chapterMetadataGroups(bestMatchingPreferredLanguages:)` 无弃用标记）。
> 落地：协议 +`PlayerChapter`/+chapters；引擎装载任务（commonKeyTitle 提名、
> 同值广播）；进度条章节刻度 + moreMenu 章节菜单 + jumpToChapter 零容差跳转；
> PiP delegate（AVPictureInPictureControllerDelegate，@preconcurrency 手法同
> MetalPreviewView）→ isInPip 占位态；AirPlayRoutePicker（AVRoutePickerView 双平台
> representable，落 surface 域边界文件）。PlayerQueueTests +2 用例。
> 本机 parse 全绿；PiP delegate 线程断言与真机行为待构建机。

```yaml
id:          TASK-UIA-016
layer:       UI
goal:        含章节视频显示章节刻度并可跳转；进/出画中画有界面占位态；顶栏可呼出 AirPlay 路由
input:       [docs/specs/UIA-020-独立视频播放器.md, docs/tasks/PLAN-播放器进阶.md P1, docs/research/RESEARCH-006-独立播放器内核与交互调研.md]
output:      [Player 域改动（协议 +chapters、引擎装载、进度条刻度、章节菜单、PiP delegate、AirPlay 入口）, PlayerTests 追加]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/**, apps/apple/packages/SharedUI/Tests/SharedUITests/PlayerTests.swift
read_set:    [docs/CODESTYLE.md, .ai/modules/ui-apple.md]
deps:        [TASK-UIA-015]   # 构建机门禁 PASS
acceptance:
  - 含章节元数据的视频：进度条显示章节分段刻度；moreMenu 出现章节子菜单；跳转落点与章节起点一致（stub 测试断言 seek）
  - 进入 PiP：画面区显示"正在画中画"占位文案；退出恢复画面；VM 有 isInPip 状态且被 delegate 驱动
  - 顶栏 AirPlay 图标可呼出系统路由选择器（AVRoutePickerView 桥接）
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - 构建机：双平台 xcodebuild（0 error 0 警告）
  - 真机：章节跳转 / PiP 进出 / AirPlay 路由逐项可观察
risk:        AVAsset 章节 API 的 async 形状无法本机验证（hypothesis）；AVPictureInPictureControllerDelegate 为 ObjC 协议，@MainActor 一致性需构建机确认（手法同 PreviewMTKView 注释）
parallel:    false
```

## 实现要点
- 协议增量：`chapters: [PlayerChapter(start:name:)]` + `jumpToChapter(id:)`（PlayerChapter 纯值类型，同 PlayerTrackOption 模式）。
- 章节 = AVAsset chapterMetadataGroups 异步装载 → 同值状态广播同步 VM（与轨道同机制）。
- PiP：PlayerPipCoordinator 成 controller.delegate，didStart/DidStop → VM.isInPip；PlayerScreen 据此盖占位层。
- AirPlay：`AVRoutePickerView` 包一层 representable（Player 域边界内文件）。

## 回写
- 模块文档 ui-apple.md 追加节；baselines 补"章节装载耗时 未实测"；新坑记 pitfalls（P60+）。
