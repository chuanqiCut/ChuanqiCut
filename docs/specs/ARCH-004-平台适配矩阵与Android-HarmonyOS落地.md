# ARCH-004：平台适配矩阵与 Android / HarmonyOS 落地方案

> 版本：v1.0（待 Review）
> 日期：2026-09-23
> P0 = iOS/macOS（本期交付）｜P1 = Android（本期规划）｜P2 = HarmonyOS（可选，本期不实现）

---

## 1. 能力矩阵总表

| 能力 | iOS/iPadOS 16+ | macOS 13+ (Apple Silicon) | Android API 26+ | HarmonyOS NEXT (API 12+) |
|---|---|---|---|---|
| **UI 框架** | SwiftUI | SwiftUI（原生 target） | Jetpack Compose | ArkUI (ArkTS) |
| **解封装** | AVAssetReader / FFmpeg | 同左 | MediaExtractor / FFmpeg | OH_AVDemuxer / FFmpeg |
| **视频硬解** | VideoToolbox | VideoToolbox | MediaCodec | AVCodecKit (`OH_VideoDecoder`) |
| **视频硬编** | VT (AVAssetWriter / VTCompressionSession) | 同左 | MediaCodec | AVCodecKit (`OH_VideoEncoder`) |
| **封装** | AVAssetWriter | AVAssetWriter | MediaMuxer | OH_AVMuxer |
| **软解兜底** | FFmpeg（可选档位） | 同左 | FFmpeg（可选档位） | 系统软解仅 H.264；其余走 FFmpeg |
| **GPU** | Metal | Metal | **Vulkan（旗舰）+ GLES 3.1（基线）** | Vulkan 1.3 / GLES 3.2 |
| **零拷贝** | `CVPixelBuffer`→`CVMetalTexture` | 同左 | `AHardwareBuffer`→`EGLImage`/`VkImage` | `OHNativeWindow` + Vulkan 外部内存 |
| **音频 I/O** | AVAudioEngine | AVAudioEngine | Oboe（AAudio→OpenSL 回退） | OHAudio |
| **推理** | CoreML（ANE） | CoreML（ANE） | TFLite（NNAPI / GPU / XNNPACK） | MindSpore Lite |
| **原生桥接** | Swift C interop / ObjC++ | 同左 | JNI + Kotlin | NAPI + ArkTS |
| **产物** | `.app` / XCFramework | `.app` | `.apk` / `.aab` | `.hap` |
| **ABI** | arm64 (device) + arm64/x86_64 (sim) | arm64 (+x86_64 若需) | **arm64-v8a 单 ABI** | arm64-v8a |

---

## 2. 运行时能力查询（关键设计）

**不允许在代码里用 `#if __APPLE__` 来推断能力。** 能力必须在运行时查询：

```c
typedef enum {
  CQ_CAP_HW_DECODE_H264, CQ_CAP_HW_DECODE_HEVC, CQ_CAP_HW_DECODE_AV1,
  CQ_CAP_HW_DECODE_PRORES,
  CQ_CAP_HW_ENCODE_H264, CQ_CAP_HW_ENCODE_HEVC, CQ_CAP_HW_ENCODE_PRORES,
  CQ_CAP_10BIT_PIPELINE, CQ_CAP_HDR_DISPLAY,
  CQ_CAP_COMPUTE_SHADER, CQ_CAP_FLOAT_TEXTURE, CQ_CAP_EXTERNAL_MEMORY_IMPORT,
  CQ_CAP_NPU_INFERENCE,
} CQCapability;

CQCapabilityValue cq_query_capability(CQCapability c);  // yes / no / degraded
```

理由：Android 的能力由**具体机型**决定而非系统版本；Apple 的能力由**具体芯片**决定（如 ProRes 硬编仅部分芯片支持）。编译期判断必然出错。

---

## 3. P0：Apple 实现要点

| 主题 | 决策 |
|---|---|
| target 结构 | `iOSApp` + `MacApp` **两个 target** + `SharedUI` Swift package。**不用 Mac Catalyst**（Catalyst 在窗口管理、键盘/触控板、菜单上有妥协，编辑器是大交互量应用） |
| 代码共享 | 目标 ≥ 80%，共享部分是 SwiftUI 视图 + ViewModel；差异部分用 `#if os(iOS)` 收敛到最小 |
| 最低版本 | iOS 16 / macOS 13（能用上 `AVSampleBufferGenerator`、Swift Concurrency、现代 SwiftUI） |
| 解码路径 | 顺序读取用 `AVAssetReader`；精确 seek / 速度曲线 / 倒放走 FFmpeg demux + 自建 `VTDecompressionSession`（由 `FrameProvider` 选择） |
| 编码路径 | **MVP：`AVAssetWriterInputPixelBufferAdaptor`**（系统内部走 VT 硬编，最稳）。需要精确码率控制、自定义 GOP、分段复用时再引入自建 `VTCompressionSession` |
| 零拷贝 | `CVMetalTextureCache` 按 device 持有并复用；解码时设置 `kCVPixelBufferMetalCompatibilityKey` |
| 推理 | CoreML + `.mlpackage`。**必须实测是否落在 ANE**（原文档假设一定落在 ANE，属未验证假设）；不可用则回退 GPU/CPU |
| 人脸检测 | Vision 做前置框（快）→ 裁人脸区域 → landmark 模型只在小图推理（对应原调研的"杠杆 1+2"，结论保留，数字待实测） |
| 相册 | PhotoKit + `PHPickerViewController`；项目文件存 App Group 容器，导出走 `UIDocumentPicker`/`NSSavePanel` |
| 后台导出 | iOS 用 `UIApplication.beginBackgroundTask` + `ProcessInfo` 低功耗约束处理；macOS 无此限制 |

---

## 4. P1：Android 实现方案

### 4.1 基线与工具链

| 项 | 取值 | 理由 |
|---|---|---|
| minSdk | **26 (Android 8.0)** | GLES 3.1 / `AHardwareBuffer` / 现代 NDK 的最低可用线；2026 年该版本以下占比极低 |
| targetSdk | 最新稳定版 | 商店要求 |
| ABI | **arm64-v8a only** | 32 位设备跑不动 4K 编辑；armeabi-v7a 无意义地翻倍包体与测试面 |
| NDK | r27+ | C++20、libc++_shared |
| 构建 | Gradle + AGP + `externalNativeBuild { cmake }` | 内核复用同一份 CMake |
| 音频 | **Oboe**（Apache-2.0） | Google 官方，AAudio 优先、OpenSL ES 回退，规避厂商 AAudio 实现差异 |
| 语言 | Kotlin + Compose | |

### 4.2 MediaCodec 使用要点

1. **异步模式**（`setCallback`）而非同步轮询，避免死锁与线程阻塞。
2. **两种输出模式的选择**：
   - Surface 模式：可拿到 `AHardwareBuffer`，支持零拷贝导入 GPU，但无法直接读回 CPU。
   - Buffer 模式：拿到 `Image`/ByteBuffer，可读回，但有拷贝。
   - **策略**：默认 Surface 模式 + 零拷贝；当效果链需要 CPU 侧访问（如某些分析）或设备黑名单命中时，降级 Buffer 模式。
3. **关键帧 seek**：`MediaExtractor.seekTo(time, SEEK_TO_CLOSEST_SYNC)`，与 iOS 的精确 seek 语义不同，Android 只有关键帧级 seek。精确 seek 场景走 FFmpeg demux 后端统一语义。**这正是 `FrameProvider` 抽象存在的价值。**
4. **色彩格式**：优先 `COLOR_FormatYUV420Flexible`，通过 `Image.getHardwareBuffer()` 取 AHardwareBuffer；需处理厂商 stride 对齐差异（YUV 平面 stride 与 iOS 不同，统一在 PAL 内转换）。
5. **并发路数**：受限于硬件解码器实例数（部分芯片只有 1–2 路硬解实例）。`DecoderPool` 必须支持"超出硬件路数时降级到软解或复用实例"。
6. **设备黑名单**：维护已知问题机型清单（Vulkan 缺陷、EGLImage 缺陷、MediaCodec 色彩偏移等），命中即降级。清单随版本更新，线上可远程下发。

### 4.3 与 Apple 端的行为差异及处理

| 差异 | 处理 |
|---|---|
| seek 只能到关键帧 | `FrameProvider` 统一为"精确 seek 语义"，Android 端内部 seek 到关键帧后向前解码到目标帧 |
| YUV 平面 stride 对齐不同 | PAL 内统一转换为 core 定义的 `NativeImageHandle` 描述，上层无感 |
| 硬解实例数受限 | `DecoderPool` 动态调度 + 降级 |
| 无 ANE，NPU 碎片化 | 推理后置多后端 + 强制 CPU 回退（见 ADR-0005） |
| 无 ProRes 硬解 | 能力查询返回 false，导入 ProRes 走 FFmpeg 软解或不支持提示 |
| 相册/分区存储 | `MediaStore` + `READ_MEDIA_VIDEO`（API 33+ 细分权限）；项目文件存 app-specific 目录 |

### 4.4 Android 端排期原则

Android 不是"再写一遍"，而是**先做 PAL(Android) + 空壳 App 跑通内核，再逐步点亮功能**。内核已由 iOS/Mac 端验证过，Android 端的主要风险集中在 PAL 与设备适配，而非业务逻辑。因此 Android 端排期应显著短于 Apple 端首次实现。

---

## 5. P2：HarmonyOS（可选，本期不实现）

### 5.1 可行性结论

HarmonyOS NEXT（API 12+，HarmonyOS 4.0/5.x/6.x）具备承载本项目所需的能力：

| 能力 | 状态 |
|---|---|
| 图形 | 原生 **Vulkan 1.3** 与 OpenGL ES 3.2；`XComponent` 提供原生渲染 surface（`OHNativeWindow`） |
| 解码/编码 | **AVCodecKit**（`OH_VideoDecoder` / `OH_VideoEncoder`），H.264/H.265/HEVC 10bit 硬件编解码，Surface 模式支持零拷贝；软解目前仅 H.264 |
| 解封装/封装 | `OH_AVDemuxer` / `OH_AVMuxer` |
| 音频 | OHAudio |
| 原生桥接 | NAPI（C/C++ ↔ ArkTS） |
| UI | ArkUI (ArkTS) |
| 工具链 | DevEco Studio + Hvigor + CMake（NDK 原生开发），产物 `.hap` |
| 推理 | MindSpore Lite |

**结论：技术可行**。已有第三方引擎（如 Godot）成功以「ArkTS 壳 + XComponent + Vulkan + NAPI」的方式完成原生移植，验证了这条链路。

### 5.2 本期做什么 / 不做什么

**做（架构预留，低成本）**：
1. PAL 接口定义中包含 `IHarmonyOS` 所需的能力枚举（已在 ARCH-003/004 的能力查询中覆盖）。
2. `pal/ohos/` 目录占位，含**接口编译检查**（保证 ohos PAL 与接口签名同步演进，不会腐烂）。
3. 依赖清单中登记鸿蒙平台的库形态与协议。
4. 任务清单中保留 `OHOS-0xx` 组（未排期）。

**不做（本期）**：
- 不实现任何鸿蒙 PAL 代码。
- 不搭建 DevEco 工程。
- 不做鸿蒙机型适配与测试。

### 5.3 若未来启动，路径是

`OHOS-001 环境验证`（DevEco + NDK hello world + Vulkan 清屏）→ `OHOS-002 GFX 后端` → `OHOS-003 媒体后端` → `OHOS-004 音频/推理` → `OHOS-005 NAPI 绑定` → `OHOS-006 ArkUI 壳` → 复用全部内核与效果。

由于内核与效果 100% 共享，届时工作量集中在 PAL 与 UI 壳，预计显著低于任一端的首次实现成本。

---

## 6. 权限与隐私

| 平台 | 媒体读取 | 媒体写入/导出 | 备注 |
|---|---|---|---|
| iOS | `NSPhotoLibraryUsageDescription` / PHPicker（无需授权） | 保存到相册需 `NSPhotoLibraryAddUsageDescription` | 尽量用 PHPicker 避免申请读权限 |
| macOS | 需要用户授权（照片库 / 文件夹） | 沙箱内导出需 NSSavePanel | 注意沙箱与安全作用域 bookmark |
| Android | `READ_MEDIA_VIDEO`（33+）/ `READ_EXTERNAL_STORAGE`（≤32） | MediaStore 插入或 SAF | 分区存储，不能绝对路径访问 |
| HarmonyOS | 对应媒体权限（P2） | 媒体库写入（P2） | |

**通用原则**：最小权限；导出优先走系统保存对话框而非申请全局写权限；任何用户媒体不得进入日志与埋点。

---

## 7. 设备矩阵与性能基线

> **2026-09-23 确认（传哲）：高端满足、中端可用、明确不适配低端机。iOS / macOS 是重点支持平台。**

### 7.1 支持档位

| 档位 | 定位 | 门槛 |
|---|---|---|
| **高端** | 必须流畅（60fps 全效果链） | iPhone 13 Pro+/A15+；M1+ Mac；骁龙 8 Gen1+/天玑 9000+；RAM ≥ 8GB |
| **中端** | 必须可用（允许降预览分辨率） | iPhone 12/A14；骁龙 7 系/天玑 8000；RAM ≥ 6GB |
| **低端** | **不支持** | 门槛以下 → 明确提示不支持 |

**不适配低端 = 不为低端写专用降级路径、不做 4GB RAM 内存裁剪**，而不是"能装但卡死"。
仍保留的安全网（防御性设计，非低端适配）：能力缺失降级（无硬解→软解、无 compute→fragment）、内存逼近预算时的 LRU 回收与降预览分辨率。

### 7.2 测试基线设备

| 平台 | 高端 | 中端 |
|---|---|---|
| **Apple（重点）** | iPhone 15 Pro / M3 Mac | iPhone 12 / M1 Mac |
| Android | 骁龙 8 Gen3 / 天玑 9300 | 骁龙 7 系 / 天玑 8000 |
| HarmonyOS | —（P2 未排期） | — |

**Apple 端优先投入**：测试覆盖、性能优化、Platform-Native shader 特化都优先做 iOS/macOS。

### 7.3 Android 硬件门槛（补充 minSdk）

`minSdk 26` 只是系统门槛，还需硬件门槛：**RAM ≥ 6GB + 支持 GLES 3.1**。不满足则在安装/启动时明确提示不支持，不做降级适配。
