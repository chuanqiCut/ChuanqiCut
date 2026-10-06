> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
# TASK-UIA-023：播放器设置页 + macOS PiP 按钮 + 快捷键扩充

> **状态**：✅ 全项代码落地（2026-10-05，Batch E + 收尾补）。落地：`PlayerSettingsView`
> （默认循环/双击步长/倍速/字幕字号聚合，即时生效 + 跨会话记忆）+ macOS PiP 按钮
> （与 iOS 同位，isPipPossible 显隐）+ 快捷键 F（NSApp.keyWindow.toggleFullScreen，
> 经闭包注入以便测试）/S（外挂字幕开关）/A（循环）——字符键映射抽为
> `PlayerScreenBody.characterKeyResult` static 可测函数。PlayerQueueTests +3 用例
> （累计 49）。本机 parse 全绿；macOS PiP 行为待构建机/真机。

```yaml
id:          TASK-UIA-023
layer:       UI
goal:        聚合既有持久化项的播放器设置页；macOS 顶栏 PiP 按钮；键盘播控扩充（F/S/A/0-9 复核）
input:       [docs/tasks/PLAN-播放器进阶.md P1, docs/research/RESEARCH-006-独立播放器内核与交互调研.md §3.3]
output:      [Player/PlayerSettingsView.swift + 设置入口 + macOS PiP 按钮 + 快捷键表, PlayerTests 追加]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/PlayerSettingsView.swift, .../PlayerControlsView.swift, .../PlayerScreen.swift, .../PlayerPipCoordinator.swift, Tests/SharedUITests/PlayerTests.swift
read_set:    [docs/CODESTYLE.md, .ai/modules/ui-apple.md]
deps:        [TASK-UIA-015, TASK-UIA-018]   # 字幕样式项挂接
acceptance:
  - 设置页可查看/修改：默认倍速（记忆值回显）、双击步长（5/10/15/30）、默认循环开关（新增持久化键 cq.player.loopDefault）、字幕样式（UIA-018 落地后挂接，字号/位置 v1 两档）
  - macOS 顶栏 PiP 按钮可用（PlayerPipCoordinator 双平台已就绪，仅补入口）；快捷键 F=全屏收起（macOS）、S=字幕开关、A=循环，与既有 空格/←→/，./0-9/m 无冲突
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox（快捷键映射/设置持久化用例）
  - 真机/构建机：macOS PiP 行为（系统画中画窗口）
risk:        macOS PiP 的系统能力表现（isPictureInPictureSupported 返回值）未验证，按钮按可用性显隐
parallel:    false
```

## 实现要点
- 设置项全部走 VM 注入的 UserDefaults（既有模式），不新增存储机制。
- 快捷键表集中在 PlayerScreen 的 handleKeyPress switch（macOS 域内），扩充即加 case + 测试表驱动。
