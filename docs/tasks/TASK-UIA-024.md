> 模板依据 .ai/templates/task.md。缺任一项不得进入编码。
> 前置：构建机门禁 PASS（TASK-UIA-015）；开工前 git fetch 核对号（PLAN-播放器进阶 §5）。
> 拍板：2026-10-05 用户确认进阶版四项开放问题"均需要"，本卡为落地卡（PLAN §3 P2）。
# TASK-UIA-024：播放器网络流播放（URL / HLS 点播）

> **状态**：✅ 代码落地（2026-10-05，Batch B）；HLS 样本真机项与远程 seek 延迟实测待执行。
> 落地：`AVPlayerEngine.isRemoteMediaURL` 纯函数 + 源策略（远程恢复系统缓冲等待）
> + 无限时长拒绝（"暂不支持直播流"）+ `onBufferingChange` 协议回调 → VM.isBuffering
> spinner + 远程禁缩略图预热/拖动气泡 + Launcher 网址入口（校验/粘贴/onSubmit）。
> 本机 parse 全绿。

```yaml
id:          TASK-UIA-024
layer:       UI
goal:        播放器支持 http(s) URL 与 HLS 点播源；本地/网络源差异化策略（缓冲策略/缩略图/入口）
input:       [docs/tasks/PLAN-播放器进阶.md P2, docs/specs/UIA-020-独立视频播放器.md, docs/research/RESEARCH-006-独立播放器内核与交互调研.md]
output:      [AVPlayerEngine 源类型策略 + VM 缓冲态 + Launcher URL 入口 + PlayerTests 追加]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Player/AVPlayerEngine.swift, .../PlayerViewModel.swift, .../PlayerScreen.swift, Tests/SharedUITests/PlayerTests.swift
read_set:    [docs/CODESTYLE.md, .ai/modules/ui-apple.md]
deps:        [TASK-UIA-015]   # 构建机门禁 PASS
acceptance:
  - 源类型判定纯函数（scheme http/https = 远程，其余 = 本地）且被单测覆盖；远程源 automaticallyWaitsToMinimizeStalling 保持默认 true（本地 false 不变）
  - 远程源禁用缩略图批量预热与拖动气泡现取（AVAssetImageGenerator 远程过慢 [E]）；拖动退化为纯时间气泡
  - 播放中缓冲：timeControlStatus == .waitingToMinimizeStalling → isBuffering published → 控制层居中 spinner（与 loading 态区分）
  - Launcher 增"输入网址"入口：scheme 校验（仅 http/https）+ 剪贴板粘贴；最近播放对远程 URL 直接存 URL（不走 bookmark）
  - 无限时长源（直播流）装载即拒绝：中文错误横幅"暂不支持直播流"（范围 = 点播，SPEC 非目标同步修订）
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox（源类型/策略/URL 校验 stub 用例）
  - 构建机/真机：HLS 样本流（公开测试流）起播/拖动/倍速/断网自动暂停（既有行为复核）
risk:        CDN/HLS 变体兼容性由 AVPlayer 自管（黑盒）；远程 seek 延迟未实测（baselines 增行）
parallel:    true
```

## 实现要点
- 引擎持 `private(set) var isRemoteSource: Bool`（load 时判定）；automaticallyWaitsToMinimizeStalling 按源切换。
- security-scope 分支天然无害（远程 URL startAccessing 返回 false）——不为此加分支，仅注释说明。
- cq-media-pipeline 六问：解码/缓冲在 AVPlayer 内部线程；无自建线程；错误走既有 failed 横幅链路。
