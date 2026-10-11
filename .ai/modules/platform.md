# 模块：core/platform — Platform 接口层（CORE-006 冻结）

> **归属**：集成机（Platform 接口冻结归口） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`core/include/cq/platform/*.h`（仅接口定义，零实现）。
**权威契约**：`docs/specs/Platform-接口契约.md`（本文件为模块运行记录 + 设计取舍摘要）。

## 职责
Platform 是**所有平台实现的契约**（iOS / macOS / Android / 鸿蒙四端照着实现）。
在 CORE-006 冻结前，任何 Platform 实现（PALA-/PALD-/OHOS）不得开始（BACKLOG 第 327 行）。

## 交付内容（8 领域 + 共用）

| 文件 | 领域 | 核心接口 |
|---|---|---|
| `chq_common.h` | 共用 | opaque 句柄（`DeviceHandle`/`TextureHandle`/`NativeImageHandle`…）、平台无关枚举（`ChqPixelFormat`/`ChqTextureFormat`/`ChqTextureUsage` bitmask/`ChqSampleFormat`/`ChqContainerFormat`/`ChqCodecId`/`ChqColorSpace`/`ChqInferenceDataType`）、`ChqIPlatformResource` 基类、`ChqPlatformPtr<T>` RAII |
| `chq_gfx.h` | GFX | `ChqIGraphicsDevice`/`ChqICommandQueue`/`ChqICommandBuffer`/`ChqICommandEncoder`/`ChqITexture`/`ChqIBuffer`/`ChqIRenderTarget`/`ChqIPipeline`/`ChqIShaderModule`/`ChqISampler`/`ChqIFence`（12 概念对齐 ARCH-003 §2.2）+ `ChqINativeImageImporter`（ExternalImage） |
| `chq_media.h` | Media | `ChqIMediaDemuxer`（demux）、`ChqIFrameProvider`（精确 seek + 帧提供）、`ChqMediaPacket`/`ChqMediaFrame`/`ChqVideoFrame`/`ChqAudioFrame`/`ChqStreamInfo` |
| `chq_audio.h` | Audio | `ChqPcmBuffer`、`ChqIAudioEngine`（播放/采集） |
| `chq_inference.h` | Inference | `ChqIInferenceBackend`、`ChqInferenceTensor`、`ChqModelAsset`、`ChqInferenceBackendType` |
| `chq_fs.h` | FS | `ChqIFile`（继承 `ChqIPlatformResource`，`Read`/`Write`/`Destroy`）、`ChqIFileSystem`、`ChqPath`/`ChqPathNamespace`、`ChqFileStat` |
| `chq_clock.h` | Clock | `ChqIMonotonicClock`（返回纳秒 `ChqRationalTime`） |
| `chq_log.h` | Log | 平台 `ChqILogSink` 工厂契约（`CreatePlatformLogSink`/`DestroyPlatformLogSink`） |
| `chq_capabilities.h` | Capabilities | `ChqCapability`/`ChqCapabilityValue` 枚举、`ChqICapabilities`、`SetCapabilitiesBackend`/`QueryCapability` |
| `chq_platform.h` | 聚合 | 一次性 include 全部领域头 |

## 硬约束满足方式（评审重点）

1. **零 FFmpeg 类型**：Media 接口不使用任何 `AV*` 类型、不 include ffmpeg 头。
   demux 产物是本项目自己的 `ChqMediaPacket`/`ChqMediaFrame`；`ChqContainerFormat`/`ChqCodecId`
   是与 `AVCodecID` 解耦的枚举（FFmpeg 后端在 Platform 实现内映射）。grep 仅注释中出现
   "FFmpeg/AVPacket" 字样，代码中无任何 AV 类型引用。
2. **零平台类型**：所有跨层资源用 `chq_common.h` 的 opaque 指针句柄
   （`struct CqXxx;` 不完整类型 + `using XxxHandle = CqXxx*;`）。头文件只见到指针，
   永远看不到底层平台类型，也不需要 include 任何平台头。grep 无 `NSString`/`CVPixelBuffer`/
   `jobject`/`JNIEnv`/`MTLDevice`/`ID3D11Device` 及 `<CoreFoundation>`/`<jni.h>`/`<android/>`。
   注：AppleClang 下「出现平台类型反而能编译通过」，朴素 grep 又会把注释误报，故零平台类型由
   （a）本设计 +（b）门禁脚本 `tools/platform/check_platform_headers.py`（剔除注释/字符串后匹配，
   接 ctest `platform_header_gate`）+（c）评审共同兜底，不能只靠编译证明。
3. **统一 base 类型**：时间一律 `ChqRationalTime`（Clock 用纳秒 timescale=1e9，与项目 120000 网格
   可 Rescale 对齐）；错误一律 `ChqStatus`；长任务（`Seek`/`Read`/`Run`/`Read`）接受 `ChqCancelToken`；
   需背压管线用 `ChqBoundedQueue<T>`（后续 MEDIA/AUDIO 使用，本契约预留）。
4. **`-Werror` 零警告**：编译验证 TU `tests/unit/platform_headers_compile.cpp` 在
   `-Wall -Wextra -Wconversion -Wshadow -Wold-style-cast` 下干净编译。

## 关键设计取舍（与契约文档一致）

- **opaque 指针句柄 vs 整数句柄**：选指针——类型安全、天然零平台类型、无需平台头。
- **`ChqPlatformPtr<T>` RAII**：析构自动 `Destroy()`（跨模块不可 `delete`），工厂直接返回，防泄漏。
- **Media 与 GFX 共享 `NativeImageHandle`**：视频帧、外部图片（含 HEIC）统一经
  `ChqINativeImageImporter` 转 `TextureHandle`，零拷贝/降级路径统一。
- **图片解码与视频 demux 分离**：HEIC 不在 FFmpeg 支持范围，图片导入走 GFX 原生 API，
  不塞进 `ChqIMediaDemuxer`（直接响应「FFmpeg 选型可逆」硬约束）。
- **Clock 用纳秒 `ChqRationalTime`**：与项目时间轴同构，A/V 同步无需浮点。
- **工厂返回 `ChqStatus` + `ChqPlatformPtr<T>&` out 参数**：与 base 层一致，内核禁用异常。
- **ExternalImage 去冗余**：`ChqINativeImageImporter` 由 `ChqIGraphicsDevice::CreateNativeImageImporter`
  创建并绑定设备上下文，不在设备上另设 `ImportNativeImage` 方法（Metal/Vulkan 纹理必须属设备）。

## 验证（2026-09-25 真跑，含评审后两处修正）
```bash
CMAKE_BIN=/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake
$CMAKE_BIN -S . -B build -DCMAKE_BUILD_TYPE=Debug
$CMAKE_BIN --build build -j4        # 全目标 -Werror 零警告
$(dirname $CMAKE_BIN)/ctest --test-dir build
# 8/8 通过：原 6 + platform_headers_compile + platform_header_gate
```
- 门禁自测：临时往 `chq_fs.h` 插入 `jobject self_test_placeholder_ = nullptr;`，
  `check_platform_headers.py` 报 `chq_fs.h:62 [platform_type] matched 'jobject'`（EXIT=1），
  回退后恢复 `0 violation(s) / EXIT=0` —— 门禁确实会拦，非摆设。

## CORE-007：能力查询已实现（2026-09-29）

CORE-006 只冻结了 `core/include/cq/platform/chq_capabilities.h` 的接口与枚举，
`SetCapabilitiesBackend` / `QueryCapability` **长期只有声明无定义**。全仓库唯一引用是
`tests/unit/platform_headers_compile.cpp` 的 `static_assert`（编译期检查、不链接），
所以 CTest 全绿也看不出接口是断的 —— 与 CORE-006 当时的教训同型。

现已补上实现，分散在两处（平台无关 / 平台专属）：

| 位置 | 内容 |
|---|---|
| `core/src/platform/capabilities.cpp` | 内核侧注入与分发。`std::atomic<ChqICapabilities*>`，查询路径无锁（红线 #8） |
| `platform/apple/capabilities.mm` + `capabilities_apple.h` | Apple 后端（Metal / VideoToolbox）。安装入口 `cq::apple::InstallCapabilities()` |

关键约定（详见 `docs/tasks/TASK-CORE-007.md`）：
- **未注入后端一律返回 `kNo`**（安全默认：上层走降级路径；谎报 `kYes` 会崩）
- **查不到就诚实返回 `kNo` / `kDegraded`，不做乐观猜测**（不猜机型、不猜芯片）
- 解码用 `VTIsHardwareDecodeSupported`（**iOS 11+ / macOS 10.13+**，无需守卫）。
  比 PALA-011 的会话探针覆盖面更广 —— 后者依赖 iOS 17.0+ 常量，iOS 16 上无法探测
- 编码无等价直接 API，只能建一次性 `VTCompressionSession` 查询
  `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`（**iOS 17.4+**）。
  iOS 16 / 17.0~17.3 返回 **`kDegraded`**（未知，非"没有"），不抬高部署目标
- `kNpuInference` 语义收窄为「CoreML 可用」，**不代表实际跑在 ANE**（无 API 可查）
- `capabilities.mm` 的 switch **刻意不写 `default:`**，新增枚举项会先触发 `-Wswitch` 编译失败

实测结果见 `.ai/memory/baselines.md`（Intel Mac，不代表 iPhone）。

## 后续任务（依赖本接口）
- GFX-001（GFX 抽象落地）、MEDIA-010（ChqFrameProvider 语义）、AI-001（ChqIInferenceBackend）、
  AUDIO-001（音频图 + PCM 管理）、CORE-008（线程模型）、CORE-009（ChqEditorSession 门面）、
  PERF-001（性能套件）、INFRA-008（OHOS 接口编译检查）、PALD-040（Scoped Storage）、
  全部 PALA-/PALD-/OHOS 实现。

## 已知待决策 / 风险（已标出，待评审）
- `ChqPlatformPtr` 跨 C ABI：当前为 C++ 内部层；若后续 C ABI 暴露句柄需转 `uintptr_t`（BIND 层处理）。
- `ChqInferenceTensor` 维数固定 8 上限：>8 维待 AI-001 实测（hypothesis）。
- `ChqMediaFrame` 用 tagged struct 而非 `std::variant`：减少编译耦合，语义不变，MEDIA-010 可调整。
- 音频图拓扑不在 `ChqIAudioEngine` 内：混音/效果（AUDIO-004/010）在 core 基于 `ChqPcmBuffer` 实现。
- `ListDir` 签名偏底层（char* + stride），PALD-040 实现时可再润色。
- 已闭环：原 `FileHandle` 裸指针（需显式 `Close`）已改为 `ChqIFile : ChqIPlatformResource` + `ChqPlatformPtr<ChqIFile>`，
  与全接口生命周期约定统一（评审要求）。零平台类型门禁已由 `tools/platform/check_platform_headers.py`
  + ctest `platform_header_gate` 落地，可抓未来违规（已自测 `jobject` 可被抓）。

---

# 2026-10-02 追加（BIND-003 子步骤 4/5）

## 新增 / 变更的 Platform 契约

| 位置 | 变更 | 说明 |
|---|---|---|
| `platform/chq_gfx.h` | 新增 `ChqIBlitPass` + 工厂 `CreateBlitPass` | 全屏纹理拷贝。从 `core/include/cq/gfx/blit_pass.h` **移入** —— 见下 |
| `platform/chq_gfx.h` | `ChqINativeImageImporter` 新增 `ReleaseTexture` | 补生命周期闭环，`Import` 返回裸句柄而 core 侧无法释放（pitfalls P14） |
| `platform/chq_media.h` | `CreateFrameProvider` **实现落地** | 自 CORE-006（2026-09-25）悬空 7 天从未实现（pitfalls P19） |
| `platform/chq_media.h` | `ChqIFrameProvider` 新增 `GetDuration` | core 的 `ChqFrameProvider` 要求此项，Platform 原本没有，适配时无处可取 |

## 为什么 `ChqIBlitPass` 从 GFX 层移到 Platform 层

判断规则：**抽象放哪层，看实现必然落在哪。**

`ChqIBlitPass` 必然由**平台原生 shader** 实现（MSL / GLSL ES），而红线 #6 规定
平台原生 shader 只允许出现在 `platform/<platform>/`。抽象若留在 GFX 层（Platform 之上），
Platform 实现它就要反向 include GFX 头 —— 依赖方向直接冲突。

上层需要用这类 Platform pass 时走逃生口，把底层句柄传下去：
- `ChqIGfxDevice::PlatformDevice()`（既有）
- `ChqIGfxEncoder::PlatformEncoder()`（本次新增：GFX 的 `ChqIGfxEncoder` 暴露其包装的 Platform
  `ChqICommandEncoder`，供 Platform 层 pass 接收）

## Apple 侧实现

| 文件 | 实现的契约 |
|---|---|
| `platform/apple/blit_pass.mm` | `CreateBlitPass`（MSL 源在 `platform/apple/shaders/blit_fullscreen_msl.h`） |
| `platform/apple/frame_provider_apple.mm` | `CreateFrameProvider` = PALA-010 demux + PALA-011 VideoToolbox → MEDIA-020 `ChqSystemFrameProvider` |

⚠️ `CreateFrameProvider` 的 Apple 实现**不含新的编排逻辑**：取帧的跨平台编排
（精确 seek / B 帧）仍在 core（MEDIA-020 `ChqSystemFrameProvider`），Platform 侧只是
「core 编排 + 平台解码器」的装配外观。

## 未实现（诚实暴露，不伪造）

Android / HarmonyOS 均无 `CreateBlitPass` / `CreateFrameProvider` 实现。
调用预览 ABI 会在**链接期**失败 —— 这是「该端暂无预览能力」的如实暴露，
与红线 #3 一致（缺失能力不伪造空实现）。将来若要支持可选编译，走 CMake option。


---

# 2026-10-03 追加（UIA-003）

## 接口缺陷修复：`ChqIRenderTarget::GetColorTexture` 的返回语义

原 Apple 实现惰性创建 `CqTexture*` 包装返回；但该方法的用途是「把 RT 背后的
可显示纹理导出给 UI」（`cq_sdk.h` 契约：reinterpret 为 id<MTLTexture>），
包装对象被 Swift 首次真实消费即崩（objc_msgSend 打在 C++ 对象上）。

- 修复：返回 `(__bridge TextureHandle)color_tex_` —— **裸原生纹理**。
- `platform/chq_gfx.h` 已把两种句柄语义写清：
  - `ChqINativeImageImporter::Import` / `CreateTexture` 产出的 `TextureHandle`
    = `CqTexture*` 包装（可送 `ChqICommandEncoder::SetTexture`）；
  - `GetColorTexture` 产出的 = 裸原生纹理（**只用于 UI 导出**，不可送 SetTexture）。
- 验证：Debug/Release 34/34 + SharedUI 像素级用例（旧实现下必崩）。详见
  `pitfalls.md` P20。
---

# 2026-10-04 追加（CAM-001 → 已回退，相机域转 iOS 原生）

**本日先冻结后回退了相机 Platform 契约**（`platform/camera.h`、`cq_sdk.h` 相机 ABI 段、
kMultiCamCapture/kVisionDetection/kAnimalBodyPose 能力枚举与相应 Apple 实现/测试）。
传哲指示相机模块"发挥 iOS 优势、不强套跨端逻辑"（**ADR-0014 已接受**）：相机
采集/特效/录制改为 iOS 原生栈（AVFoundation + Vision/ARKit + Core Image/Metal，
App 层），不经 Platform/C ABI。

保留的**事实性知识**（防重查）：
- `AVCaptureMultiCamSession` **仅 iOS**（macOS 编译报 unavailable，pitfalls P44）；
  双摄能力运行时查 `isMultiCamSupported`。
- 相机帧过零拷贝链路的能力已具备：CVPixelBuffer(32BGRA+MetalCompat) 走
  `ChqINativeImageImporter`（PALA-002），App 层也可直接用 `CVMetalTextureCache`。
- 相机域 pts 约定沿用 120000 网格（ADR-0009）。
- 录制若未来要进 SDK，`ChqIMediaMuxer`（PALA-012）能力齐备（视频 CVPixelBuffer +
  PCM→AAC）；相机 MVP 按 ADR-0014 直接用 `AVAssetWriter`。

Platform 层无任何相机代码存留；门禁 39/39（回退后复跑，-Werror）。

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| ChqTask ID | 标题 | 状态 |
|---|---|---|
| CORE-006 | Platform 接口定义冻结 | ✅ 冻结 |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| — | 未实测（本模块无独立阶段批记录） | — |
| 2026-10-11 | INFRA-022 P2：`pal` → `platform` 全量改名后的 core 编译 + ctest | `build_core.sh --platform=apple --config=Debug --test` → **EXIT 0，46/46 通过**（113.32s）；首轮全量重编 2m55s，0 error / 0 warning。机器：Intel Mac / macOS 26.7.1 / Xcode 26.6（**非 ANE/ProRes 硬编机器，不作产品阈值**） |
| 2026-10-11 | Platform 契约头门禁（改名后） | `tools/platform/check_platform_headers.py` → **38 header(s), 0 violation(s)** |

### 调研 · 决策 · 池指针

- ADR-0011（core 调 Platform 工厂隔离）· SPEC-Platform-接口契约
- **ADR-0035（2026-10-11）PAL 统一改名为 Platform** —— 本次目录/标识符/概念名全量改名的
  决策依据、映射表、有意保留清单、三条红线。**改名后新增代码一律用 `platform` / `Platform`，
  不再出现 `pal` / `PAL`**（历史卡号 `PALA-xxx` / `PALD-xxx` 除外）。
- RESEARCH-011 §5.2（命名候选对比：platform / adapter / hal / ports / system / backend）

### 改名后的维护红线（改名时踩出来的，动本模块前先读）

1. 门禁脚本 `tools/platform/check_platform_headers.py` 里的
   `CONTRACT_DIR_NAMES` **白名单写死了目录名**。本模块目录再改名，
   白名单不同步 → 门禁**静默漏扫**（不报错、CTest 全绿）。这是 **P95 的复发**。
2. 新增 test target 时，ctest 名也要同步，否则文档里的 `ctest -R <name>` 会断链
   （编译抓不到，只有跑测试才炸）。
3. 本模块 `ChqPlatformPtr<T>` / `ChqIPlatformResource` 是生命周期契约，
   跨模块不可直接 `delete`，一律经 `Destroy()`。
