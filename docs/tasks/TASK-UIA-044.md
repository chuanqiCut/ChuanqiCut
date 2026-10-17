# TASK-UIA-044：轨道区接入 TimelineKit（本地 Pod）+ 适配层与真源方向落地

> **状态：✅ 验收完成（2026-10-17 传哲回收，合并版问卷整卷通过）**。
> 三项待决（D5/E1/F3）已裁定并转出：D5 → TASK-UIA-046，E1 → TASK-CORE-011（关池 [19] 的待决策态），
> F3 → 接受现状（iPad 不保留常驻右栏）。登记全文见
> `docs/reviews/QUESTIONNAIRE-UIA-044-045-合并版-轨道区接入与四项回归统一验收.md` 末段。


> 模板。缺任一项不得进入编码。

```yaml
id:          TASK-UIA-044
layer:       UI
goal:        真实 iOS 编辑页轨道视图换成 TimelineKit，新增内核⇄组件适配层；只换轨道视图，保留预览/传输条/底栏/导入流程
input:       [ADR-0042, 用户 2026-10-15 命题, TimelineKit INTEGRATION_GUIDE.md, RESEARCH-017, ADR-0024, ADR-0034]
output:      [新增 UIKit/TimelineKitAdapter.swift, 新增 UIKit/EditorTimelineKitView.swift, 改 EditorViewController.swift,
             删除 UIKit/EditorTimelineUIView.swift, podspec 拆子 spec, 两端 Podfile/lock, 双壳 BUILD SUCCEEDED]
write_set:   apps/apple/packages/ChuanqiCutEditor/**、apps/apple/ios/Podfile、apps/apple/mac/Podfile(.lock)
read_set:    /Users/zhuning/Documents/ChatGPT/zui/Sources/TimelineKit/**（只读，不改动组件）
deps:        [UIA-034, UIA-039, UIA-040, UIA-041, UIA-043]
blocked_by:  []
merge_note:  与上一轮未提交的 TimelineKit 依赖改动（podspec/Podfile.lock/ChuanqiCutApp.swift）同域，需同批交付
acceptance:
  - iOS 壳构建 BUILD SUCCEEDED（generic/platform=iOS）
  - macOS 壳构建 BUILD SUCCEEDED（x86_64 ONLY_ACTIVE_ARCH=YES）
  - 两端 bundle exec pod install 均成功（P134 子 spec 生效）
  - 内核仍是唯一真源：无 Kit→内核 持久化路径；翻译不了的命令走回滚
  - 未改动调试预览页 TimelineKitIntegrationPreview.swift 来冒充接入
verification:
  - cd apps/apple/ios && bundle exec pod install
  - cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build
  - cd apps/apple/mac && bundle exec pod install
  - cd apps/apple/mac && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build
risk:        TimelineStore 无整体替换入口 → 按快照重建（zoom 需自行带走）；
            播放中每帧 setCurrentTime 的开销未实测（真机问卷项）；
            轨道静音/锁定/排序内核缺写 ABI → 组件自我变更一律回滚；
            macOS/iPad 横屏 SwiftUI 轨道区仍是旧实现（TimelineKit 是 UIKit-only）
parallel:    false
```

## 背景

早期自绘轨道区（UIA-035/037/038 累积）被判定为不合格；本地 CocoaPods 组件 TimelineKit 已具备
完整轨道交互。用户命题：以 TimelineKit 这版为主，现有项目按它适配，三区（轨道/预览/操作面板）
联动统一。硬约束：内核唯一真源、不持久化 Kit 快照、不改调试页冒充接入。

## 子步骤

| # | 内容 | 状态 |
|---|---|---|
| 1 | 确认真实入口：iOS 竖屏 = `EditorViewController` 内的 `EditorTimelineUIView`（SwiftUI `EditorTimelineView` 只服务 macOS/iPad 横屏） | ✅ |
| 2 | `TimelineKitAdapter.swift`：ID 互转 / 有理数时间互转 / 轨道·片段·媒体·帧率 → TimelineProject | ✅ |
| 3 | `EditorTimelineKitView.swift`：容器 + store 重建 + 事件出口（Intent/scrub/append/resync） | ✅ |
| 4 | `EditorViewController` 换型接线；提交后强制按内核快照重灌 | ✅ |
| 5 | 删除旧自绘 `EditorTimelineUIView.swift` | ✅ |
| 6 | podspec 拆 `Core`/`TimelineKitTrack` 子 spec（P134），两端 pod install | ✅ |
| 7 | 双壳构建 | ✅ iOS / ✅ macOS |
| 8 | 真机问卷（移动/跨轨/裁剪/播放头/缩略图/波形/空态）+ 播放期开销实测 | ✅ **已回收 2026-10-17**：传哲通读合并版全卷后判定「验收通过」，并当场定 D5/E1/F3 三条决策。**回收口径**：未逐项勾选、未回传截图、D7/G1 无新的主观/内存数据 → 28 项测试条目按整体判定入账，登记全文见 `docs/reviews/QUESTIONNAIRE-UIA-044-045-合并版-轨道区接入与四项回归统一验收.md` 末段「回收与裁定登记」 |

## 模型映射（内核 → TimelineKit）

| 内核 | TimelineKit | 说明 |
|---|---|---|
| `TrackInfo.trackId: UInt64` | `TimelineTrack.id = "cq-t-<id>"` | 前缀编码，单射可判定 |
| 首条视频轨 | `kind: .primaryVideo`, `role: .primary` | 最多一条 primary（组件校验） |
| 其余视频轨 / 音频轨 | `.video` / `.audio`, `role: .secondary` | 名称「画中画 n」/「音频」 |
| `TrackInfo.muted` | `isMuted`（**只读回显**） | 内核无写 ABI → **已裁定补内核**（TASK-CORE-011，2026-10-17 问卷 E1）；C 落地前组件侧点按仍回滚 |
| `ClipInfo.clipId` | `TimelineClip.id = "cq-c-<id>"` | 同上 |
| `start` / `duration` | `timelineRange`（`TimelineTime` 直搬有理数） | 不经过浮点秒 |
| `sourceIn` / `sourceDuration` | `sourceRange` | 非正时长则不带 |
| 片段种类 | 随轨道：视频轨 `.video`（图片素材 `.image`）、音频轨 `.audio` | 缩略图/波形通道据此选择 |
| `AssetInfo.assetId` / `path` | `TimelineMediaAsset.id = "cq-m-<id>"` / `locator = 宿主素材路径` | 缩略图与波形由该路径提供 |
| 帧率（渲染刻度 1/30） | `TimelineFrameRate.fps30` | 与 `TimelineZoomMath.defaultFrameDuration` 同源 |
| 时长语义 | `durationPolicy: .longestEnabledClip` | 与 `session.timelineDuration()` 同义 |
| 转场/关键帧/画布 item/蒙版 | 不映射（恒空） | 内核侧尚无对应命令或 UI 出口 |

## 事件映射（TimelineKit → 内核）

| 来源 | 事件 | 处理 |
|---|---|---|
| store | `.projectChanged(.moveClip(id,toTrackID,start))` | 同轨 `.move` / 跨轨 `.moveToTrack` → `TrackIntentApplier` → VM 命令 + `refreshFromKernel`，随后强制重灌 |
| store | `.projectChanged(.trimClip(id,edge,boundary))` | leading → `.trimStart`（只给新起点，内核联动 sourceIn）；trailing → `.trimEnd`（只给新占时） |
| store | `.projectChanged(其它命令)` | **不写内核**，`onNeedsResync` 立即按内核快照重灌（回滚） |
| store | `.selectionChanged(clipID)` | `.selectClip` Intent → VM（宿主灌入时用 `isPushingSelection` 抑制回流） |
| store | `.playheadChanged(origin: .userScrub)` | 按项目帧率吸附 → `onScrub` → `VM.setPlayhead`（程序化回灌被忽略，防播放头↔播放器反馈环） |
| view | `.tailInsertionRequested` | `onRequestAppend` → 既有素材导入入口 |
| view | `.zoomChanged(scale)` | 记录，重建时回填 |
| view | `.editRejected` / `.resourceFailed` | os.Logger 记账 + 重灌 / 仅记日志（片段照常显示） |

反向（内核 → 组件）：`$timeline` / 宽度变化 → `reload(tracks:clips:assets:playheadSeconds:force:)`
（值相等则跳过重建）；提交后 `force = true`。
