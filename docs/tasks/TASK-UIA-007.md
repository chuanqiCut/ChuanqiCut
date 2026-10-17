# TASK-UIA-007：导出面板（格式选择 / 进度 / 取消）

```yaml
id:          TASK-UIA-007
layer:       UI
goal:        把 EXPORT-001 的导出控制器接进编辑器 —— 现在那颗按钮是置灰的
input:       [TASK-EXPORT-001、UIA-042（UIKit 布局）、ADR-0034（问卷即验收）]
output:      [导出面板、进度/取消接线、Swift 侧导出封装、真机问卷]
write_set:   ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/EditorScreen.swift、
             ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/{EditorViewController.swift,EditorToolbarUIView.swift}、
             ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/ExportSheetUIView.swift（新建）、
             api/swift/Sources/ChuanqiCut/Export.swift（新建）、
             ui/ChuanqiCutEditor/Tests/、docs/reviews/QUESTIONNAIRE-UIA-007-*.md（新建）
read_set:    api/swift/Sources/ChuanqiCut/{Session.swift,Timeline.swift}、
             ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/{MediaSheet.swift,EditorChromePalette.swift,AppEntry.swift}
deps:        [EXPORT-001]
acceptance:
  - 导出按钮不再 `.disabled(true)`；可用性走 capability 查询，**不得**用 `#if os(iOS)` 推断（红线 3）
  - 取消在 UI 上可点、点了 ≤1 帧内有反馈；进度只读 EXPORT-001 的回调，面板不自己数帧
  - 主线程零阻塞：导出跑 session 线程，UI 经 observer 回流刷新（沿用编辑页既有回流路径）
  - UIKit 面必须由**双壳真编译**判红：`tools/ci/check_apple_shells.sh`；`swift test` 绿不算（P181）
  - 真机走查 + 问卷回收才算完成（ADR-0034）；本卡的问卷**并入** UIA-046 那张一起发
verification:
  - tools/ci/gate_scope.sh                       # 先问脚本要跑哪几条
  - swift test（api/swift 侧封装）
  - tools/ci/check_apple_shells.sh               # 唯一能判红 UIKit 那两步的档
  - xcrun devicectl device process launch …（真机，见池 [30] 的取证口径）
risk:        面板与 UIA-046 抢同一批编辑器文件 → 必须串行，UIA-046 排本卡之后。
             相册写入**不在本卡**：授权口径属 EXPORT-010/011 与未定稿的 ADR-0028，
             本期只落沙盒文件 + 系统分享，别顺手加 `UIActivityViewController` 之外的落盘路径。
parallel:    false
```

## 背景

`EditorScreen.swift` 的 iOS 工具栏早就有"导出"位，一直是 `.disabled(true)`，
`AppEntry.swift` 里也留了 capability 开关 —— 内核没导出线时它只能灰着。EXPORT-001 落地后这张卡把它接上。

BACKLOG 那行写的写集是 `SharedUI`，**已过期**：SharedUI 现在只剩基础件（ADR-0044 之后轨道区归
TimelineKit、编辑器布局归 UIKit），导出面板落在 UIKit 面而不是 SwiftUI。

## 面板范围（MVP，别再长）

1. 入口：工具栏导出 → 弹层（表先例 = `MediaSheet.swift`）。
2. 参数：分辨率/帧率两档即可，编码档位属 EXPORT-002。
3. 状态机映射：idle → running（进度条 + 取消）→ done（给出路径）/ error（给出错误码文案）/
   cancelled（**不算失败**，不弹红）。
4. 完成后：沙盒文件路径 + 系统分享；**不写相册**。

## 回写

`.ai/modules/ui-apple.md`（编辑器装配形状 + 面板归属）、`docs/tasks/TASK-BACKLOG.md` §3.5 行状态、
`docs/handoff/` 下一张卡的接手指针、问卷回收登记进池并把数字写进模块册。
