> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
# TASK-UIA-016：播放器系统级播控补完（章节 + PiP 占位态 + AirPlay）

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
