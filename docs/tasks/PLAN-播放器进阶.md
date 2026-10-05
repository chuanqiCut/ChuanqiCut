# PLAN — 播放器进阶版本规划（UIA-015 配套，2026-10-05）

> 背景：播放器 MVP 三轮交付完成（commit 0701d48 / adac5f1 / 6d936ab，PlayerTests 17 用例），
> AVPlayer 过渡内核稳定（ADR-0022），V1 档仅剩章节标记。本文件规划**进阶版本**：
> 三阶段推进、卡清单、触发条件与开放问题。授权：用户 2026-10-05"看下进阶版本如何规划"。
> 前置事实：本机（Swift 5.5）只能做 parse 级验证——P1/P2 全部卡以**构建机门禁 PASS** 为开工前置。

## 1. 版本定位：两条主线

| 线 | 内核 | 内容 | 节奏 |
|---|---|---|---|
| **体验线** | AVPlayer（不动） | P1 体验补完 → P2 场景与能力扩展 | 卡就绪即开工，受构建机门禁约束 |
| **内核线** | C++ 播放 session | P3 演进（ADR-0022 既定路线） | **触发条件制**：PALA-030 落地后才立项 |

原则：体验线不动内核协议已冻结部分（只允许增量扩展 + 对应 stub 测试）；
内核线在触发前**不写一行代码、不占坑文件**（遵守 ADR-0022"登记不立项"）。

## 2. P1 体验补完（六张卡，AVPlayer 内核上）

| 卡 | 内容 | 关键依赖/前置 | 备注 |
|---|---|---|---|
| [UIA-016](TASK-UIA-016.md) | 系统级播控补完：章节标记 + PiP 占位态 + AirPlay 路由 | V1 遗留 + delegate 接线 | 章节 API 形状 hypothesis，构建机首验 |
| [UIA-017](TASK-UIA-017.md) | 画面捏合缩放与拖移（1x–3x + 双击复位） | 纯手势层 | 与上下滑/长按倍速消歧是重点 |
| [UIA-018](TASK-UIA-018.md) | 外挂字幕 v1（SRT/WebVTT） | **开工前补 ADR-0023**（解析层归属） | 解析纯函数可测，v1 Swift 过渡 |
| [UIA-021](TASK-UIA-021.md) | 最近播放（bookmark 持久化 + 列表） | 独立 | macOS 未开 sandbox，仅 iOS 走 bookmark |
| [UIA-022](TASK-UIA-022.md) | 播放列表与连续播放 | UIA-021（列表 UI 复用） | 队列语义与循环/AB 的优先级已定义 |
| [UIA-023](TASK-UIA-023.md) | 播放器设置页 + macOS PiP + 快捷键扩充 | UIA-018（字幕样式项） | 聚合既有 UserDefaults 项 |

依赖图：`UIA-016/017/021 互相独立，可并行` → `UIA-022 依赖 021` → `UIA-023 依赖 018`；
全部卡 deps 挂 `TASK-UIA-015 门禁 PASS`。

## 3. P2 场景与能力扩展（四张卡，2026-10-05 用户拍板"均需要"后新增）

原规划期列为开放问题的四项，用户确认全部纳入，各立一卡：

| 卡 | 内容 | 关键依赖/前置 | 范围要点 |
|---|---|---|---|
| [UIA-024](TASK-UIA-024.md) | 网络流播放（URL/HLS **点播**） | 独立 | 源类型策略（缓冲/缩略图差异化）、URL 入口、直播流拒绝 |
| [UIA-025](TASK-UIA-025.md) | 外挂字幕 v2：ASS/SSA **样式子集** | UIA-018 | 颜色/粗斜下/字体字号/对齐/\pos；卡拉OK 矢量等明确不做；libass 引入另行评估 |
| [UIA-026](TASK-UIA-026.md) | 编辑器素材库 → 播放器联动 | UIA-022 | 单条预览/批量入队；值拷贝过接缝；PropertyPanelZone 热点协调 |
| [UIA-027](TASK-UIA-027.md) | macOS mini player（MenuBarExtra） | UIA-022 | PlayerController 门面（VM 上移 App 级）、关窗续播 |

依赖图：`UIA-024 独立` / `UIA-025 依赖 018` / `UIA-026、027 依赖 022`；
全部挂 `TASK-UIA-015 门禁 PASS`。范围红线：网络流仅点播（直播流拒绝）；
ASS 是样式子集不是完整 libass。

**仍然不建卡的挂接点**：

1. **导出完成 → 直接预览成片**：挂接点 = UIA-007（导出界面）立项时，
   在其"导出成功"分支引用本节——`PlayerScreen(url: 导出产物)` 一行装配，
   播放器侧零改动（public 入口已为此设计）。
2. **"最近导出"快捷入口**：并入 UIA-021 的最近列表（来源除 fileImporter 外
   增加 App 导出目录），待 EXPORT-001 落地后补数据源。
3. **编辑器内预览联动**：不做——编辑预览走自研 RenderGraph 线（ADR-0016/0017），
   与文件播放器是两条链路，汇合点只在 P3。

## 4. P3 内核演进（纲领，触发后按流程立项）

**触发条件**（ADR-0022 反转条件）：PALA-030（AVAudioEngine 后端）落地，
且产品要求"成片预览与导出画面一致（HDR/色彩管理）"或三端统一播放行为。

触发后的立项序列（届时按 cq-spec-authoring 出 SPEC，再 cq-task-planning 拆卡）：

```
PALA-030（已在 BACKLOG，deps AUDIO-001）
  → SPEC-播放session（范围：文件播放语义 vs 时间线播放语义的边界重申）
  → 契约冻结：cq_play_* C ABI 设计稿 + 评审（高冲突文件 cq_sdk.h，单独成卡）
  → 内核：demux loop + 音视频双队列 + 主时钟（复用 PlayerClock / MEDIA-020/021 快路径）
  → PAL：VideoToolbox/MediaCodec 硬解接入（能力运行时查询，红线 #3）
  → 绑定：CQPlayerEngine 实现 PlayerEngine 协议（UI 零改动，ADR-0022 接缝兑现）
  → sink 抽象：PlayerSurfaceSink（替代 as? AVPlayerEngine 耦合点）
  → HDR/EDR 自绘（wantsExtendedDynamicRangeContent + 浮点管线）
  → Android P1 同构（MediaCodec；与 Media3 的取舍届时按 RESEARCH-006 §2 复评）
```

FFmpeg 仅作软解兜底（能力查询后启用，不 `--enable-gpl`，RESEARCH-006 §2）。

## 5. 编号说明（防撞号案底：UIA-011→012→014 两次让位）

- **UIA-016~018、021~023、024~027 取号前已 `git fetch` 核对**（2026-10-05 两次核对：task 层远端均空闲）。
- **跳过 UIA-019**：`docs/specs/UIA-019-统一面板框架与四端布局.md` 保留号，
  该任务立项时取 TASK-UIA-019。
- **跳过 UIA-020**：与 `docs/specs/UIA-020-独立视频播放器.md` 同号，防 spec/task
  混淆（两空间独立但同域同号易错引）。
- 发号协议按 [PLAN-三线并行](PLAN-三线并行.md) §2：集成机为发号器，登记即占号。

## 6. 非目标（进阶版本明确不做）

- 不做通用格式播放器承诺（MKV 等随 AVPlayer 能力自然覆盖，播不了走错误横幅）。
- 不做流媒体下载、DRM、账号体系。
- 不做 P3 触发前的任何内核改动（预览/导出/播放 RenderGraph 统一属 P3）。
- 不为低端机写专用降级路径（AGENTS 既有红线）。
- 不做字幕在线下载/翻译（外挂字幕 = 本地文件）。

## 7. 已拍板（2026-10-05 用户：四项"均需要"）

| 原开放问题 | 决定 | 落地卡 |
|---|---|---|
| 网络流播放（HLS/URL） | 纳入 | [UIA-024](TASK-UIA-024.md)（范围收敛为点播，直播流拒绝） |
| 外挂字幕 ASS/SSA | 纳入（样式子集） | [UIA-025](TASK-UIA-025.md)（依赖 UIA-018；libass 引入另评） |
| 播放列表与素材库联动 | 纳入 | [UIA-026](TASK-UIA-026.md)（单向推值过接缝） |
| macOS mini player | 纳入 | [UIA-027](TASK-UIA-027.md)（MenuBarExtra + 生命周期上移） |

规划期遗留的拍板项至此清零；P1/P2 共十卡，均以构建机门禁 PASS 为开工前置。

## 8. 开工纪律

- 每卡开工前 `git fetch` 核对号；一次一个写集，Player 域内六卡串行或按依赖并行。
- 门禁口径以构建机为准（PLAN-三线并行 §1）；
  本机新增代码继续按 Swift 5.5 可解析风格（显式绑定，无 `any P`）。
- 每卡收工走 AGENTS 上下文同步 8 项；媒体管线类改动挂 cq-media-pipeline 六问。
