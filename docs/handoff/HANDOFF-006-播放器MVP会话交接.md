# HANDOFF-006：播放器 MVP 会话交接（构建机验收待执行）

- **日期**：2026-10-05
- **上游**：[TASK-UIA-015](../tasks/TASK-UIA-015.md) · [SPEC-UIA-020](../specs/UIA-020-独立视频播放器.md) · [ADR-0022](../decisions/ADR-0022-独立播放器AVPlayer过渡与内核演进接缝.md) · [RESEARCH-006](../research/RESEARCH-006-独立播放器内核与交互调研.md)
- **状态**：代码与文档全部落盘；**本机（Swift 5.5 / P45）只做了语法级验证**，构建机验收未执行

## 本轮做了什么（对着 commit 核）

1. **支线立项**：独立视频播放器（预览成片 + 播放任意本地视频），RESEARCH-006
   （内核对比 + 交互范式两路调研）→ SPEC-UIA-020 → ADR-0022（AVPlayer 过渡 +
   PlayerEngine 接缝；取号时撞远端 ADR-0021，按让位纪律改 0022）→ TASK-UIA-015。
2. **SharedUI 新域 `Player/` 七文件**：协议接缝 + AVPlayerEngine（倍速/双档
   seek/外部暂停同步/音频会话激活）+ VM 状态机（拖动暂停+静音、松手零容差
   seek、4s 自动隐藏）+ 控制层（自绘进度条、双击 ±10s、上下滑亮度/音量（iOS）、
   倍率菜单、失败横幅、VoiceOver adjustable）+ surface（AVPlayerLayer 桥）+
   PiP 协调器（强持有 + 退后台自动进）+ 缩略图装载器（按秒桶 + LRU ≤120）。
3. **装配**：HomeView 第三入口卡；MacApp `Window("视频播放器")` 场景；
   `ios/project.yml` 加 `UIBackgroundModes: [audio]`。
4. **测试**：`Tests/SharedUITests/PlayerTests.swift`（StubPlayerEngine 注入，8 用例）。
5. **回写**：ui-apple.md 播放器节、baselines 播放器节（逐项"未实测"）、
   workbuddy 日志 + MEMORY（AVFoundation 域边界 + 5.5 可解析风格两条长期规则）、
   BACKLOG/登记表（46→47 张）。

## 下一步是谁、做什么（构建机会话）

1. `cd apps/apple/packages/SharedUI && swift test --disable-sandbox`
   —— PlayerTests 8 用例 + 既有 71 用例不回归。**已知风险点**：
   `AVAssetImageGenerator.image(at:)` async 的 Swift 6 Sendable 标注完整性
   （hypothesis，见 RESEARCH-006 §5）——报 Sendable 错就给 Task 体套
   `@Sendable` 装箱或在 loader 内收敛。
2. 双平台编译（顺序 xcodegen → pod install，P54/P56）：
   `cd apps/apple/ios && xcodegen generate && bundle install && bundle exec pod install`
   后 `xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp`；
   mac 同构。**P49 盲区**：iOS 分支（PiP/亮度/`requestGeometryUpdate`/idleTimer）
   是 macOS swift test 照不到的，重点看这些文件的 typecheck。
3. `tools/ci/run_gate.sh` 全量（预期 PASS=9/FAIL=0 维持）。
4. 真机行为清单（SPEC §6.4）+ baselines 播放器节逐项替换实测数字
   （起播延迟 / 零容差 seek 延迟 / 2x CPU / 缩略图内存）。
5. 如踩新坑：pitfalls 记 **P60 起**（本轮未用号）。

## 第二轮（同日深夜，V1 批次）新增验收点

- 新增功能：长按倍速（2x 松手恢复+触觉）、单片循环、A-B 循环（三态+区间
  标记+区间外自动清除）、倍速跨会话记忆（UserDefaults `cq.player.rate`）、
  缩略图批量预热（≤24 桶错峰）、换片（moreMenu"打开新视频"）、macOS 拖放打开。
- PlayerTests 8 → **14 用例**；构建机跑全量。
- 新增 Swift 6 关注点：`onLongPressGesture` 与 pan/tap 手势共存（构建机真机
  验证消歧）；`dropDestination(for: URL.self)`（iOS16/macOS13 基线内）；
  PickerFeedback 跨域复用（MediaPicker 域 → Player 域，同模块 internal）。
- 行为清单追加：长按 2x 松手回 1x；A-B 回跳与标记显示；换片后进度/缩略图/AB
  复位且循环开关保留；重启 App 倍速保持。
- **第三轮追加**：多音轨/内封字幕视频的 moreMenu"音轨/字幕"子菜单切换生效
  （切换后音画继续、气泡反馈、checkmark 移动）；双击步长 5/10/15/30 切换
  持久化且 skip 按钮图标同步变化。PlayerTests 8 → **17 用例**。
  新增 Swift 6 关注点：`AVMediaSelectionGroup`/`AVMediaSelectionOption`
  跨执行器 Sendable 标注（与缩略图同 hypothesis，报错则同样装箱收敛）。

## 进阶版本规划（2026-10-05 深夜追加）

进阶版路线已立：`docs/tasks/PLAN-播放器进阶.md`（P1 六卡 UIA-016/017/018/021/022/023
+ P2 导出挂接点 + P3 内核演进纲领）。P1 全部卡以**构建机门禁 PASS**为开工前置；
编号跳过 019（面板框架 spec 保留）/020（防 spec 同号混淆），取号已 git fetch 核对。
构建机会话完成门禁后，可直接按 PLAN §2/§3 顺序开工 P1 → P2
（P2 四卡 = 用户拍板项：UIA-024 网络流点播、025 ASS 样式子集、026 素材库联动、
027 macOS mini player；依赖：025←018、026/027←022，024 独立）。

## 实施进度（P1/P2 开工后滚动更新）

- **UIA-018 / UIA-025 ✅ 代码落地（2026-10-05 Batch C）**：ADR-0023（解析层
  Swift 纯函数过渡，SubtitleCue 值类型即未来 C ABI 底稿）+ SubtitleParser
  （SRT/VTT/ASS 嗅探、时间戳方言、坏块容错、ASS 样式子集与 span 样式快照切段）
  + SubtitleOverlayView（\pos/九宫格/PlayRes 字号归一）+ VM 装载/关闭/派生查询
  + moreMenu 入口（外挂开启时内封字幕让位）+ 换片清除。PlayerSubtitleTests
  **9 用例**（累计 42）。**待构建机**：swift test 全量；**待真机**：真实字幕样本对照。
- **UIA-024 / UIA-017 ✅ 代码落地（2026-10-05 Batch B）**：网络流点播
  （`isRemoteMediaURL` 纯函数 + 远程恢复系统缓冲 + 直播流拒绝 + onBufferingChange
  → spinner + 远程禁预热/气泡 + Launcher 网址入口含剪贴板粘贴）+ 捏合缩放
  （PlayerZoomMath 纯函数 + MagnificationGesture + 缩放态 pan 拖移 + 双击复位 +
  aspect/换片复位）。PlayerTests +3、PlayerQueueTests +2 用例（累计 33）。
  **待构建机**：MagnificationGesture 与 pan/长按消歧、远程 AVPlayer 行为；
  **待真机**：HLS 样本、捏合手感。
- **UIA-021 / UIA-022 ✅ 代码落地（2026-10-05 Batch A）**：最近播放存储
  （`PlayerRecentStore`，shared 单例 + tests 注入）+ 队列状态机（分派链
  AB > 循环 > 队列 > 停止；失败跳片）+ Launcher 多选/最近列表 + 队列 sheet。
  测试支撑抽出 `PlayerTestSupport.swift`（StubPlayerEngine + makePlayerViewModel 共用）。
  新增公共 API：`PlayerScreen(urls:startIndex:)`。PlayerTests 17 + PlayerQueueTests 11 用例。
  **待构建机**：swift test 全量 + 双平台编译；待真机：iOS bookmark 跨会话、连播间隙。

## 装配形状（一图）

```
HomeView(第三卡)/MacApp(Window) → PlayerLauncherScreen(fileImporter)
  → PlayerScreen(url) — public 唯一入口
      ├ PlayerSurface(AVPlayerLayer) ← engine.avPlayer（类型耦合点，ADR-0022 已登记）
      ├ PlayerControlsOverlay（手势全挂这层；按钮命中优先）
      │    └ PlayerScrubber（拖动→VM scrub 状态机；气泡←VideoThumbnailLoader）
      └ PlayerViewModel(@MainActor)
           ├ engine: PlayerEngine ← AVPlayerEngine（AVPlayer/观察者/音频会话）
           └ pip: PlayerPipCoordinator ← layer 由 Screen 以不透明值传入
```

## 坑与约定

- **AVFoundation/AVKit 只许在 Player 域五文件**（引擎×2/surface/缩略图/PiP）；
  跨文件传 `AVPlayer`/`AVPlayerLayer` 用"不点名的不透明值"（不写类型名即可传）。
- **SharedUI 新代码按 Swift 5.5 可解析风格**（显式 `guard let x = x`、
  不用 `any P`）——否则本机 parse 验证失真（P45/P46）。
- 缩略图 LRU 上界 120 张 [E ≈32MB]：低端机吃紧就先降 `maximumSize` 再降上界。
- 播放器 ≠ 编辑预览：不要把 AVPlayer 接进 RenderGraph 预览线，两条链路的
  汇合点是 ADR-0022 §5 的 C++ session（PALA-030 落地后才立项）。
