# ARCH-001：ChuanqiCut 技术方案总纲

> 版本：v1.0（待 Review）
> 日期：2026-09-23
> 前置阅读：`docs/research/RESEARCH-001`（对既有调研的批判性评审）
> 配套：`ARCH-002 依赖治理`、`ARCH-003 跨平台内核与 GPU/Shader`、`ARCH-004 平台适配矩阵`、`ARCH-005 UI 层与工程结构`

---

## 1. 项目定位

ChuanqiCut 不是一个 App，而是**一个视频编辑 SDK + 三个平台壳**：

```
┌─────────────────────────────────────────────────────────┐
│  应用层（App Shell）—— 各平台原生 UI，不共享             │
│  iOS/macOS: SwiftUI   |  Android: Compose  |  鸿蒙: ArkUI │
├─────────────────────────────────────────────────────────┤
│  绑定层（Bindings）—— 把 C API 包装成平台惯用接口        │
│  Swift 封装 | Kotlin/JNI | ArkTS/NAPI（预留）            │
├─────────────────────────────────────────────────────────┤
│  SDK 层（C++ 共享内核）—— 唯一的业务逻辑真源，≥90% 共享  │
│  模型/命令/动画/媒体/渲染图/效果/音频/项目/推理           │
├─────────────────────────────────────────────────────────┤
│  PAL 层（平台抽象）—— 每个平台一份实现                   │
│  GFX | MediaCodec | Audio | Inference | FS | Clock | Log  │
└─────────────────────────────────────────────────────────┘
```

**核心原则：除 UI 之外的一切都下沉到 C++。**

---

## 2. 平台路线

| 优先级 | 平台 | 状态 | 系统基线 | 说明 |
|---|---|---|---|---|
| **P0（重点）** | iOS / iPadOS | 本期交付 | iOS 16+ | iPhone 与 iPad 同一 target，自适应布局 |
| **P0（重点）** | macOS | 本期交付 | macOS 13+，Apple Silicon | **不使用 Mac Catalyst**，用原生 macOS target + 共享 SwiftUI 包 |
| **P1** | Android | 本期规划、下期实现 | API 26+，arm64-v8a，**RAM ≥ 6GB + GLES 3.1** | 见 `ARCH-004 §4` |
| **P2** | HarmonyOS NEXT | **可选，本期不实现** | API 12+ | 仅做架构预留与可行性验证，见 `ARCH-004 §5` 与 ADR-0007 |

### 2.1 性能基线（2026-09-23 确认）

| 档位 | 定位 | 门槛 |
|---|---|---|
| **高端** | 必须流畅（60fps 全效果链） | iPhone 13 Pro+/A15+；M1+ Mac；骁龙 8 Gen1+/天玑 9000+；RAM ≥ 8GB |
| **中端** | 必须可用（允许降预览分辨率） | iPhone 12/A14；骁龙 7 系/天玑 8000；RAM ≥ 6GB |
| **低端** | **明确不支持** | 门槛以下 → 清晰提示，不做降级适配 |

**"不适配低端"的确切含义**：不为低端机写专用降级路径（极简效果链、超低分辨率代理），不做 4GB RAM 内存裁剪。低端设备得到的是"明确不支持"，而不是"能装但卡死"。

**仍保留的安全网**（这是防御性设计，不是低端适配）：
- 能力缺失降级：无硬解→软解；无 compute→fragment（中端机也可能缺某项能力）
- 内存逼近预算：LRU 回收 + 降预览分辨率（防 OOM 的基本机制）

### 2.2 为什么现在就要按 P1/P2 设计

C++ 内核的模块边界、PAL 接口、Shader 分层这三样东西一旦先按"仅 Apple"写好，后续补 Android 的成本不是增量而是重写。本期多付约 15% 的设计成本，省掉后续 60% 的返工。

**但资源投入是 Apple 优先**：架构按三端设计，人力与优化优先保障 iOS/macOS。具体地 —— Platform-Native shader 特化、性能调优、测试覆盖都先做 Apple 端。

---

## 3. 语言与运行时分配

| 层 | 语言 | 标准/版本 | 占比 | 说明 |
|---|---|---|---|---|
| SDK 内核 | **C++** | C++20 | ~55% | 唯一业务逻辑真源。禁用异常跨模块、禁用 RTTI（可选开）、禁用 STL 类型跨 ABI 边界 |
| PAL (Apple) | **Swift / ObjC++** | Swift 5.10+ | ~10% | Metal、VideoToolbox、AVAudioEngine、CoreML 的适配与零拷贝桥接 |
| PAL (Android) | **C++ / Kotlin** | NDK r27+ | ~8% | MediaCodec、AHardwareBuffer、Oboe/AAudio、TFLite 适配 |
| PAL (HarmonyOS) | **C++ / ArkTS** | — | 预留 | AVCodecKit、XComponent、OHAudio、MindSpore Lite |
| Shader | **GLSL（Vulkan 方言）** | GLSL 4.50 / ES 3.10 | ~8% | 单一源，编译为 SPIR-V 后交叉生成 MSL / GLSL ES，见 `ARCH-003 §4` |
| UI (Apple) | **Swift / SwiftUI** | Swift 5.10+ | ~12% | 双 target 共享 UI package |
| UI (Android) | **Kotlin / Compose** | — | ~5% | |
| 构建/工具 | CMake / Python / Shell | — | ~2% | |

**关于 Rust**：考虑过用 Rust + wgpu 做核心。否决理由 —— ① 团队现有能力在 C++/Swift；② wgpu 的 naga 对 MSL 的成熟度低于 SPIRV-Cross，而我们在 Apple 端的性能优势依赖 Metal 原生路径；③ 与 Android NDK / 鸿蒙 NAPI 的工具链整合成本更高。若未来核心算法需要内存安全保证，可在 `core/dsp` 等无 GPU 依赖的子模块局部试点。

---

## 4. 架构分层与模块

### 4.1 SDK 内核模块（`core/`）

| 模块 | 职责 | 关键类型 | 是否跨端共享 |
|---|---|---|---|
| `base` | 有理数时间、状态码、日志、内存池、并发原语、平台宏 | `RationalTime`, `Status`, `Arena` | ✅ |
| `model` | 时间线数据模型（Project/Track/Clip/Transition/Effect/Marker） | `TimelineModel` | ✅ |
| `command` | 命令模式：所有变更的唯一入口，天然支持 Undo/Redo | `EditorCommand`, `CommandHistory` | ✅ |
| `anim` | 关键帧与插值引擎（Linear/Bezier/Hermite/Catmull-Rom） | `Keyframe<T>`, `AnimationChannel<T>` | ✅ |
| `retime` | 时间映射引擎：恒速 / 速度曲线 / 倒放 | `TimeMap` | ✅ |
| `graph` | 渲染图：节点 DAG、pass 合并、中间纹理池 | `RenderGraph`, `RenderNode` | ✅ |
| `media` | 解封装/解码/编码/封装 的调度与帧缓存 | `FrameProvider`, `DecoderPool`, `Encoder` | ✅（PAL 分离） |
| `audio` | 音频图：解码、效果、时间拉伸、变声、混音 | `AudioGraph`, `TimeStretchNode` | ✅（PAL 分离） |
| `effect` | 效果节点：变换/抠像/美颜/美型/调色/滤镜/转场/文字 | 各类 `RenderNode` 子类 | ✅ |
| `inference` | 推理抽象：模型加载与执行 | `InferenceBackend` | ✅（PAL 分离） |
| `project` | 项目文件序列化、schema 版本、迁移链 | `ProjectSerializer`, `Migrator` | ✅ |
| `session` | 编辑器会话：串起上述模块，对外唯一门面 | `EditorSession` | ✅ |

### 4.2 PAL 接口（`core/pal/`，头文件仅声明；实现在 `pal/<platform>/`）

| 接口 | 职责 | Apple 实现 | Android 实现 | HarmonyOS 实现 |
|---|---|---|---|---|
| `IGraphicsDevice` | 设备/队列/纹理/buffer/pipeline/命令提交 | Metal | Vulkan（旗舰）+ GLES3.1（基线） | Vulkan |
| `IMediaDemuxer` | 容器解析 + seek | AVAssetReader / FFmpeg | MediaExtractor / FFmpeg | OH_AVDemuxer / FFmpeg |
| `IVideoDecoder` | 硬解，输出可共享的 GPU 兼容 frame | VTDecompressionSession | MediaCodec | OH_VideoDecoder |
| `IVideoEncoder` | 硬编 | VT (via AVAssetWriter / VTCompressionSession) | MediaCodec | OH_VideoEncoder |
| `IMediaMuxer` | 封装 | AVAssetWriter | MediaMuxer | OH_AVMuxer |
| `IAudioDevice` | 播放/采集 PCM | AVAudioEngine | Oboe(AAudio→OpenSL) | OHAudio |
| `IInferenceBackend` | 模型加载/推理 | CoreML | TFLite (NNAPI/GPU/XNNPACK) | MindSpore Lite |
| `IFileSystem` | 沙箱/相册/媒体库访问 | FileManager + PhotoKit | Scoped Storage + MediaStore | 鸿蒙文件/媒体库 |
| `IClock` | 高精度单调时钟 | mach_absolute_time | clock_gettime | OHOS 时钟 |
| `ILogger` | 分级日志 + 帧级 trace | os_log | __android_log | HiLog |
| `ICapabilities` | 运行时能力查询 | 见 `ARCH-004 §2` | 同 | 同 |

**PAL 设计铁律**：
1. PAL 头文件**不得暴露任何平台类型**（`CVPixelBuffer`、`AHardwareBuffer`、`VkImage` 一律不得出现在 `core/` 可见的头文件中）。跨层传递统一用句柄 `NativeImageHandle`（opaque）。
2. PAL 接口是**纯虚 + C 风格工厂**，保证 ABI 稳定。
3. 每个 PAL 实现必须提供对应的 capability 查询，不能假设能力存在。

---

## 5. 时间模型（先定死，否则后面全是 bug）

### 5.1 有理数时间

```cpp
struct RationalTime {
    int64_t value;      // 以 timescale 为单位的整数值
    int32_t timescale;  // 每秒刻度数，必须 > 0
};
```

- **禁止用浮点秒表示任何时间**。NTSC 的 23.976 / 29.97 用浮点必然累积漂移。
- 项目 timescale 统一取 **60000**（可被 24/25/30/60/1001 整除）。
- 素材 timescale 沿用其原生 timescale，转换只在边界处发生一次。
- `RationalTime` 的比较/加减/乘除必须做 timescale 归一化并检测溢出。

### 5.2 三套时间坐标

| 坐标 | 定义 | 用途 |
|---|---|---|
| **TimelineTime** | 时间线上的位置 | UI 播放头、片段排布 |
| **SourceTime** | 素材内部位置 | 解码 seek 目标 |
| **PresentationTime** | 输出时间线上的位置 | 编码时间戳、音画同步 |

映射关系：
```
SourceTime = TimeMap_clip(TimelineTime - clip.start)   // 由 retime 模块计算
PresentationTime = TimelineTime（无变速段时）
```
`TimeMap` 是 Retime 的唯一抽象：`map(t) -> source_t`，恒速/曲线/倒放三个实现。

### 5.3 时钟与同步

- **预览**：以音频为主时钟（audio master clock）。视频渲染按音频时钟的当前位置取帧，无音频轨时退化为系统单调时钟驱动。
- **导出**：不依赖任何实时时钟，按 `PresentationTime` 逐帧推进，全速渲染。
- **音画同步判据**：A/V 偏差绝对值 ≤ 1 帧时长（30fps 下 ≤ 33.4ms），持续 500ms 以上视为失步，触发告警与自动校正。

---

## 6. 线程模型

```
┌─ Main Thread ────────── UI 渲染、手势；禁止任何阻塞调用 ─────────┐
├─ Session Thread ─────── 命令执行、模型变更、状态通知（串行） ─────┤
├─ Decode Pool ────────── N 路并发解码（N = min(轨道数, 4)） ──────┤
├─ Render Thread ──────── GPU 命令编码与提交（单线程） ────────────┤
├─ Encode Thread ──────── 编码器输入/输出，背压控制 ───────────────┤
├─ Audio Thread ───────── 实时优先级，禁止加锁与分配 ──────────────┤
└─ Inference Pool ─────── AI 推理，可降级/可丢弃 ──────────────────┘
```

铁律：
1. **主线程零阻塞**：任何超过 16ms 的操作不得在主线程执行。
2. **音频线程无锁、无分配**：所有 buffer 预分配，通信用 lock-free ring buffer。
3. **背压**：解码与渲染之间用有界队列；队列满时解码暂停（预览）或降速（导出），不允许无限增长导致 OOM。
4. **取消**：所有长任务持有 `CancelToken`，在 pass 边界与解码边界检查，取消后必须释放全部 GPU/媒体资源并清理临时文件。

---

## 7. 预览与导出：同一张渲染图

**原则：预览和导出走同一份 `RenderGraph`，只是输出目标和时钟源不同。**

```
                    ┌──────────────────────┐
   TimelineModel ──▶│  GraphBuilder        │  构建与帧无关的节点 DAG
                    └──────────┬───────────┘
                               │ 每帧只更新 uniform / 纹理绑定
                               ▼
                    ┌──────────────────────┐
                    │  RenderGraph.execute │
                    └──────────┬───────────┘
                    ┌──────────┴───────────┐
                    ▼                      ▼
         Target: Swapchain          Target: EncoderInput
         Clock:  Audio clock        Clock:  PresentationTime
         Drop:   允许丢帧           Drop:   不允许丢帧
         Quality: 自适应降级        Quality: 最高
```

这条约束能消除"预览好看、导出不一样"这个视频编辑器最经典的 bug 类别。代价是预览必须能扛住完整效果链的开销 —— 由 `RenderGraph` 的 LOD 机制解决（预览可跳过超分/降噪等昂贵节点）。

---

## 8. 工程仓库结构（monorepo）

```
chuanqicut/
├── core/                          # C++ 共享内核
│   ├── CMakeLists.txt
│   ├── include/cq/                # 公共头文件（C API + C++ 内部头分离）
│   │   ├── cq_sdk.h               # 对外 C API（ABI 边界）
│   │   └── cq/...                 # 内部 C++ 头
│   ├── src/…                      # 按 §4.1 模块划分
│   └── tests/
├── pal/
│   ├── apple/                     # Metal / VT / AVAudioEngine / CoreML / PhotoKit
│   ├── android/                   # Vulkan+GLES / MediaCodec / Oboe / TFLite
│   └── ohos/                      # 预留（不实现，仅占位与接口编译检查）
├── shaders/                       # 单一源 GLSL
│   ├── src/*.glsl
│   └── generated/                 # spirv / msl / glsl_es（构建产物，不入库）
├── bindings/
│   ├── swift/                     # C API → Swift 封装（SPM package）
│   ├── kotlin/                    # JNI → Kotlin
│   └── arkts/                     # NAPI（预留）
├── apps/
│   ├── apple/                     # Xcode workspace：iOSApp / MacApp / SharedUI
│   ├── android/                   # Gradle：app module
│   └── ohos/                      # 预留
├── third_party/                   # 依赖（见 ARCH-002）
│   ├── manifest.toml
│   ├── deps.lock
│   └── <name>/
├── tools/
│   ├── build/                     # 各平台构建脚本
│   ├── shaders/                   # shader 编译链脚本
│   ├── ai/                        # 上下文同步、任务模板
│   └── compliance/                # 协议扫描、SBOM 生成
├── docs/                          # 本目录
├── .ai/                           # AI 协作上下文（见 AI-COLLAB-001）
├── .agents/skills/                # 项目技能
├── AGENTS.md / CLAUDE.md / .cursorrules / .github/copilot-instructions.md
└── .github/workflows/             # CI
```

---

## 9. 构建系统

| 平台 | 构建入口 | 内核构建方式 |
|---|---|---|
| Apple | Xcode 15+ / `.xcworkspace` | External build target 调用 `tools/build/build_core_apple.sh` → CMake 生成 XCFramework |
| Android | Gradle + AGP | `externalNativeBuild { cmake }`，产出 `.so` + 头文件 |
| HarmonyOS | Hvigor + CMake（预留） | 同 Android 模式 |
| 内核单测 | 直接 CMake + CTest | 桌面（macOS/Linux）跑，不依赖真机 |

**内核产物形态**：
- Apple：`CQCore.xcframework`（含 iOS device / iOS simulator / macOS 三切片）
- Android：`libcqcore.so`（arm64-v8a）
- 源码集成与二进制集成的切换由 `ARCH-002` 的依赖清单控制，CI 两条路径都要跑通。

---

## 10. 质量门禁

任务"完成"由以下门禁判定，Agent 自述完成不算：

| 门禁 | 内容 | 阻塞级别 |
|---|---|---|
| Build | 三平台内核编译 + App 编译，零 warning（-Werror） | 阻塞 |
| Unit | 内核单测，新增逻辑覆盖率 ≥ 70% | 阻塞 |
| Golden | 效果/导出 golden frame 对比，PSNR ≥ 40dB（详见 ARCH-003 §9 容差） | 阻塞 |
| Integration | 导入→编辑→导出端到端，1080p/4K 各一 | 阻塞 |
| Perf | 预览帧时间、导出耗时、内存峰值不超过基线 + 阈值 | 阻塞（仅核心链路） |
| Memory | 无泄漏；4K 三轨内存峰值不超过预算上限 | 阻塞 |
| Compliance | 依赖协议扫描 + SBOM 生成 | 阻塞（发布分支） |
| Review | 人工审查核心媒体管线与公共 API | 阻塞（P0 模块） |

---

## 11. 里程碑

| 阶段 | 目标 | 出口标准 |
|---|---|---|
| **Phase 0 — 地基** | 内核骨架、PAL 契约、构建链、依赖治理、CI、基准测试 | 三平台能编译出内核；Apple 端空壳 App 跑起来；性能基线数据入库 |
| **Phase 1 — Apple MVP** | 解码→渲染→预览→导出 全链路通，基础剪辑 | 导入 3 段素材→裁剪→拼接→变速→调色→转场→导出 MP4，1080p 60fps 预览稳定 |
| **Phase 2 — 效果与编辑能力** | 美颜/美型/抠像/关键帧/文字/多轨/Undo | 人像视频美颜+瘦脸实时预览 → 导出；完整 Undo/Redo |
| **Phase 3 — Android** | PAL(Android) + Compose 壳 + 完整功能对齐 | Android 端完成 Phase 1+2 同等功能，设备矩阵通过 |
| **Phase 4 — 鸿蒙（可选）** | PAL(OHOS) 可行性验证 / 实现 | 视资源决定，架构已预留 |

详细任务见 `docs/tasks/TASK-BACKLOG.md`。

---

## 12. 与既有文档的关系

- 本方案**取代** `技术方案决策书.md`（该文件应标记为 Superseded，保留作历史记录）。
- `技术调研_视频管线全链路技术细节.md` 保留为算法参考，沉淀进 `.ai/modules/`。
- `docs/specs/AI-ENG-001.md` 保留，本方案的 `.ai/` 与 `.agents/skills/` 是其落地实现，参见 `docs/ai/AI-COLLAB-001`。
