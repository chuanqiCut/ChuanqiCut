> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
# TASK-UIA-018：播放器外挂字幕 v1（SRT / WebVTT）

```yaml
id:          TASK-UIA-018
layer:       UI
goal:        加载本地 SRT/WebVTT 字幕文件，随播放时间轴显隐渲染；v1 覆盖解析、渲染、入口三件事
input:       [docs/tasks/PLAN-播放器进阶.md P1, docs/specs/UIA-020-独立视频播放器.md §7 开放问题 2]
output:      [Player/SubtitleParser.swift（纯函数解析）+ Player/SubtitleOverlayView.swift + VM/Screen 接线, PlayerTests 追加（解析夹具用例）]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/**, Tests/SharedUITests/PlayerTests.swift, docs/decisions/ADR-0023*
read_set:    [docs/CODESTYLE.md, .ai/modules/ui-apple.md]
deps:        [TASK-UIA-015]
acceptance:
  - SRT 与 WebVTT 样本解析正确：时间戳→秒、多行文本、HTML 实体/标签剥离（WebVTT）
  - 容错：坏行跳过不致命；>1MB 文件拒绝（内存上界）；UTF-8 优先、带 BOM 的 UTF-16 可读
  - 字幕随 currentTime 显隐（tick 0.25s 粒度）；换片/关闭入口清除；渲染位置避开控制层
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox（解析器用例含夹具）
  - 真机：实际 srt 文件加载、与内封字幕（UIA-016 前的 moreMenu 字幕）不冲突
risk:        解析层归属——**开工前补 ADR-0023**：v1 以 Swift 纯函数过渡（可测、零 ABI 变更），三端一致需求出现时下沉 C++（红线 #1 边界登记，先例 ADR-0014 域豁免叙事）
parallel:    true
```

## 实现要点
- 解析输出 `[(start, end, text)]` 有序数组 + 二分查找当前行（O(log n)，无逐帧扫描）。
- 字幕开关与内封字幕选择共存：外挂开启时内封字幕菜单置灰（v1 简化）。
