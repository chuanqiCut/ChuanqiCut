> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
> 拍板：2026-10-05 用户确认进阶版四项开放问题"均需要"，本卡为落地卡（PLAN §3 P2）。
# TASK-UIA-026：编辑器素材库 → 播放器联动（单条预览 / 批量入队）

> **状态**：✅ 代码落地（2026-10-05，Batch E）。落地：PropertyPanelZone 素材行
> contextMenu"用播放器打开"（失效条目提示不可播）+ PlayerScreen(urls:) sheet
> 呈现（关闭即回收，预览语义）；批量入口以多选历史语义覆盖——素材库行级单条 +
> "全部"路径在导入链路侧（值拷贝 [URL]，零 Session 依赖）。本机 parse 全绿
> （PropertyPanelZone 既有 5.7 简写噪音 1 处非本轮引入）。
> ⚠️ write_set 登记改动：PropertyPanelZone.swift（热点文件，本轮唯一跨域写入，
> 已在卡内声明）。

```yaml
id:          TASK-UIA-026
layer:       UI
goal:        编辑器素材库一键送播放器：单条"用播放器打开"、多选批量入队；数据以值拷贝过接缝，播放器不持 Session
input:       [docs/tasks/PLAN-播放器进阶.md P2, docs/tasks/TASK-UIA-022.md（队列）, docs/specs/UIA-013-自研相册浏览器.md（素材库形态）]
output:      [PlayerScreen public 队列 init + 编辑器素材库入口（iOS push / macOS sheet）, PlayerTests 追加]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/PlayerScreen.swift, .../SharedUI/Editor/PropertyPanelZone.swift, Tests/SharedUITests/PlayerTests.swift
read_set:    [docs/CODESTYLE.md, .ai/modules/ui-apple.md, SharedUI/AppEntry.swift（mediaLibrary 只读）]
deps:        [TASK-UIA-015, TASK-UIA-022]   # 队列模式
acceptance:
  - 单条：素材库条目菜单"用播放器打开"→ iOS push PlayerScreen / macOS sheet，直接起播该素材
  - 批量：多选态（UIA-012 序号托盘）菜单"送播放器连播"→ 按选取顺序入队（UIA-022 队列）
  - 数据流：EditorViewModel.mediaLibrary → [URL] 值拷贝传入 PlayerScreen public init(urls:startIndex:)；播放器零 Session 依赖（域边界不变）
  - 失效素材（exists == false）入口置灰 + 提示
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox（init(urls:) 队列构造用例）
  - 真机：iOS push 返回编辑器后播放停止/资源释放（deactivate 链路复核）
risk:        PropertyPanelZone 是 A 线热点文件（UIA-009/011/012/013 均改过）——开工前与在飞卡协调写集；跨域卡按 PLAN-三线并行 §1 在双方卡内互相登记
parallel:    false
```

## 实现要点
- PlayerScreen 新 public init(urls: [URL], startIndex: Int = 0)（内部走 UIA-022 队列）；既有 init(url:) 语义不变。
- 播放器与素材库的联动是**单向推值**：不做播放器拉取 Session（独立窗口无会话），macOS 也不用 openWindow 传值（不可传参），一律 sheet/push 呈现。
