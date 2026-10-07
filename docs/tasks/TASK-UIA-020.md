# TASK-UIA-020：预览活性修复（模型推进 → 同 pts 重渲染）

> **状态：✅ 已落地（2026-10-05，本集成机）**——门禁数字与走查证据见 `docs/reviews/REVIEW-2026-10-05-UIA015-编辑页走查.md`、`.workbuddy/memory/2026-10-05.md`。

```yaml
id:          TASK-UIA-020
layer:       UI
goal:        导入/编辑/撤销等命令落地后，预览在当前播放头自动重渲染（消除"导入后黑屏/编辑后旧画面"）
input:       [docs/specs/UIA-015-编辑页重构.md §4.1, .ai/modules/preview.md §10, RESEARCH-004]
output:      [AppEntry.swift renderEpoch, MetalPreviewView.swift seq 追帧, SharedUITests 新用例]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift、
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/MetalPreviewView.swift、
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PreviewZone.swift（renderEpoch
             透传一行，UIA-015 重构前先行的胶水）、
             apps/apple/packages/SharedUI/Tests/SharedUITests/**
read_set:    bindings/swift/Sources/ChuanqiCut/PreviewPump.swift、.ai/modules/preview.md、ADR-0016
deps:        []
acceptance:
  - applySnapshot（含初始 refreshTimeline）后 pump.stats.requested 递增且 renderEpoch 递增（真 Session+Previewer+Pump 单测）
  - seq 追帧判定抽纯函数（装载→旧帧继续追→新帧 seq 前进即收敛；渲染失败黑帧同规则收敛）单测覆盖
  - 既有 SharedUI 全量测试零回归（含 MetalPreviewViewTests 像素用例）
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - xcodebuild build -workspace apps/apple/ios/ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -sdk iphonesimulator -destination 'generic/platform=iOS Simulator'
  - xcodebuild build -workspace apps/apple/mac/ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -destination 'platform=macOS'
risk:        追帧停止条件从 pts 比较改为 seq 比较可能影响 UIA-003 像素级用例 → 先跑全量既有测试锁定基线，纯函数分步断言
parallel:    true   # 与 UIA-016 写集不相交；UIA-015 依赖本卡
```

## 背景
SPEC-UIA-015 §1 症状 2：`MetalPreviewView.sync` 只在 pts 变化时向泵请求；`applySnapshot` 不触发重渲染——导入前对空时间线渲染的空隙黑帧（seq 未变）被永远 blit。`CQ_DEMO_VIDEO` 演示钩子把播放头设到 0.5s，掩盖了缺口。

## 实现要点
1. `EditorViewModel`：`@Published private(set) var renderEpoch: UInt64`；`applySnapshot` / `refreshTimeline` 末尾 `previewPump?.request(pts: playhead)` + `renderEpoch += 1`。
2. `PreviewMTKView.sync` 新增 epoch 入参：变化 → `pump.request(pts:)` + 装载追帧；追帧停止条件 = **seq 判定**（装载时经 `withLatestFrame` 记录当时最新 seq，`draw()` 中 `frame.seq != seqAtArm` 即收敛）。pts 变化路径同样走 seq 判定（旧 pts 比较在"同 pts 重渲染"下永不收敛，正是本缺口）。
3. 判定逻辑抽 `PreviewSettleRule` 纯函数（SharedUI 内部），供单测。
4. 媒体管线六问（cq-media-pipeline）：线程=请求仍主线程入队/渲染在泵线程（不变）；时序=RationalTime 不变；内存=无新分配路径；取消=不变；错误码=空隙/失败仍按泵既有语义发布（黑帧/nil 纹理，seq 前进）；一致性=同请求同结果。**不触解码与 ABI**。

## 验收
对应 acceptance 三条；测试文件 `PreviewLivenessTests.swift`。

## 回写
`.ai/modules/preview.md` §10 增补"模型推进触发"段；pitfalls 若有新坑记录。
