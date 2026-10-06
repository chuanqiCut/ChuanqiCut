> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
> 拍板：2026-10-05 用户确认进阶版四项开放问题"均需要"，本卡为落地卡（PLAN §3 P2）。
# TASK-UIA-025：播放器外挂字幕 v2——ASS/SSA 样式子集

> **状态**：✅ 代码落地（2026-10-05，Batch C，与 UIA-018 同解析器交付）。
> 覆盖：[Script Info] PlayRes、[V4+/V4 Styles] Format/Style 行（字段序由 Format 决定）、
> Dialogue 固定序字段、样式子集 {\b}{\i}{\u}{\fn}{\fs}{\c/\1c（BGR→RGB）}{\an}{\pos}、
> \N 换行、未知 tag 容错剥离；样式切换即切段（span 持样式快照）。未做：卡拉OK/
> 矢量/blur/3D/clip（还原度声明"样式子集"）；libass 引入另评（ADR-0023 §4）。
> PlayerSubtitleTests 含 ASS 3 用例。本机 parse 全绿。

```yaml
id:          TASK-UIA-025
layer:       UI
goal:        在 UIA-018 的解析/渲染管线上支持 ASS/SSA 字幕的**样式子集**：颜色/粗斜下划/字体字号/对齐/边距/\pos 绝对定位
input:       [docs/tasks/PLAN-播放器进阶.md P2, docs/tasks/TASK-UIA-018.md, docs/decisions/ADR-0023*（UIA-018 产出）]
output:      [SubtitleParser 扩展 ASS 解析 + AttributedString 样式渲染 + PlayerTests 追加（ASS 夹具）]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/SubtitleParser.swift, .../SubtitleOverlayView.swift, Tests/SharedUITests/PlayerTests.swift
read_set:    [docs/CODESTYLE.md, .ai/modules/ui-apple.md, docs/decisions/ADR-0023*]
deps:        [TASK-UIA-015, TASK-UIA-018]
acceptance:
  - ASS/SSA 样本解析：[Script Info]/[V4+ Styles]/[Events] 三段；Dialogue 时间戳（h:mm:ss.cc）→ 秒；样式行映射默认样式
  - override tag 子集生效：{\b \i \u \s}{\fn}{\fs}{\c / \1c（&HBBGGRR→RGB）}{\an1-9}{\pos(x,y)}；未知 tag 剥离不致命（容错解析）
  - 明确不做并在卡内文档化：卡拉OK \k、矢量 \p、模糊 \blur、3D \fr、\clip、嵌套复杂效果——还原度声明为"样式子集"
  - 渲染对齐 UIA-018 管线（二分查当前行 + 显隐）；1MB 上界沿用；性能：2MB ASS 解析 < 200ms [E] 待实测
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox（ASS 夹具用例：样式/对齐/pos/未知 tag 容错）
  - 真机：真实 ASS 样本对照（和 MPC-B/SPlayer 截图对比主样式）
risk:        ASS 方言差异（SSA v4 / ASS v4+）；样式还原度期望管理——是子集不是完整 libass；libass 引入与否列为卡内开放问题（ISC 许可，但走 manifest.toml + cq-dependency-governance 成本另评）
parallel:    true
```

## 实现要点
- 解析输出与 UIA-018 同构（[(start, end, segments)]，segments 带样式 span），渲染层 SwiftUI AttributedString。
- \pos 相对播放区归一化坐标（PlayResX/Y → 视图比例换算纯函数，可测）。
