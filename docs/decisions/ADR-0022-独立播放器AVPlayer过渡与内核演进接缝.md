# ADR-0022：独立播放器 MVP 走 AVPlayer 过渡，以协议接缝保留 C++ 内核演进

- **状态**：已批准（MVP 同日实施）
- **日期**：2026-10-05
- **相关**：RESEARCH-006（内核对比与交互范式）· SPEC-UIA-020 · ADR-0014（相机 UI 域豁免先例）· ADR-0015（相册浏览器先例）· ADR-0016（预览取帧线程归属）· ADR-0017（顺序取帧快路径）· ui-apple.md

## 背景

独立文件播放器（预览导出成片 + 播放任意本地视频）需要"有声播放"。已核验的事实：

1. 自研预览线（`PlayerClock` + `PreviewPump` + RenderGraph）**无声**：PALA-030（AVAudioEngine 后端）在 BACKLOG 未实现，`core/src/audio/` 不存在。复用自研线做 MVP 须先补音频后端，交付时间不可控。
2. 用户要求当晚交付 MVP；编辑内核改造成播放 session 的工作量为 2-4 人月 [E]。
3. 仓库已有 UI 域系统 API 豁免先例：相机走 iOS 原生栈（ADR-0014）、相册浏览器走 PhotoKit（ADR-0015）。播放器 MVP 的性质相同——"UI 域消费系统能力"，且导出成片是普通 mp4，AVPlayer 原生可播。
4. 若直接把 AVFoundation 调用散进控制层/视图，未来换 C++ 内核时 UI 全线返工——需要一个**接缝**把"内核实现"与"交互 UI"解耦。

## 决策

1. **MVP 内核 = AVPlayer**（系统框架：零许可/零体积/零依赖变更；HDR、PiP、后台播放、中断暂停全部系统承担）。这是**过渡实现**，不是终态。
2. **接缝先行**：SharedUI/Player 域内控制层与 ViewModel 只依赖 `PlayerEngine` 协议（load/play/pause/seek/rate/volume/状态回调）；`AVPlayerEngine` 是该协议的已知实现。未来 C++ 播放 session 落地时新增 `CQPlayerEngine` 实现，UI 不改。
3. **不动 core/ 与 C ABI**：MVP 零内核改动，规避 BIND 协调与高冲突文件。`cq_player_*`（时间线播放时钟）语义不变，文件播放器不与其混淆。
4. **AVFoundation 使用边界**：AVFoundation 只允许出现在 Player 域的引擎/画面/缩略图文件（`AVPlayerEngine`、`PlayerSurface`、`VideoThumbnailLoader`）；控制层、ViewModel、App target 不 import AVFoundation（协议接缝之外不得泄漏平台播放类型）。
5. **长期演进路线（登记，不立项）**：PALA-030 落地后，基于 `core/preview/`（PlayerClock + PreviewPump + ADR-0017 顺序快路径）改造 C++ 播放 session：demux loop + 音视频双队列 + 主时钟 + PAL 硬解；画面走 RenderGraph 输出（红线 #9：预览/导出/播放同一张图，只换输出目标与时钟源）；Android P1 同构接 MediaCodec。FFmpeg 仅作软解兜底（能力运行时查询，红线 #3），不 `--enable-gpl`。
6. **明确排除** mpv / GStreamer / ijkplayer / MobileVLCKit（许可、体积、维护状态或管线模型与产品形态不匹配，对比见 RESEARCH-006 §2）。

## 备选方案

| 方案 | 否决理由 |
|---|---|
| 复用自研预览线做 MVP | 无声（PALA-030 未实现）；成片播放须音频后端先行，交付时间不可控；且编辑预览与文件播放器语义不同（时间线 vs 容器文件） |
| FFmpeg 自研集成 | 5-10MB/架构 [E] + 自建 demux/时钟/音频输出 = 自研内核子集再背体积；FFmpegKit 已退役需自行交叉编译；LGPL 静态链接合规负担 |
| mpv/libmpv | GPL 为主（LGPL 需自编译裁剪）；render API 仅 GL 后端成熟，Apple 已弃 OpenGL；30-50MB [E] |
| MobileVLCKit / GStreamer / ijkplayer | 体积大 [E]；官方二进制 GPL 插件风险 / 管线模型冲突 / 实质停更 |

## 后果

**正面**

- 当晚可交付有声 MVP；HDR/PiP/后台/中断/字幕组全由系统框架承担。
- 协议接缝让"换内核"成为纯引擎层替换，UI 层零返工。
- `core/` 零改动，规避高冲突文件与双机协调。

**负面 / 成本**

- AVPlayer 黑盒：帧级 seek 精度/延迟受 GOP 影响，近 EOF 落点可能偏短 [E]；格式覆盖受限（MKV 等），不能播的走错误横幅。
- 画面 sink 与 `AVPlayer` 类型临时耦合（`PlayerScreen` 中 `as? AVPlayerEngine` 取 AVPlayer 绑 layer）——接缝只覆盖控制语义，不含画面抽象。
- 长期会出现两条播放实现并存期（AVPlayer 文件播放 vs C++ session 时间线播放），需要边界文案管理。

**缓解**

- sink 抽象（`PlayerSurfaceSink`）推迟到 C++ session 立项时一并设计，避免为单一实现预抽象。
- "AVFoundation 边界"写入 `.ai/modules/ui-apple.md` 与 workbuddy 长期规则，代码审查按域检查。
- seek 精度/起播延迟在真机验收时实测回填 baselines，替代估算。

## 反转条件

- PALA-030 落地且产品要求"成片预览与导出画面一致（HDR/色彩管理）"或三端统一播放行为 → 立项 C++ 播放 session，AVPlayer 降级为"格式兼容兜底"。
- 产品定位扩展为通用格式播放器（MKV/多音轨等 AVPlayer 覆盖不了的场景）→ 重估 FFmpeg 兜底集成。

## 落地任务

`TASK-UIA-015`（伞任务：接缝 + AVPlayerEngine + 控制层 + 缩略图 + 平台接线）
