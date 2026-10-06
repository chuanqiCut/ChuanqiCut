# RESEARCH-006：独立播放器内核选型与交互范式调研

- **状态**：完成（支撑 [SPEC-UIA-020](../specs/UIA-020-独立视频播放器.md) 与 [ADR-0022](../decisions/ADR-0022-独立播放器AVPlayer过渡与内核演进接缝.md)）
- **日期**：2026-10-05
- **范围**：独立"文件播放器"（预览项目导出的成片 + 播放任意本地视频），覆盖**内核**与 **UI 交互**两层
- **数字纪律**：本文所有体积/耗时数字均为估算 [E]；标 [hypothesis] 的为未验证推测，不得作为验收阈值

---

## 1. 背景与关键事实

- 用途差异于编辑预览：编辑预览是"时间线在 pts 这一刻的画面"（自研 RenderGraph 线，`PlayerClock` + `PreviewPump`，**无声**——PALA-030 音频后端未实现）；文件播放器要播**有声成片**与用户任意视频。
- 现有播放链路性能基线：顺序取帧 acquire 4.45ms/帧（MEDIA-021 后，baselines 实测）；播放链路无音频数字。
- 导出产物是普通 mp4（AVAssetWriter H.264 + AAC），AVPlayer 直接可播——"成片播放"与"任意视频播放"在 MVP 内核层无差别。

## 2. 内核候选方案对比

| 方案 | 许可证（闭源 App） | 体积增量 | 集成成本 | HDR | 帧级 seek | 三端覆盖 | 与 C++ 架构契合 |
|---|---|---|---|---|---|---|---|
| **AVPlayer** | 无忧（系统框架） | 0 | 极低 | 优（DV/HLG 自动） | 中（零容差可做，长 GOP 慢 [E]） | Apple only | 低（黑盒） |
| 自研 C++ 播放 session | 无忧 | ~0（复用内核） | 高（2-4 人月 [E]） | 取决自建管线 | 可做准 | 三端 | **最优** |
| FFmpeg 自研集成 | LGPLv2.1+ 可闭源（不 `--enable-gpl`） | 5-10MB/架构 [E] | 高 | 需自建 | 可做准 | 三端 | 高（但绕开内核） |
| libmpv | GPL 为主（LGPL 需自编译裁剪） | 30-50MB [E] | 中 | 有（GL 管线） | 好 | 三端但 GL（Apple 弃 OpenGL） | 低 |
| GStreamer | LGPL | 30-60MB [E] | 中高 | 部分 | 好 | 三端 | 低（管线模型与 RenderGraph 冲突） |
| ijkplayer | LGPL（基于 FFmpeg n3.4，**实质停更**） | ~20MB [E] | 低 | 弱 | 中 | 双端 | 低 |
| MobileVLCKit | LGPL（官方二进制含 GPL 插件风险） | 50-100MB [E] | 低 | 有 | 好 | Apple+Android | 低 |
| Media3/ExoPlayer（P1 参考） | Apache-2.0 | ~3-5MB [E] | 低 | 设备相关 | 设备相关 | Android | 低 |

要点展开：

1. **AVFoundation 限制**：默认 seek 吸附关键帧，零容差 seek 帧精确但需从关键帧解码到目标，延迟随 GOP 变大；近 EOF 落点可能偏短 [E]；方向是"取帧"（`AVPlayerItemVideoOutput.copyPixelBuffer`）而非"喂帧"（喂帧须 `AVSampleBufferDisplayLayer`）。
2. **FFmpeg**：原 FFmpegKit（arthenica）2025 年已退役，须自行交叉编译；VideoToolbox hwaccel 在主线，H.264/H.265/ProRes/VP9 可硬解；iOS 静态链接需按 LGPL 提供目标文件 + 重链接说明。FFmpeg 帧级 seek 的正确姿势 = `avformat_seek_file(AVSEEK_FLAG_BACKWARD)` 落关键帧 → flush → 按 **PTS** 逐包丢弃（B 帧时 DTS≠PTS）。
3. **mpv/GStreamer/ijkplayer/VLCKit 排除理由**：许可/体积/维护状态/管线模型与产品形态不匹配（详表见上）。
4. **行业参照**：CapCut Web 官方确认自研内核（WebCodecs + WASM）而非 `<video>`；原生剪辑 App 无官方披露 [hypothesis：推测平台硬解 + FFmpeg 兜底 + 自研渲染/时钟的混合形态]；Infuse 社区共识为 AVFoundation + mpv/FFmpeg 混合 [hypothesis]。行业形态与本项目红线 #9（预览/导出同一 RenderGraph）同构。

## 3. UI 交互范式

### 3.1 Apple 基线与自研理由

`AVPlayerViewController` 自带播放/暂停、进度条+时间码、PiP、AirPlay、字幕菜单、全屏；但**传输栏样式与进度条不可重绘**，只能 overlay。剪辑类播放器需要"进度条即时间线"（缩略图预览、区间循环），必然自研控制层。SwiftUI `VideoPlayer` 仅薄封装，无定制 API。结论：`AVPlayerLayer` 承载画面 + 自绘 SwiftUI 控制层。

### 3.2 手势与控制层语法（一线产品归纳）

- 单击显隐控制层（3-5s 自动隐藏，触摸重置；Reduce Motion 关动画）。
- 双击快进快退：左半屏 -10s / 右半屏 +10s（YouTube 范式，档位 5-60s 可设是 V1）。
- 左半屏上下滑 = 亮度、右半屏 = 音量（YouTube 范式）。
- 长按倍速（抖音 2x / B站 3x，松手恢复 + 触觉）→ V1。
- 横滑 seek 带缩略图 + 时间气泡（`AVAssetImageGenerator`，放宽 tolerance；全片缩略图网格批量预生成 → V1）。
- 进度条拖动中行业惯例**降音量或静音**（防 pitch 异常"花栗鼠声"），松手恢复。
- 变速音质：`audioTimePitchAlgorithm`——`.varispeed` 变调省电；`.timeDomain` 保音调适合语音；`.spectral` 最高音质适合音乐但 CPU 高。≤2x 场景选 `.timeDomain` 或 `.spectral`。
- 全屏方向按视频宽高比判定（横屏视频 → 请求横屏几何）。

### 3.3 macOS 键盘（对齐 mpv/IINA 权威表）

空格 = 播放暂停；← → = ±5s；，/. = 逐帧步进；0-9 = 跳 0-90%；m = 静音。J-K-L 梭式播放是专业 NLE 范式 [hypothesis：QuickTime 细节未逐一验证]，本期不做。

### 3.4 无障碍与工程细节

- 自定义进度条必须：`accessibilityLabel` + `accessibilityValue`（"3 / 10 分钟"）+ `.adjustable` trait + `accessibilityAdjustableAction`（VoiceOver 上下扫动 seek）。
- PiP 最小接线：`AVPlayerLayer` → `AVPictureInPictureController(playerLayer:)` **强引用** + `canStartPictureInPictureAutomaticallyFromInline = true`（退后台自动进）+ Background Modes 勾 Audio + `AVAudioSession` category `.playback`。
- 中断（耳机拔出/来电）AVPlayer 默认自动暂停，无需自写逻辑。
- 息屏：`isIdleTimerDisabled` 仅在播放中置 true。
- 起播延迟（本地文件）：`automaticallyWaitsToMinimizeStalling = false` + 提前创建 asset/item + `play()` 而非 `setRate`。
- HDR：`AVPlayerLayer` 自动支持 Dolby Vision/HDR10（EDR）；自定义 Metal 层需 `wantsExtendedDynamicRangeContent` + 浮点像素格式——这是未来自研 C++ 引擎接 RenderGraph 的主要额外成本 [E]。

### 3.5 剪辑类播放器的差异点

成片预览 ≠ 通用播放器：① 所见即所得（预览与导出同一渲染管线）；② 帧级步进与时间码对齐（`. ,`）；③ 区间循环（A-B loop，校对转场）→ V1；④ 导出参数（比例/HDR/色彩空间）在预览中如实呈现。

## 4. 结论（→ ADR-0022）

- **MVP 内核 = AVPlayer**：唯一能立刻交付"有声播放"的路径（自研线无声）；系统框架零许可零体积；HDR/PiP/后台播放免费。
- **接缝先行**：控制层只依赖 `PlayerEngine` 协议（play/seek/rate/状态回调），AVPlayer 是该协议的**平台实现**；未来 C++ 播放 session（复用 `PlayerClock` + `PreviewPump` + PALA-030 音频后端）落地时换实现不换 UI。
- **明确排除**：mpv / GStreamer / ijkplayer / MobileVLCKit。
- **功能分档**：见 SPEC-UIA-020 §5（MVP 必做 / V1 应做 / V2 可做）。

## 5. 风险与未验证项

- AVPlayer 零容差 seek 在长 GOP 源上的延迟未实测 [E]——真机验收时补 baselines。
- `AVAssetImageGenerator.image(at:)` async 版的 Swift 6 Sendable 标注完整性 [hypothesis]——构建机编译确认。
- B站长按 3x / 抖音双击等竞品细节来自社区拆解 [hypothesis]，V1 落地前真机核对。
- 自研 C++ session 的 HDR 输出管线（DV metadata 透传）工作量未评估 [hypothesis]。

## 6. 来源

- 内核：[FFmpeg legal](https://www.ffmpeg.org/legal.html) · [FFmpegKit 退役](https://github.com/arthenica/ffmpeg-kit) · [mpv render_gl](https://github.com/mpv-player/mpv/blob/master/libmpv/render_gl.h) · [GStreamer FAQ](https://gstreamer.freedesktop.org/documentation/frequently-asked-questions/general.html) · [ijkplayer](https://github.com/bilibili/ijkplayer) · [VLCKit 与 App Store](https://mjtsai.com/blog/2024/04/19/vlc-vs-the-app-stores) · [Media3 支持格式](https://developer.android.com/media/media3/exoplayer/supported-formats) · [CapCut Web 案例](https://web.dev/case-studies/capcut)
- 交互：[AVPlayerViewController](https://developer.apple.com/documentation/avkit/avplayerviewcontroller) · [自定义播放器接 PiP](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player) · [audioTimePitchAlgorithm](https://developer.apple.com/documentation/avfoundation/avplayer/audiotimepitchalgorithm) · [AVAssetImageGenerator](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator) · [WWDC22 responsive media app](https://developer.apple.com/videos/play/wwdc2022/110379) · [mpv 手册](https://mpv.io) · [音频中断处理](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
