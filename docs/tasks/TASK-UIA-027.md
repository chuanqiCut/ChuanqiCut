> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
> 拍板：2026-10-05 用户确认进阶版四项开放问题"均需要"，本卡为落地卡（PLAN §3 P2）。
# TASK-UIA-027：macOS mini player（MenuBarExtra）+ 播放器生命周期上移

```yaml
id:          TASK-UIA-027
layer:       UI
goal:        macOS 菜单栏迷你播控（标题/进度/播放暂停/上一下一片/打开主窗口）；关闭主窗口播放不中断
input:       [docs/tasks/PLAN-播放器进阶.md P2, docs/tasks/TASK-UIA-022.md（队列）, docs/research/RESEARCH-006-独立播放器内核与交互调研.md §3.3]
output:      [public PlayerController 门面（共享 VM 上移 App 级）+ PlayerMiniBar 视图 + MacApp MenuBarExtra 场景, PlayerTests 追加]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/PlayerController.swift（新）, .../PlayerScreen.swift, apps/apple/mac/MacApp/ChuanqiCutMacApp.swift, Tests/SharedUITests/PlayerTests.swift
read_set:    [docs/CODESTYLE.md, .ai/modules/ui-apple.md]
deps:        [TASK-UIA-015, TASK-UIA-022]
acceptance:
  - PlayerController：public ObservableObject 门面（init(urls:) / 播放控制 / 队列转发），PlayerScreen 与 MiniBar 共享同一实例——单窗口既有用法（init(url:)）行为不变
  - 关闭播放器主窗口后播放继续（VM 由 App 持有）；重开窗口画面恢复到当前时刻
  - MenuBarExtra（.window 样式，macOS 13+ 基线内）：标题 + 进度条（只读）+ 播放/暂停 + 上/下一片 + "打开主窗口"（openWindow）
  - macOS 非 sandbox，无系统权限前置；iOS 不受影响（场景仅在 mac project.yml）
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox（PlayerController 队列/转发用例）
  - 构建机：MacApp 编译 0 警告；真机：MenuBarExtra 交互、窗口关闭续播
risk:        App 级 ObservableObject 跨 Window/MenuBarExtra 注入（environmentObject）行为需构建机验证；PlayerScreen StateObject→外接 VM 的改造要保既有 init 兼容（回归 PlayerTests 全量）
parallel:    false
```

## 实现要点
- VM 是 internal：public 门面用组合包装（Controller 持 VM 转发），不放大 VM 可见性——保持"App target 消费面 = PlayerScreen/Controller/Launcher 三个 public 类型"。
- MiniBar 进度条只读显示 + 点击打开主窗（编辑进度在主窗做，v1 克制）。
