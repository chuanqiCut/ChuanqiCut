# 周报 W42（截至 2026-10-12）· 第二刊

> 覆盖窗口：**2026-10-08 ~ 10-12**（W41 周报止于 10-07，本期补齐 10-08~10-11 未覆盖的四天 + 10-12 当日）。
> 出刊：集成机（Intel x86_64 / macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / cmake 4.4.3）。
> 数字纪律：**只写实测**，估算标 `[E]`、推测标 `hypothesis`；门禁数字写具体 PASS/FAIL，不写"全绿"。
> 本期结构在原六节（项目介绍/架构/进度/数字/目标/风险）之上，按传哲要求扩充：**技术细节、Pipeline、优缺点、优化路径、分工进展**。

---

## 0. 本期速览

1. **门禁口径升级**：全量 `run_gate.sh` **PASS=14 / FAIL=0 / SKIP=0（22m14s）**，内核 ctest Debug/Release 各 **48/48**；相机 77、编辑器 65、播放器 52、导入 16、绑定 26，全部 0 failure。
2. **编辑能力第一次真正长出来**：EDIT-007/008（分割·删除·左缘裁剪）+ EDIT-009/010（跨轨移动·画布）+ UIA-039/040（接轨道区 + 面板分级/画布/多轨）——**内核到 UI 一条链打通**，不再是"命令有了没入口"或"入口有了没命令"。
3. **依赖线收口**：FFmpeg 9.0.2 demux 档真实接入（5 slice 链接闭合 5/5、GPL 扫描 0 命中），拆出 `ChuanqiCutFFmpeg` 独立 Pod（ADR-0038），LGPL 义务载体落定（ADR-0036）。
4. **架构与工程地基**：`PAL→Platform` 全量改名（ADR-0035）、内核 Chq 前缀（ADR-0039）、壳工程冻结入库退役 XcodeGen（ADR-0037）、Engine 源码共置与双 Pod 边界（ADR-0033）。**本周新增 7 份 ADR（0033~0039）**。
5. **最该记住的一条**：**现在还不能导出成片**。`cq_sdk.h` 里没有任何 `cq_export*`；B0（RenderGraph）未开工、SPIR-V 链零文件。**门禁是绿的，但绿 ≠ 能出片**——这正是 P99 说的"绿而空"，本期第一次把它写进周报。

---

## 1. 项目介绍

ChuanqiCut = **跨平台视频编辑 SDK + 各端原生 App**。

- `engine/core/cq/` = C++20 共享内核（时间/模型/命令/媒体/渲染/音频/预览/会话），对外**纯 C ABI**；
- `engine/platform/apple/` = 平台适配（Metal / AVFoundation / VideoToolbox / CoreImage），Android·HarmonyOS 目前**只有 CMake 骨架，零源码**；
- `apps/apple/{ios,mac,packages}` = 各端原生 UI（SwiftUI 外壳 + UIKit 三件套）。

平台节奏：iOS + macOS（P0）→ Android（P1）→ 鸿蒙（P2，仅接口预留）。性能基线 = **高端满足、中端可用、明确不适配低端机**；能力缺失降级照做（无硬解→软解），但不为低端机写专用路径。

协作形态（ADR-0029/0030 修订）：本机 = **集成机**（唯一发号器、全局册单写者、全量门禁与真机唯一验收口径、热点文件守门）；远端开发机 = 编码优先（模块级自查 + 待办池登记）。**本周同工作区多 agent 并行成为常态**（相机线 / 编辑线 / 依赖线 / 基建线同时跑），写集不相交是硬约束。

---

## 2. 技术架构（代码实况，不是愿景图）

### 2.1 三层与 Pod 拓扑

```
┌─ 壳 App（apps/apple/ios + mac）：路由/权限/装配，零业务
│    ├─ ChuanqiCutEngine   Swift 绑定层
│    │     └─ ChuanqiCutCore   C ABI + C++20 内核 + Apple Platform（唯一 public 头 cq_sdk.h）
│    │           └─ ChuanqiCutFFmpeg  vendored xcframework（LGPL-2.1，独立 Pod，ADR-0038）
│    ├─ SharedUI        基座（仅 Common/，三个跨域注入器）
│    ├─ ChuanqiCutEditor / Player / Import / Camera(iOS 专属) / Draft(骨架)
└─────────────────────────────────────────────────────────────
功能 Pod 横向零依赖；跨域交接走基座注入器 + 壳装配。
```

- CMake：`third_party → engine/core → engine/platform → apps → tools → tests`；主目标 `cq_core`（约 30 TU）、`cq_platform_apple`（10 个 .mm）、`cq_ffmpeg`。
- 警告集 `-Wall -Wextra -Wconversion -Wshadow -Wold-style-cast` **+ `-Werror`**，**禁止 `-Wno-*` 逃逸**。
- 顶层 `LANGUAGES C CXX` 的 C 不是历史遗留——是为了让 `test_c_abi*.c` 成为**真正的 C 翻译单元**，以此机器校验 ABI 纯净性（实测塞进 `std::string` 立即 fatal error）。

### 2.2 内核子模块（`engine/core/cq/`，实际目录）

| 子模块 | 职责一句话 | 状态 |
|---|---|---|
| `base` | 有理数时间 `ChqRationalTime`、状态码、日志（含 workflow 维度）、纹理预算账本、并发原语 | 已实现 |
| `platform` | **Platform 契约头（仅声明）**：gfx/media/audio/inference/fs/clock/log/capabilities/net 九域 | 已实现·冻结 |
| `model` | `ChqTimeline/Track/Clip` + `ChqEditorModelState` | 已实现 |
| `command` | `ChqICommand` + `ChqCommandHistory`（Undo/Redo） | 已实现 |
| `session` | `ChqEditorSession` 门面 + `ChqTaskRunner`（session 线程）+ 8 类线程角色 | 已实现 |
| `media` | 帧缓存 LRU、解码器池、`ChqSystemFrameProvider`（精确 seek 编排）、`ChqAssetRegistry` | 已实现 |
| `gfx` | `ChqIGfxDevice`/`ChqIGfxEncoder` 编排层（在 HAL 之上） | 已实现（**无 RenderGraph**） |
| `preview` | 预览渲染器、取帧泵 `ChqPreviewPump`、墙钟播放时钟 | 已实现 |
| `audio` | PCM 池、SPSC 无锁环、`ChqPreviewMixer`、C ABI | 已实现·MVP |
| `ai` | **只有 `ChqEditPlan` JSON 校验器 + golden 样例**，无推理运行时 | 已实现·仅 plan 校验 |

**关键否定事实**：内核里**没有** `graph/`、`effect/`、`render/`、`export/`、`project/`、`retime/`、`inference/` 目录。ARCH-001 §4.1 那张 12 模块表是愿景，实际落地 10 个。

### 2.3 跨层接口

- **C ABI**：`engine/core/cq/cq_sdk.h`，**76 个 `cq_*` 函数**（2026-10-12 实测）。分组：session 29 / preview 19 / player 11 / status 4 / audio 4 / version 3 / 线程角色 2 / log 2 / capability 1 / media 1。**65 个函数零 stub**（工程是诚实的），但**覆盖域只有六件事**：会话生命周期、能力查询、时间线 CRUD、命令与撤销、单轨预览渲染、播放时钟。
- **Swift 绑定**：`engine/bindings/swift/Sources/ChuanqiCut/`（Session / Previewer / PreviewPump / PreviewAudio / Player / Timeline / Time），经 `module.modulemap` + `shim.c` 桥 `ChuanqiCutCore`。注意 Swift 侧预览类叫 **`Previewer`**（避免与 SwiftUI `Preview` 撞名）。
- **Platform 契约 vs 实现**：契约 `engine/core/cq/platform/*.h`（9 域，头文件零平台类型，红线 #2）；Apple 实现 `engine/platform/apple/{base,gfx,media}/`。门禁 `tools/platform/check_platform_headers.py` **实测有效**（插 `jobject` 会被抓），改名后 **41 头 0 违规**。跨层靠 opaque 句柄 + `ChqPlatformPtr<T>` RAII。

---

## 3. 关键 Pipeline

### 3.1 预览渲染（已实现：单轨、单片段、无效果链）

```
FindClipAt(pts) → AssetRegistry 取路径 → FrameProvider.AcquireFrame(精确 seek + 硬解)
  → INativeImageImporter(CVPixelBuffer → CVMetalTexture，零拷贝)
  → IBlitPass.Encode（离屏 RenderTarget）→ 导出纹理句柄给 UI
  → MTKView.draw: unsafeBitCast(handle→MTLTexture) → blit → present
```

- **零拷贝是真跑通的**：源 IOSurface ID 与导入纹理 IOSurface ID 实测相同；**零拷贝 ≈0.003ms vs CPU 退化 ≈5.1ms（约 1500× 代差）**；真机 import 段 p50 0.0ms / p95 0.2ms。
- **线程模型**：主线程只 `request + Lock/blit/Unlock`；**取帧·解码·离屏绘制全在 `ChqPreviewPump` 线程**；blit 必须与内核共用同一条 `MTLCommandQueue`（`cq_preview_shared_queue()`）。硬约束：`RenderFrame`/`Resize` 只由泵线程调用；**持锁期间禁调 Request**（P36 实踩死锁）。
- 播放时钟 `ChqPlayerClock`：`t = anchor + (now - anchor_wall)`，整数帧网格量化，时钟自己不跑线程。
- **实测瓶颈**：连续递进单帧 total **99.3ms，取帧占 94%**；App 侧 1s 播放 1280×720 Debug：请求 59 / 渲染 3 / 合并 54——**帧率瓶颈在取帧策略，不在线程模型**。MEDIA-021 顺序快路径把 120 帧 acquire 从 93.3ms 降到 **4.45ms（Release）**。
- ⚠️ **多轨/合成/RenderGraph 明确未做**：`chq_preview_renderer.cpp:215` 直写"只取第一条命中的视频轨（本期不支持多轨合成）"，且这条"本期明确不支持"已写进头文件。模型层已支持多轨（`MoveClipToTrack` 已落地），**渲染只画第一轨**。

### 3.2 媒体管线

```
导入：PHAsset.fetchAssets → PHAssetResourceManager 落我方 tmp（处理 iCloud）
probe：cq_media_probe_duration（独立 TU，毫秒级）
demux：AVURLAsset + AVAssetReader（outputSettings=nil = passthrough，demux 不含解码）
解码：VTDecompressionSession（异步），H.264 + HEVC('hvc1'/'hev1'/杜比视界基底)
seek：kExact/kKeyframeBefore/kNearest —— demux 到 ≤t 关键帧 → 前向解码 → 区间归属
缓存：ChqLruFrameCache（lease = move-out 模型，杜绝 use-after-free）
     ChqDecoderPool（默认最大硬件路数 1，超限返回 kResourceExhausted，不抢占不降级）
闸门：解码输出队列上界 12 帧；缺口判定 streak 8；Flush 改轮询+1s 超时（VTWait 会永久阻塞）
```

- **FFmpeg 定位**：**仅 demux/probe 档，无解码器**（`manifest.toml` profile="demux"）。唯一消费 TU 是 `chq_ffmpeg_probe.cpp`；`FFmpegFrameProvider` **未开工**。
- ⚠️ 适配层 `ChqPlatformFrameProvider` 非 `kExact` 策略一律拒，且 `SetFrameCache/SetDecoderPool` 在此**不生效**——这是**当前预览没接帧缓存的直接原因**。

### 3.3 编辑与时间线

```
手势 → EditorViewModel.submit() → C ABI → ChqEditorSession
     → ChqTaskRunner（kSession 线程，串行）→ Command → 发布不可变快照{version, digest(FNV-1a)}
     → 观察者回调 → Task{@MainActor} → UI diff 刷新
```

- **UI 不得直接改模型**（红线 #5）是硬约束；`Submit` 异步不阻塞，实测 **0.005~0.010ms**，**刻意不提供 `SubmitAndWait`**。
- 命令只存增量（clipID + old/new），不存数据拷贝；**Add/Insert 重放必须走 `RestoreTrack/RestoreClip` 恢复原 id**（否则后续命令引用悬空），已由 C ABI 实证：全 undo→全 redo，clip id 与撤销前**完全相同**。
- 时间：**项目 timescale = 120000**（ADR-0009 从 60000 改，因 60000 不能整除 24000 → 23.976fps 单帧非整数）；`static_assert(!is_convertible_v<ChqRationalTime, double>)`，唯一浮点出口 `ToSeconds()` 仅供日志/UI。
- **UIKit 三件套确实存在**（ADR-0024）：`EditorViewController` / `EditorTimelineUIView` / `EditorToolbarUIView`；播放头用 CADisplayLink 直读 `vm.playhead`，**每帧只改一个 CAShapeLayer 的 path，SwiftUI 零参与**。时间线单 UIView 自绘，实测 **500 片段（5轨×100）布局 0.663ms/帧**。
- ⚠️ **持久化 PROJ-001 未开工**：`core/` 下没有 project 目录，**项目状态只活在内存 Session，进程退出即丢**。

### 3.4 音频（AUDIO-002，本周一次贯通）

`ChqIAudioTrackReader`（契约）→ `ChqPreviewMixer`（时间线→PCM：快照命中 + 逐 clip 独立读位 + 求和混音削波 + 漂移护栏 + 欠载重锚）→ Apple 侧 `AVAssetReader` PCM 输出 + `AVAudioEngine`/`AVAudioSourceNode` + **SPSC 环（唯一无锁执行点）** → C ABI `cq_audio_preview_*` → Swift `PreviewAudio`。

**音画同步 MVP（诚实边界）**：**视频（墙钟）为主、音频为从**；缓冲区与外推播放头差 **>120ms → Flush + 重锚**；欠载 = 静音缺口（不伪造）。
⚠️ ARCH-001 §5.3 的"以音频为主时钟"是愿景，**当前实现相反**；全量音画同步归 MEDIA-030（未开工）。⚠️ **真机出声、漂移/欠载分布均未实测**。

### 3.5 相机（iOS 原生域，不经 SDK/C ABI，ADR-0014）

```
采集 CameraManager（AVCaptureSession，配置/启停全在 sessionQueue）
   ├ videoQueue → CameraFrameSlot.push（latest-wins，不排队）
   └ audioQueue → CameraRecorder.appendAudio
检测 AVCaptureMetadataOutput 系统脸框（零 Vision）+ Vision 按需开关（BeautyDetectionPlan 纯函数决定）
渲染 CameraPreviewRenderer（MTKViewDelegate）
   ✗ CI → drawable                    （framebufferOnly 缺 ShaderWrite → 静默黑屏，P60）
   ✗ CI → 中间纹理 → blit → drawable  （Metal 禁对 framebufferOnly 纹理 blit → SIGABRT，P65）
   ✓ CI → 自建中间纹理(ShaderWrite|ShaderRead, private) → 显式 UV 渲染 pass → drawable
录制 CameraRecorder（AVAssetWriter + PixelBufferAdaptor），与预览/拍照共用同一条「美颜→滤镜」链（WYSIWYG）
```

- 拍摄**不走** `ChqIMediaMuxer`（ADR-0014 豁免），能力其实齐备。
- MetalFX（CAM-022）运行时 `supportsDevice()` 查询，不支持则跳过（诚实降级）——它的 `import MetalFX` 是池 [16] 的源头。

### 3.6 Shader 两层（**现状是"降级"，不是"优化"**）

| 层 | 位置 | 实况 |
|---|---|---|
| Portable（`shaders/src/*.glsl` → SPIR-V → MSL） | `shaders/src/` **只有 `.gitkeep`，0 个 .glsl**；`tools/shaders/` 空；glslang/SPIRV-Cross 源码未落地 | **链从未跑通** |
| Platform-Native | `blit_fullscreen_msl.h`（MSL 以 raw string 内联进 .h） | 已实现，**但是能力缺失降级路径**（该文件 :4-7 自陈） |
| App 域特效 | `ChuanqiCutCamera/.../Effects/{beauty_bilateral,beauty_guided,face_warp}.metal` | 已实现，Xcode 编进 `default.metallib` |

CoreImage kernel 与自研 Metal **并存且有分工**：磨皮 = 自研双边/引导滤波（两 pass，亮度域，参数对滑杆单调不减）；滤镜/美妆蒙版/径向渐变 = 系统 `CIFilter`。**黏性回落纪律**：引擎闭包连续 3 次 nil → 本会话停用、只走默认 CI（否则逐帧在两种视觉间翻转 = 真机"磨皮闪屏"主嫌）。产物验收：编译绿 ≠ metallib 可用，`strings | grep cq_beauty` 必须出现两个 kernel 名（96B = 空壳），实测 **9391B** 且齐全。

---

## 4. 当前实现的优点（做对了什么）

**架构层面**

1. **红线执行有机器背书**：Platform 契约零平台类型靠门禁强制（41 头 0 违规）；ABI 纯净性靠真 C TU 校验；有理数时间靠 `static_assert` 固化。**不是靠自觉。**
2. **零拷贝链真跑通并有实测**——1500× 代差、真机 import p50 0.0ms。
3. **线程归属固化**：预览泵线程 / session 线程 / 主线程 / 音频 SPSC 环各司其职，相关约束写进了模块册（ADR-0016/0012）。
4. **命令与撤销栈方向与工业 NLE 一致**（RESEARCH-014 §4 对照表：快照式撤销 ✅、两层 GPU HAL ✅、Track/Clip 模型 ✅），无需翻案。
5. **"禁临时方案"真的拦住过事**：传哲 10-10 否掉「导出优先」和「文字先 Swift 顶着」两个临时方案，理由是本仓已因「相机滤镜 vs 编辑器特效两套实现」背过一次债（ADR-0014 代价）。**第二次两套渲染路径被拦在开工之前。**

**工程机制层面（这是本仓最硬的资产）**

6. **全量门禁 `run_gate.sh`**：deps / headers / artifacts / core-dbg / core-rel / apple（XCFramework+绑定+5 Pod）/ golden，**一票否决**；artifacts 步是 P84 事故转化来的制度（产物入库一票否决）。
7. **可追溯三件套**（ADR-0034）：`LEDGER-W42.md`（六字段：时间/执行者/决策/写集/验证/拍板，append-only）+ 真机问卷模板 + 实例问卷；**问卷未回收不得标记完成**。
8. **TODO-POOL 待办池**：开发机只 append，清扫/编号只归集成机（P82 事故固化）。
9. **pitfalls 坑库 P1–P124**，每条含日期/来源/验证状态，未验证标 `hypothesis`。
10. **真机 SOP + 自动探针 + CrashProbe**：30 秒内抓出 metadata 装配崩溃；十一轮取证后 SIGTRAP 归零。DebugCenter 浮层 2Hz 采样内存与逐线程 CPU。

**已跑通的链路与实测数字**

11. 播放 5s 冻结 + jetsam 修完：真机**跑满 t=121.99s**，footprint **134~184MB** 平稳，`nonok/s=0`（修复前 3375MB 单调涨 + signal 9）。
12. MEDIA-024 后：真机 `pump_rendered/s` **74 → 120（ProMotion 满帧）**，acquire p50 **0.0ms**，total p50 **1.2~1.8ms**。
13. 美颜真机 **1.6~3.0ms/帧满帧**；Vision 单次 **11.6~20.3ms**（iPhone 17 Pro）。
14. App 净启动成本 **≈0**（与空壳参照 App 无统计差异，Intel i7-9750H / macOS 26.7.1）。
15. INFRA-022 改 174 文件后 ctest **46/46 零回归**；`apps/` 体积 **5.5G → 4.3M**。

---

## 5. 当前缺陷与技术债

### 5.1 结构性缺口（功能级没有）—— 最要紧的五个

| # | 缺口 | 证据 | 影响 |
|---|---|---|---|
| 1 | **导出链整体未做** | `cq_sdk.h` 无任何 `cq_export*`/`cq_encode*`；`export.md:44`"未做（P0 缺口：导出按钮置灰）" | **一个不能出片的剪辑软件，其余做得再好也只是 Demo**。⚠️ 底层能力其实具备（`AppleVideoEncoder` + `AppleMediaMuxer` 已编译进产物，H.264+AAC MP4 实测可写），**缺口在上层导出控制器（状态机/进度/取消）+ C ABI 暴露** |
| 2 | **RenderGraph 未做** | 内核无 `graph/` 目录；`engine/core/CMakeLists.txt:53-55` 明写"不做 RenderGraph" | 红线 #9「预览与导出走同一张 RenderGraph」**目前是纯愿景，代码里是两条独立路径**；多轨/文字/滤镜全部排队等它 |
| 3 | **Portable shader 链从未跑通** | `shaders/src/` 零 .glsl；`blit_fullscreen_msl.h:4-7` 自陈 | B0 的前置；开工前必须先做极窄 spike 验通 glsl→SPIR-V→MSL |
| 4 | **属性系统 MODEL-003 未落地** | `cq_sdk.h:312`"那是 MODEL-003 属性系统的事" | 卡住音量/变速/滤镜参数/文字样式 |
| 5 | **草稿持久化零实现** | 内核无 project 目录；`ChuanqiCutDraft` Pod 仅骨架 | 关 App 即丢；草稿箱无地基 |

补充：音频只到 MVP（视频主时钟）；对标 App P0/P1 能力大面积缺（BGM/音量/关闭原声/文字/转场/滤镜/调参/淡入淡出/关键帧/ASR）；**macOS 桌面形态未做**（全仓零 `CommandMenu`，常驻 Inspector / 工具栏 / 多窗口 / 快捷键全表 / Finder 拖拽均未落地，Mac 端可见能力**少于** iOS）。

> **更正（避免误报）**：RESEARCH-010（2026-10-10）列的"无 SplitCommand / RemoveClip 不对外 / 左缘裁剪明确不做 / CreateAudioEngine 无实现"四条，**已于 10-11~10-12 被 EDIT-007/008、AUDIO-002 补上**，但文档未回填。**引用旧缺口清单前必须对着 commit 核。**

### 5.2 工程与流程缺陷

- **门禁不含 App 壳构建 = 伪绿之源（池 [18]）**：`run_gate.sh` 六步里没有 iOS/macOS 壳构建。实证——`face_warp.metal` 改签名后**门禁全绿但 shader 一行没被编译过**，P123 只在真机日志里暴露。
- **文档与代码状态不一致**：RESEARCH-010 缺口清单未回填；BACKLOG 写集路径整体过期（`core/src/*` → `engine/core/cq/*`，P98）；`docs/api/engine-api.md` 生成源路径已不存在且缺 6 个新函数；TASK-CAM-034/035 卡片仍写"待开工"但代码已落地。
- **「完成 = 门禁通过」缺用户可见性一栏（P99）**：`enabled:false` + 空闭包的占位按钮在编译和单测里**完全静默**；全仓 `Sources/` 零 `TODO`/`FIXME`。ADR-0034 已把"禁止空闭包"升为硬规则，但 AGENTS.md 口径未改（待传哲拍板）。
- **并行会话写集污染（重复发作）**：P120（10-11 相机会话 `d31e6b8` 把带缺陷的 EDIT-007/008 卷入，HEAD 一度是坏版本）、P86 同机双会话、P82 双机编号分叉、P109 发号撞号。规约都写了，10-11 仍复发。
- **估算当实测 / 验证债务挂账**：UIA-037/038 的 `swift test` 与 iOS 构建"用户指示跳过未跑"，baselines 该节自陈"**本节零实测数字**"；播放器 UIA-015 **16 项全部未实测**。
- **Intel 本机限制被当验证口径**：mac 壳命令行默认 universal 必挂（P96）；本机无 ANE / ProRes 硬编；VFR 素材复现不出。**本机数字不得作产品阈值。**

### 5.3 已知未取证的运行时问题（**全是 hypothesis，取证前不改代码**）

- **真机内存单调增长 → jetsam（池 [17]①）**：播放段 footprint **188.0 → 282.4MB**（t=2→10s），相机长跑 3300+ 帧后 Metal 断言 + **signal 9**。三个候选（编辑会话未随切页释放 / CIContext 逐帧 DAG 缓存 / 相机 scratch 纹理重建泄漏）**均未实测**，取证手段定为 Xcode Memory Graph。
- **主线程同步 I/O（池 [17]②，违红线 #8）**：`importMedia` 是 `@MainActor` 同步调用，内部仍 `dispatch_semaphore_wait` 等 Default QoS 回调——**优先级反转的结构没变，P122 只把 967ms 降到毫秒级**。
- **PHAsset 元数据按需取（池 [17]③）**：`Missing prefetched properties` 警告，Photos 明确提示会掉帧。
- **iOS 模拟器全壳构建红（池 [16]）**：`import MetalFX` 自 `fdb4e97` 起即红，挡住编辑器线全壳证据。
- **macOS 通用双架构构建红（池 [14]）**：CP 1.17 Swift Compatibility Header 共享路径。
- **桌面 soak 吞吐退化未定位**：acquire p95 158→401ms、wall 178s→306s（同素材）。

---

## 6. 未来优化路径

### 6.1 编辑能力对齐批次（RESEARCH-010 §5.2，B0~B8）+ 2026-10-12 实况

| 批次 | 出口标准 | 卡 | 依赖 | **当前实况** |
|---|---|---|---|---|
| **B0 渲染地基** | 单轨画面经 RenderGraph 出到预览，与原 blit 路径像素一致 | RENDER-001（最小 RenderGraph）+ MODEL-003（属性与 EffectBinding）+ SHADER-001（glsl + SPIR-V 链） | 需 ADR 反转 CMakeLists 的"不做 RenderGraph" | **未开工**。RESEARCH-014 已给范围修订建议，**待传哲拍板** |
| **B1 模型命令** | Split / RemoveClip / RemoveTrack / 左缘裁剪经 C ABI 可用且有单测 | EDIT-007/008 | MODEL-002 | ✅ **已完成入库**，UIA-039 已接轨道区；顺带完成 EDIT-009/010 |
| **B2 音频地基** | 预览出声；多轨 PCM 混音电平正确 | PALA-030 + AUDIO-004 | AUDIO-001 | **部分完成**：AUDIO-002 全链已落地（ctest 48/48）；真机出声与漂移分布未实测；AUDIO-004 未做 |
| **B3 工程持久化** | 项目可存可恢复，往返序列化一致 | PROJ-001 | MODEL-001 | **未开工**（独立支线，写集不冲突，随时可插） |
| **B4 第一个可见出口** | **导出 MP4 到相册，且预览与导出结果一致** | EXPORT-001 + `cq_export_*` ABI + UIA-007 + EXPORT-003 | B0 + B1 | **未开工** |
| **B5 音频可见能力** | BGM / 调音量 / 关原声 | EDIT-011 | B2 + B4 | 未开工 |
| **B6 文字与贴纸** | 打字、改样式、加贴纸，预览=导出 | EDIT-004/005 | B0 + SHADER-001 | 未开工（UIA-040 只做了抽屉入口占位） |
| **B7 视觉效果** | 滤镜 / 调参 / 转场 / 变速 | RENDER-012 + EDIT-001 | B0 | 未开工 |
| **B8 进阶** | 关键帧 / 蒙版 / 混合 / 抠像 / ASR | ANIM-001 + EDIT-003 + AI-023/024 | B7 | 未开工 |

### 6.2 并行拓扑（写集互不相交）

```
B0 渲染地基 ─┐
B1 模型命令 ─┼─ B4 导出闭环 ─ B5 音频能力 ─ B6 文字贴纸 ─ B7 视觉效果 ─ B8 进阶
B2 音频地基 ─┘
B3 工程持久化 ── 独立支线，不与任何批次争写集，随时可插
```

**真正串行的是 B4 之后**：每个可见能力批次都依赖 B4 建立的「预览 = 交付」一致性保证。这也是传哲 10-10 排期反转（地基先行、导出推后到 B4）的含义——**先保证只有一条渲染路径，再往上堆能力**。

### 6.3 其他已提出的优化方向

1. **RENDER-001 范围修订**（RESEARCH-014）：从"节点 DAG + 拓扑排序"扩为「拓扑/环检测 **+ 装配器（预览/导出/纯音频三图同源）+ 时钟源接口 + Push/Pull 分区」；验收加"预览图与导出图同一装配器产出"。**立卡前必答 Push vs Pull**。
2. **音画同步 MEDIA-030**（audio master clock，验收 A/V 偏差 ≤1 帧）。
3. **面板配置化**（RESEARCH-013）：`PanelDescriptor` + `PanelRegistry`（对齐字节 其创作 SDK 的 `Panel_configs/*.json`），需与既有 `SPEC-UIA-019` 分层合并避免撞设计（P80/P81）。**待拍板**。
4. **轨道交互收敛为单一纯逻辑**（RESEARCH-013 P0）：抽 `TrackInteraction` reducer，消除 SwiftUI `commit` 与 UIKit `commitDrag` **两份手势逻辑**——现正踩 ADR-0034「严禁两套逻辑」红线边缘。
5. **slot 概念预留**（建议 B0/B1 引入）：不预留则 B6 贴纸文字、B8 关键帧必返工。
6. **相机重构**（RESEARCH-015，部分已落地）：检测分两级、磨皮换引导滤波、蒙版升级语义分割、整链半分辨率。
7. **门禁扩 App 壳构建**（池 [18]）：iOS 壳约 10min + macOS 壳一并纳入。
8. **P3 工程规范五件**（HANDOFF-018，未开工）：根 README → `.clang-format` → `.editorconfig` → `CODEOWNERS` → 最小 CI（**CI 放最后，且必须复用 `run_gate.sh`，禁止另写一套编译命令**）。
9. **验证债务消化**：池 [1] 播放器 5 检查点 / [2] CAM-018/019 五项 / [3] UIKit 编辑页走查 / [5] 相册走查 / [6] UIA-037/038 六项。

---

## 7. 当前分工与进展

### 7.1 线别表

| 线 | 归属模块 | 号段（实际用到） | 状态 |
|---|---|---|---|
| **集成机**（本机） | `core`/`platform`/`deps` + 全部热点文件（`cq_sdk.h`、CMake、podspec、Podfile、AGENTS 真源、CI） | INFRA-024/025、DEPS-012、ADR-0033~0039 | 活跃。唯一发号器 + 全局册单写者 + 阶段批门禁 |
| **A 编辑/UI 线**（含 AIEDIT） | `ui-apple`/`ui-android`/`model`/`session`/`preview`/`project` | UIA-039/040、EDIT-007~010 | **本周最活跃** |
| **B 相机/特效线** | `camera` + platform/apple 相机子域 | CAM-033/034/035 | 活跃，真机驱动 |
| **C 内核/媒体/渲染线** | `media`/`render`/`gfx`/`audio`/`shader`/`export` | MEDIA-021~027、AUDIO-002 | 部分活跃；RENDER-001 未开工 |
| **AIEDIT 智能成片** | `ai` | AIEDIT-001 已完成，002~011 未开工 | 停在第一张卡 |

### 7.2 各线战绩（10-08 ~ 10-12）

**编辑线**

| 卡 | 成果 | 实测 |
|---|---|---|
| EDIT-007/008 | 分割·删除·左缘裁剪命令 + C ABI×4 | 窄检 6/6、全量 ctest **48/48** |
| EDIT-009/010 | 跨轨移动（id 不变）+ 画布（指纹纳入） | 窄检 4/4、**48/48** |
| UIA-039 | 四命令接轨道区（trimStart 手柄 / 选中态 + 分割删除双端 / 零位移提交跳过） | XCFramework 三切片重建（新 ABI 符号 3/3 在）、Editor **61/61**、Pod 壳绿 |
| UIA-040 | 面板分级 + 画布 + 多轨（画中画轨/跨轨拖拽） | 内核 **48/48** + Editor **65/65** |

> 三犯立规：分割/移动类"目标实体取错变量"第三次犯（P121），单测当场抓住 → 定规「目标实体只能由 `candidate` 派生」。

**相机线**

| 项 | 成果 | 实测 |
|---|---|---|
| CAM-033 P1 | 系统 metadataOutput 脸框（零 Vision）+ Vision 按需 + 磨皮美白单次混合 | Camera **73/73** + iOS 壳绿 |
| 标定收口 | 前摄 metadata 映射 = **转置**，误差 ≤0.011；闸门翻 true | 874 meta + 771 vision 对照 |
| CAM-034 P2 | `beauty_guided.metal` 引导滤波引擎 | 真机 **0.8~2.1ms** vs 双边 1.6~3.0ms |
| CAM-035 P3 | 人像分割蒙版 ∩ 脸框 + 美白改 CIToneCurve 五点 + 半分辨率链 540×960 | 真机全链满帧 **0.8~1.8ms**，内存 240~276MB |
| SIGTRAP 治本 | 7 个回调属性 `@Sendable` + `@unchecked` | **60s 长跑零崩溃**（此前 30~40s 必崩） |
| 10-12 纠偏 | P122/P123/P124 三案（见 §8） | 全量门禁 PASS=14 |

**依赖线**：DEPS-012 FFmpeg demux 档真实接入（5 slice **2.49~2.83MiB**、GPL 扫描 0 命中、xcframework vendored）；ADR-0036（LGPL 处置）+ ADR-0038（Pod 改名/拆分）。
**基建线**：PAL→Platform 全量改名（124+100 文件）、内核 Chq 前缀（189 类型/83 文件）、壳工程冻结入库退役 XcodeGen、agent 友好化两台阶（`tools/build/edit_project.rb` + synchronized groups）。

### 7.3 待办池（未清条目，18 条中 14 条未清）

| 池 | 一句话 | 归属 |
|---|---|---|
| [1] 播放器域真机 5 检查点 · [2] CAM-018/019 五项 · [3] UIKit 编辑页走查 6 项 · [5] 相册走查 | 真机验证债务 | A/B 线，传哲 |
| [6] UIA-037/038 验证 | Editor `swift test` 首验已清（57/57），真机 6 项未做 | A 线 |
| [9] 相机 C 期三条 · [12] AUDIO-002 + 前摄方向 · [15] 相机收尾（余 P93/P94 复验、最大强度目检、后摄美颜、Makeup/MetalFX 回归、会话生命周期） | 待门禁 + 待真机 | B 线 |
| [11] DEPS-012 iOS 真机链接与运行 | 待真机 | C 线 |
| [14] macOS 通用双架构 · [16] 模拟器 MetalFX · [17] 真机内存/jetsam + 主线程 I/O + PHAsset · [18] 门禁不含壳构建 | 集成机，[16]/[17]/[18] 待决策 | 集成机 |
| [13] 内核 Chq 改名 | ✅ 已关 | — |

---

## 8. 关键数字（实测，带机器环境）

**门禁（Intel x86_64 / macOS 26.7.1 / Xcode 26.6，2026-10-12）**

```
bash tools/ci/run_gate.sh → PASS=14  FAIL=0  SKIP=0   耗时 22m14s
  core-dbg 48/48 · core-rel 48/48
  bindings 26 · camera 77 · import 16 · editor 65 · player 52 —— 全部 0 failure
  deps / headers / artifacts / golden 均 PASS
```

**本机实测（其他）**

| 项 | 数字 |
|---|---|
| 时间线布局 | 500 片段（5轨×100）**0.663 ms/帧** |
| App 净启动成本 | **≈0**（LaunchBench，空壳参照无统计差异） |
| 零拷贝 vs CPU 退化 | **≈0.003ms vs ≈5.1ms**（约 1500×） |
| 顺序取帧快路径（Release） | 120 帧 acquire **93.3ms → 4.45ms** |
| INFRA-022 改名后 | 全量重编 **2m55s**；ctest **46/46（113.32s）**；`apps/` **5.5G → 4.3M** |
| Platform 头门禁 | **41 头 0 违规** |
| FFmpeg 5 slice | macosx-x86_64 **2.66MiB**；链接闭合冒烟 5/5；GPL 扫描 0 命中 |

**真机实测（iPhone 17 Pro / iOS 26.6）**

| 项 | 数字 |
|---|---|
| 播放长跑（MEDIA-027 修后） | **t=121.99s**，footprint **134~184MB**，`nonok/s=0`（修复前 3375MB + signal 9） |
| 预览吞吐 | `rendered/s` **74 → 120**；acquire p50 **0.0ms**；total p50 **1.2~1.8ms** |
| 相机美颜 | 磨皮 0.5+美白 0.5 **1.6~3.0ms 满帧**；guided 引擎 **0.8~2.1ms**；半分辨率链 **1.1~3.5ms** |
| Vision 单次 | **11.6~20.3ms** |
| 方向语义（P67/P72 取证） | back=90 / front=0 / front mirror=true；前摄照片修复后 **1080×1920 端正** |
| 标定 | 874 meta + 771 vision，映射 = 转置，**误差 ≤0.011** |
| **未取证** | 内存 188.0→282.4MB + signal 9（三候选全 hypothesis） |

**数字纪律现状**：`baselines.md` 开篇自陈「**当前状态：尚未建立**，PERF-001 完成后填入」。渲染/媒体/内存三张表的实测列**大量为"—"**（多轨 blend、4K 效果链帧时间、1080p 三轨预览内存、probe_duration、命令层单次开销、预览单帧全链路、播放器 UIA-015 全 16 项）。**这些不得作验收阈值。**

---

## 9. 下周计划（2026-10-13 ~ 10-19）

> 前三件是**必须先拍板**的；4~8 是可并行推进的编码/验证项。**一批未验收不得在其上叠加下一批**（ADR-0034）。

**① B0（RENDER-001）范围拍板 + shader spike** —— 最关键，整条关键路径卡在这
- 拍板 RESEARCH-014 的范围修订建议（装配器三图同源 + 时钟源接口 + Push/Pull 分区）与 Push vs Pull；
- 极窄 spike 验通 `glsl → SPIR-V → MSL`（**这条链从未跑过，不验就开工是赌**）；
- ADR 反转 `engine/core/CMakeLists.txt` 的"本期不做 RenderGraph"注记。

**② 池 [18] 决策**：把 iOS 壳（约 10min）+ macOS 壳（`x86_64` 口径）纳入门禁，终结"shader 改动门禁伪绿"。

**③ 池 [17] 内存取证**：Xcode Memory Graph 先取证，**取证前不改代码**；导入链路异步化单独建卡（动 `@MainActor` 边界，不是顺手改）。

**④ 真机一趟攒齐（传哲）**：回收两份未回收问卷（10-11 相机方向+预览音频、10-12 日志纠偏三案），并跑池 [1][2][3][5][6] 五批走查。**问卷未回收 → 相关卡不得标记完成。**

**⑤ 池 [16] 修法定夺**（`#if canImport(MetalFX)` / Pod 排除 simulator / 门禁改真机口径），解开编辑器线全壳证据。

**⑥ B3（PROJ-001）开工**：写集独立、不与任何批次冲突，随时可插——把"关 App 即丢"先解决。

**⑦ 相机线收尾**：CAM-034/035 观感目检（guided 是否翻默认）、池 [15] 剩余五项、美型 warp 修后真机确认 `INSTALLED`。

**⑧ 文档与卡片回填**（低风险、高价值）：RESEARCH-010 缺口清单、TASK-CAM-034/035 状态、`docs/api/engine-api.md` 重新生成（当前源路径已失效且缺 6 个函数）、BACKLOG 写集路径过期（P98）。

**顺延/待定**：P3 工程规范五件（CI 最后）、面板配置化（待拍板）、slot 引入时机、草稿箱是否提前到 B3。

---

## 10. 风险与待拍板

| 风险 | 说明 |
|---|---|
| **不能导出成片** | EXPORT-001 未做，`cq_sdk.h` 无 export ABI；第一个可见出口在 B4，且依赖 B0。**这是当前唯一"致命"缺口** |
| **B0 未拍板 → 全线排队** | RENDER-001 阻塞多轨合成（`RENDER-001 → RENDER-011 → EXPORT-010`）、EXPORT-002（红线 #9）、B6/B7 |
| **门禁伪绿** | 池 [18]；CIWarpKernel 这类"只有真机加载才知道对不对"的改动，门禁给的是假绿（P123 实证） |
| **内存/jetsam 未取证** | 池 [17]①；三个 hypothesis 一个都没验证，且本机复现不出（Intel + 无 VFR 素材） |
| **并行写集污染** | P120 复发过；多 agent 同工作区是常态，逐文件 `add` 是硬纪律 |
| **Intel 本机口径** | 无 ANE / 无 ProRes 硬编 / macOS 通用构建红；**本机数字不得作产品阈值** |
| **文档漂移** | 缺口清单、卡片状态、API 文档三处与代码不一致；引用前必须对着 commit 核 |
| **LGPL 义务** | 处置已定（ADR-0036：App 内声明 + 源码可获得 + 可重链接归档，载体 `engine/NOTICE.md`）；**SDK 本体 License 仍待定** |
| **容量风险** | B4 之后每个能力批次都串行依赖导出一致性；若 B0 拖过下周，B4 出口将顺延 |

---

## 附：本期新增决策与案底

- **ADR**：0033（Engine 源码共置 + 双 Pod）· 0034（分批推进·禁临时方案·署名台账·问卷验收）· 0035（PAL→Platform）· 0036（FFmpeg 接入与 LGPL 处置）· 0037（壳工程冻结入库，XcodeGen 退役）· 0038（ChuanqiCutCore 改名 + FFmpeg 独立 Pod）· 0039（内核 Chq 前缀）。
- **pitfalls**：P103~P124（22 条），其中系统性三条：P108（Pods 远程依赖三件缺失 = 假绿之源）、P118（检测队列 MainActor 隔离断言 = SIGTRAP 无消息崩，归因二次修正）、P121（分割/移动双变量取错三犯立规）。
- **未结**：池 [17] 三案未取证；两份真机问卷未回收；`face_warp.metal` 的 `-fcikernel` 编译不在门禁内。
