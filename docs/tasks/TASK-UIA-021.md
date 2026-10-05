> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
# TASK-UIA-021：播放器最近播放（bookmark 持久化 + 列表入口）

> **状态**：✅ 代码落地（2026-10-05，Batch A）；构建机门禁与真机项待执行。
> 落地：`Player/PlayerRecentStore.swift`（去重置顶/上限 20/失效剔除/bookmark 平台分支）
> + Launcher 最近列表（含清空）+ VM ready 时记录（每片一次，失败不污染）。
> PlayerQueueTests 6 用例覆盖存储纯逻辑与 VM 记录时机。本机 parse 全绿。

```yaml
id:          TASK-UIA-021
layer:       UI
goal:        记住最近播放的本地视频（跨会话），Launcher 空态提供最近列表一键重播，失效自动剔除
input:       [docs/tasks/PLAN-播放器进阶.md P1]
output:      [Player/RecentMediaStore.swift（@MainActor，UserDefaults + security-scoped bookmark）+ Launcher 列表 UI, PlayerTests 追加（store 纯逻辑用例，注入 UserDefaults）]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/PlayerRecentStore.swift, .../PlayerScreen.swift（Launcher 部分）, Tests/SharedUITests/PlayerTests.swift
read_set:    [docs/CODESTYLE.md, .ai/modules/ui-apple.md, apps/apple/ios/project.yml]
deps:        [TASK-UIA-015]
acceptance:
  - 播放过的视频在重启后出现在最近列表顶部；去重（同文件只一条）+ 置顶 + 上限 20 条
  - iOS：fileImporter URL 以 security-scoped bookmark 持久化，重开时 startAccessing 成功才可播
  - 失效剔除：bookmark 解析失败 / 文件不存在 → 该条自动移除并刷新列表
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox（store 用例注入 UserDefaults suite）
  - 真机：iOS 跨会话重开（Files 选入的文件）；macOS 直接路径重开
risk:        iOS security-scoped bookmark 行为需真机验证；plist 体积上界（上限条目钳制）
parallel:    true
```

## 实现要点
- 条目 = {name, bookmark/path, addedAt}；macOS 工程未开 sandbox（project.yml 无 entitlemens 段）→ 直接存 file path，iOS 存 bookmark data——平台分支收敛在 store 单文件。
- 播放成功（state == .ready）才入列表，失败不污染。
