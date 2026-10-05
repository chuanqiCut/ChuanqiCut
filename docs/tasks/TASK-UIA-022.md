> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
# TASK-UIA-022：播放器播放列表与连续播放

```yaml
id:          TASK-UIA-022
layer:       UI
goal:        多文件队列连续播放：Launcher 多选入队、播完自动下一片、列表 UI 当前高亮可点击切换
input:       [docs/tasks/PLAN-播放器进阶.md P1, docs/specs/UIA-020-独立视频播放器.md]
output:      [VM 队列状态机 + Launcher 多选接线 + 列表 UI（半屏面板，MediaPicker 交互范式参考）, PlayerTests 追加（队列推进/边界用例）]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/PlayerViewModel.swift, .../PlayerScreen.swift, .../PlayerQueue.swift（新，可选）, Tests/SharedUITests/PlayerTests.swift
read_set:    [docs/CODESTYLE.md, .ai/modules/ui-apple.md, SharedUI/MediaPicker/（交互参考，只读）]
deps:        [TASK-UIA-015, TASK-UIA-021]   # 列表 UI 与最近播放同壳
acceptance:
  - 多选入队后从首片播放；单片播完自动 swapMedia 下一片，间隙不黑屏死等（失败跳下一片并计数）
  - 优先级语义（stub 测试断言）：A-B 循环 > 单片循环 > 队列推进（AB/循环开启时不自动切下一片）
  - 列表：当前片高亮、点击切换（resetABLoop + swapMedia）、清空队列；换片复位语义与 swapMedia 既有实现一致
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox（队列推进/优先级/失败跳片用例）
  - 真机：多片连播换片间隙（目标 < 1s [E]，实测回填 baselines）
risk:        v1 不做预加载，换片间隙取决于 swapMedia 现载路径（本地文件应可接受，实测定夺；超预期再立预加载卡）
parallel:    false
```

## 实现要点
- VM 持 `queue: [URL]` + `queueIndex`；engineDidEnd 的分派顺序：AB → 单片循环 → 队列下一片 → 停止（既有代码只改这一处分派）。
- 失败跳片：engineDidChangeState(.failed) 时若队列还有下一片自动前进并 toast 计数，全部失败才落错误横幅。
