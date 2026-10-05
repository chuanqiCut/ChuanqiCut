# RESEARCH-001：现有调研文档批判性评审与事实核验

> 项目：ChuanqiCut（跨平台视频编辑器 SDK + 应用）
> 评审对象：第一代 7 份调研（6 份技术调研 + 技术方案决策书，现位于 `docs/research/legacy/`）+ `docs/specs/AI-ENG-001.md` + `docs/ai/AI原生软件工程系统落地记录.md`
> 评审日期：2026-09-23
> 状态：待 Review（其中「事实性错误」与「结构性矛盾」两节的结论需确认或反驳）

---

## 0. 评审方法与证据分级

本文档对原调研材料中的每一条关键结论标注证据等级，**未经实测的数字一律不得作为验收标准**：

| 标记 | 含义 | 使用规则 |
|---|---|---|
| **[V]** Verified | 有官方一手来源（Apple/Google/Huawei 官方文档、上游项目 LICENSE/源码、可复现实测） | 可直接进方案 |
| **[E]** Estimated | 作者估算、行业共识、二手博客 | 可作方向参考，不得作验收阈值 |
| **[H]** Hypothesis | 推测，尤其是对竞品内部实现的推测 | 必须有实测替代方案后才能依赖 |

**评审发现：原文档大量性能数字属于 [E]/[H] 级别，且被当作事实使用。** 这在本项目中必须通过 P0 阶段的基准测试（TASK `PERF-001`）替换为实测值。

---

## 1. 文档资产清单与价值评级

| 文档 | 主要价值 | 评级 | 处置 |
|---|---|---|---|
| 技术调研_剪辑软件技术方案分析.md | 竞品技术拆解（FCP/CapCut/LumaFusion/DaVinci/Premiere）、Apple 平台优势 | ★★★★☆ | **保留**（竞品分析部分），修正若干事实 |
| 技术调研_视频管线全链路技术细节.md | 20 个管线环节的算法原理与 API 细节，是最好的入门教材 | ★★★★★ | **保留**（作为 `.ai/modules/` 的素材源） |
| 技术调研_管线选型决策表.md | 逐环节选型对照 + 补了 7 个缺失环节 | ★★★☆☆ | **保留结论，重做裁决**（与决策书冲突） |
| 技术调研_系统API局限性与FFmpeg取舍分析.md | 系统 API 在 seek/变速/倒放上的边界分析，逻辑扎实 | ★★★★★ | **保留**，是本方案 FFmpeg 定位的直接依据 |
| 技术调研_MediaPipe加速与系统API对比.md | 美颜管线逐帧耗时拆解、三个优化杠杆 | ★★★★☆ | **保留框架**，所有数字降级为 [E] |
| 技术方案决策书.md | 最终技术栈选型 | ★★☆☆☆ | **重做**（平台前提已变：需支持 Android） |
| AI原生软件工程系统落地记录.md + AI-ENG-001.md | AI 研发工作流、知识库、角色编排 | ★★★★☆ | **保留并落地**（已按此构建 `.ai/` 与 skills） |

---

## 2. 事实性错误（阻塞级，必须修正）

| # | 出处 | 原文表述 | 核验结果 | 证据 | 影响 |
|---|---|---|---|---|---|
| **F1** | 技术方案决策书 §1、§2.4；管线选型决策表 §[15] | 「SoundTouch (MIT)」 | **错误。SoundTouch 是 LGPL v2.1-or-later**，官方明示「Commercial Non-LGPL license alternative available upon request」 | [V] 上游 README/LICENSE（surina.net、codeberg 仓库） | 协议合规结论完全反了。iOS 静态链接 LGPL 存在可替换义务，不能按 MIT 处理 |
| **F2** | 管线选型决策表 §[1]、系统API文档 §五 | 「FFmpeg LGPL（需合规处理）」表述含糊，暗示引入即高风险 | **FFmpeg 默认即为 LGPL v2.1+**；仅当 `--enable-gpl` 或链接 `libx264/libx265/libpostproc/librubberband/libvidstab` 等 GPL 外部库时整体才升为 GPL v2+ | [V] ffmpeg.org LICENSE.md | 风险被夸大。通过构建裁剪可让 FFmpeg 完全停留在 LGPL 面内 |
| **F3** | 技术方案决策书 §2.2；MediaPipe 对比文档全文 | 「Vision 检测 ~0.5ms ANE」「MediaPipe CoreML ~1ms」「剪映 ~2ms」「M4 ANE 人脸检测 ~3ms」等约 20 处性能数字 | 均**无一手公开来源**，属 [E]/[H]。其中「剪映自研方案 2.1ms」原文自述为「传闻数据，基于行业共识估算」 | [E] | 不可作为验收阈值；必须建立自有基准 |
| **F4** | 技术调研_剪辑软件方案分析 §4.1 | 「AVAsset 在 M 芯片上的解封装是硬件加速的——moov box 解析、sample table 查找都在 Media Engine 里完成」 | **无 Apple 官方文档支持**。Media Engine 负责编解码，容器解析（moov/stbl）由 CPU 完成 | [H] | 误导性能预期，会导致 seek 成本估算错误 |
| **F5** | 技术方案决策书 §1 框架表 | 「SwiftUI：一个 target 跑 iOS + Mac，80%+ 代码共享」 | iOS 与 macOS 是**两个独立 target**。同工程多 target 共享 SwiftUI 代码可行，但「一个 target」不成立 | [V] Xcode 工程模型 | 工程结构规划错误 |
| **F6** | 技术方案决策书 §7.1、§八 | 「Intel Mac 可开发……代码自动兼容 M 芯片」「Intel Mac: ❌ 不支持 ProRes 硬解硬编」被当作可接受的基线 | 2026 年以 Intel Mac 为基线不可接受：无 ANE、无 ProRes 硬编、无 AV1 硬解、UMA 优势完全消失，且 Xcode 对 Intel 的支持已进入末期 | [V] Apple 芯片能力矩阵 | 开发与性能基线错误，直接影响 ANE/ProRes 相关功能的可验证性 |
| **F7** | 技术方案决策书 §2.5、§1 | 「设置页用 Flutter 模块」「纯粹为了学 Flutter，不产生架构风险」 | 三重问题：① 违反本文档自己定的「最小化第三方依赖」原则；② Flutter Engine 会创建自己的 Metal/GL 上下文与渲染线程，与编辑器主渲染上下文竞争 GPU 与内存带宽，风险不为零；③ 为「学习」引入生产依赖不是工程理由 | [V] Flutter 引擎架构 | **明确否决** |
| **F8** | MediaPipe 对比文档 §二 | 「TFLite → CoreML 转换是唯一能让模型跑在 ANE 上的方法」「coremltools 转换后 ~1-2ms」 | 转换路径可行，但两点被低估：① 转换后是否真的落到 ANE 由 CoreML 运行时决定，需 `MLModelConfiguration.computeUnits` 与实际 profile 验证，无法保证；② **MediaPipe face_landmark 模型输出不是 468 个可直接使用的屏幕坐标**，需复现其 post-processing（含 attention/iris crop 的逆变换与 face geometry 的 metric→screen 换算），这部分工作量在原方案中完全缺失 | [V] CoreML 行为；[E] 工作量 | 实施风险被显著低估 |
| **F9** | 技术方案决策书 §四管线数据流 | 「→ VTCompressionSession (硬编) → 编码回调 CMSampleBuffer → AVAssetWriter (封装)」 | 技术上可行，但对 Metal 渲染出的 CVPixelBuffer，更稳的路径是 `AVAssetWriterInputPixelBufferAdaptor`（系统内部走 VT 硬编）。自建 VTCompressionSession 需要处理 B-frame 重排、`expectsMediaDataInRealTime=false`、时间戳连续性等，复杂度显著更高，原方案未给出理由 | [V] AVAssetWriter 用法 | 建议 MVP 走 PixelBufferAdaptor，仅在需要精确码率控制/自定义 GOP 时才降级到自建 session |
| **F10** | 关键架构补遗 §1.3 project.json 示例 | `"duration": 120.0`、`"start": 10.0, "end": 30.0`（浮点秒） | **浮点秒不能表示 NTSC 帧率**（23.976 / 29.97）。累积误差会导致帧漂移、音画不同步、导出丢帧 | [V] 时间基原理 | 必须改为有理数时间 `{value, timescale}` |

---

## 3. 文档间的结构性矛盾（必须由 ADR 裁决）

| # | 矛盾点 | 各方结论 | 裁决（本方案采用） | ADR |
|---|---|---|---|---|
| **C1** | FFmpeg 是否引入 | 决策书：**必须**（demux+seek）；管线选型决策表：**可完全避免**（用 AVAssetReader）；系统API文档：**分阶段**（Phase1 不用，Phase2 引入） | **采用系统API文档的分阶段结论**：MVP 用系统 demux；引入统一 `FrameProvider` 抽象；速度曲线/倒放/精确 seek 场景启用 FFmpeg **demux-only** 后端。 | ADR-0003 |
| **C2** | 解码路径 | 决策书：VTDecompressionSession；管线表：AVAssetReader；剪辑软件分析：AVAssetReader | **不是矛盾而是分工**：顺序读取 → AVAssetReader（内部即走 VT）；FFmpeg demux 后 → 自建 VT session 复用。**两者都实现，由 `FrameProvider` 按访问模式选择** | ADR-0003 |
| **C3** | 是否做跨平台共享内核 | 剪辑软件分析 §6.3：**「早期不要做 C++/Rust 共享核心」**；§6.4 Phase4 才考虑；决策书：明确「不做 Android」 | **前提已变**（需求要求 Android 必须支持、鸿蒙可选）。裁决：**现在就建立 C++ 共享内核**。但共享的是「引擎与算法」，不是「UI」 | ADR-0001 |
| **C4** | MetalPetal | 决策书：**不引入**（手写 Metal）；管线表：**⭐强烈推荐**；剪辑软件分析：**作为基础或参考自研** | **不引入**。理由：MetalPetal 只解决 Apple 单端，引入后会把渲染核心锁死在 Swift 侧，与 C++ 共享内核（C3）直接冲突。改为自研薄 GFX 抽象 | ADR-0002 |
| **C5** | 美型：Mesh Warp vs UV Offset Map | 三份文档均「MVP Mesh Warp → 生产 UV Offset」 | **结论保留**，但补一条硬约束：**两者必须实现同一个 `FaceWarpNode` 接口**，切换只换实现不换调用方，且必须预先评估 468→精简点模型替换时的参数语义迁移成本 | ADR-0005 |
| **C6** | 变速/Retime | 管线表：AVComposition + AVAudioUnitTimePitch；系统API文档：速度曲线必须 FFmpeg；决策书：Phase 4 才做 | **统一为 Retime 引擎**：`TimeMap(timelineTime) -> sourceTime`，恒速/曲线/倒放三种实现同一接口；音频侧由统一 `TimeStretchNode` 处理 | ADR-0006 |
| **C7** | KMP 定位 | 决策书：Kotlin (KMP) 用于「共享数据模型（限 iOS 端，目前不考虑 Android）」 | **废弃**。KMP 的价值在于跨端，本项目已有 C++ 内核，KMP 只共享 iOS 端模型毫无意义，纯属负债 | ADR-0001 |

---

## 4. 缺失的工程主题（原文档未覆盖，但对交付是硬需求）

这些不是"锦上添花"，是**媒体类项目不出事的前提**。原方案直接跳过了：

| # | 缺失主题 | 为什么关键 | 本方案落点 |
|---|---|---|---|
| **M1** | 时钟与同步模型 | 预览由谁驱动（audio master clock / display link / 内部时钟）？导出时如何保证与预览一致？不做会导致音画漂移 | `ARCH-001 §5`；TASK `CORE-03x` |
| **M2** | 线程模型与 QoS | 解码/渲染/编码/UI 四条队列的优先级、背压、主线程零阻塞约束 | `ARCH-001 §6`；TASK `CORE-04x` |
| **M3** | 帧缓存与内存预算 | 4K 多轨下必须有明确内存上界（MB），否则老设备必 OOM。原方案只提「CVPixelBuffer Pool」，没有上界和降级策略 | `ARCH-003 §7`；TASK `RENDER-02x` |
| **M4** | RenderGraph 与 pass 合并 | 效果链 10 个 pass 若各自 render target，纹理带宽是瓶颈而非算力。原方案逐 pass 串行描述，性能模型过于乐观 | `ARCH-003 §6`；TASK `RENDER-01x` |
| **M5** | 统一色彩管理 | working color space、HDR/SDR、Display P3/sRGB、跨端色彩一致性。原方案只提了"HDR 管线"，没有可执行的色彩管道定义 | `ARCH-003 §8`；TASK `COLOR-0xx` |
| **M6** | 取消 / 进度 / 错误码 / 可恢复性 | 导出是长任务，必须可取消、可续、失败有稳定错误码与临时文件清理 | TASK `EXPORT-0xx` |
| **M7** | 测试策略：golden frame 与确定性 | 视频渲染的正确性不能靠肉眼。需要 golden-frame + PSNR/SSIM 回归，以及「同输入同输出」的确定性导出定义与容差 | TASK `QA-0xx` |
| **M8** | 性能门禁与设备矩阵 | 无基线就无法判断"优化是否有效"，也无法防止回归 | TASK `PERF-0xx` |
| **M9** | 项目文件跨端兼容与版本迁移 | 项目文件要跨 iOS/Mac/Android 打开，必须有 schema version + migrator 链 | ADR-0006；TASK `PROJ-0xx` |
| **M10** | 权限与隐私 | iOS 相册权限、Android Scoped Storage（分区存储）、鸿蒙权限模型各不相同 | `ARCH-004 §5` |
| **M11** | 可观测性 | 媒体管线是黑盒，崩溃后无法复现。需要分级日志、帧级 trace、失败样本归档 | TASK `CORE-05x` |
| **M12** | 跨端数值一致性 | 不同 GPU 的浮点实现不同，同一项目在 iOS 与 Android 导出的像素不可能 bit-identical。必须事先定义**容差标准**（否则 golden test 永远红） | `ARCH-003 §9` |
| **M13** | 开源依赖治理机制 | 原方案只有一张「开源依赖清单」表，没有版本锁定、源码/二进制双集成、能力裁剪、协议门禁、SBOM | **用户明确要求** → `ARCH-002` 全篇 |
| **M14** | Android / 鸿蒙的技术方案 | 原方案明确不做，本需求要求必须给出 | `ARCH-004` 全篇 |

---

## 5. 处置结论总表

### 5.1 保留（可直接沿用）
- 20 个管线环节的算法原理与 Apple API 用法（`视频管线全链路技术细节.md`）→ 沉淀为 `.ai/modules/media.md` 等模块知识
- 竞品架构拆解（FCP 代理工作流、CapCut C++ 核心、LumaFusion 路线）→ 作为架构论证依据
- 系统 API 在 seek/倒放/速度曲线上的边界分析 → ADR-0003 的直接依据
- Command Pattern + Undo/Redo 设计 → 保留，但迁移到 C++ 层
- 关键帧动画数据模型（Keyframe / AnimationChannel / Interpolatable）→ 保留，改为 C++ 实现
- 项目文件 `.chuanqicut` 包结构 + 自动保存策略 → 保留，改为有理数时间 + schema version
- AI 原生工程工作流（八层模型、角色编排、四层记忆）→ 保留并落地

### 5.2 修正
| 项 | 修正为 |
|---|---|
| SoundTouch (MIT) | 移除。**改用 signalsmith-stretch（MIT，C++11 header-only，已被 Qt Multimedia 采用）**，同时解决协议、跨端、formant 补偿三个问题 → ADR-0004 |
| FFmpeg 协议风险 | 通过构建裁剪停留在 LGPL v2.1+ 面内，并纳入依赖治理 → ADR-0003 / ARCH-002 |
| SwiftUI 单 target | 改为 iOS + macOS 双 target + 共享 SwiftUI package |
| Intel Mac 基线 | 改为 Apple Silicon 基线（iOS 16+ / macOS 13+） |
| 编码路径 | MVP 用 `AVAssetWriterInputPixelBufferAdaptor`，自建 VT session 延后 |
| 项目文件时间表示 | 浮点秒 → 有理数 `{value, timescale}` |
| 性能数字 | 全部降级为 [E]，由 PERF-001 实测替换 |

### 5.3 废弃
| 项 | 废弃理由 |
|---|---|
| Flutter 设置页模块 | 违反最小依赖原则；引擎与主渲染上下文争 GPU；引入理由非工程性 |
| Kotlin Multiplatform 共享数据模型（仅 iOS） | 与 C++ 内核职责重叠，且无跨端收益 |
| MetalPetal 作为渲染核心 | 与跨端内核冲突；改为自研薄 GFX 抽象 |
| "不做 Android / 不做跨平台核心" | 需求前提已变更 |
| KMP / Flutter 目录结构 | 工程结构重做 |

---

## 6. 评审后必须补做的三件事

1. **建立事实基线**：`PERF-001` 在真实设备上实测解码/渲染/推理耗时，替换本文档中所有 [E] 数字，并把结果写回 `.ai/memory/baselines.md`。
2. **写 7 条 ADR**：把 C1–C7 的裁决固化为 `docs/decisions/ADR-000x`，每条含「背景 / 决策 / 备选 / 后果 / 反转条件」。
3. **建立依赖治理**：`ARCH-002` 落地清单、裁剪档位、协议门禁与 SBOM，CI 强制执行，不允许口头约定。
