> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
# TASK-UIA-017：播放器画面捏合缩放与拖移

```yaml
id:          TASK-UIA-017
layer:       UI
goal:        双指捏合 1x–3x 缩放画面（v1 锚定中心），缩放态可单指拖移，双击 1x↔放大复位
input:       [docs/tasks/PLAN-播放器进阶.md P1, docs/specs/UIA-020-独立视频播放器.md §3 V2]
output:      [PlayerControlsView 缩放手势层 + VM 缩放状态, PlayerTests 追加（缩放映射纯函数）]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/PlayerControlsView.swift, .../PlayerScreen.swift, .../PlayerViewModel.swift, Tests/SharedUITests/PlayerTests.swift
read_set:    [docs/CODESTYLE.md, .ai/modules/ui-apple.md]
deps:        [TASK-UIA-015]
acceptance:
  - 捏合平滑缩放且钳制 [1, 3]；松手低于 1.15x 回弹到 1x（防"半放大"悬挂态）
  - 缩放 >1 时可拖移且钳制在画面边界内；双击在 1x↔2x 间切换；aspect 填充/适合切换与换片时复位 1x
  - 缩放映射为纯函数（scaleForMagnification/offsetClamp）并被单测覆盖
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - 真机：捏合/拖移/双击复位/与上下滑及长按倍速共存逐项验证
risk:        捏合与上下滑（亮度/音量）、长按倍速的手势消歧需真机验证——捏合走 MagnificationGesture，与 DragGesture(pan) 的 minimumDistance 区分
parallel:    true   # 与 UIA-016/021 写集不同文件族，可并行（同域内需协调 Controls 文件改动顺序）
```

## 实现要点
- VM 持 `@Published zoomScale/zoomOffset`；surface 包 `scaleEffect/offset`（纯 UI 变换，不碰 AVPlayer）。
- 双击复位与既有"双击 ±N 秒"冲突裁决：缩放态下双击 = 复位，1x 态双击 = 快进快退。
