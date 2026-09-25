# PAL 接口契约（CORE-006 冻结稿）

- **状态**：冻结待评审（2026-09-25）
- **产出**：`core/include/cq/pal/*.h`（接口定义，零实现）
- **上游依赖**：CORE-001~005（base 层已全部完成并提交）
- **下游依赖**：GFX-001、MEDIA-010、AI-001、AUDIO-001、PERF-001、CORE-007、
  INFRA-008、PALD-040，以及全部 PALA-/PALD-/OHOS 实现任务。

---

## 0. 本契约的目标与边界

PAL（Platform Abstraction Layer）是**所有平台实现的契约**。在 `CORE-006` 冻结之前，
任何 PAL 实现（PALA-/PALD-/OHOS）不得开始（BACKLOG 第 327 行）。本文件冻结的接口，
iOS / macOS / Android / 鸿蒙四端必须照着实现；接口定错，四端一起返工。

**本阶段只定义接口，不实现任何平台层。** 实现是后续 PALA-xxx / PALD-xxx / OHOS 任务的事。
因此本契约中的所有类型都是：抽象基类（纯虚接口）、opaque 句柄（不完整结构体指针）、
枚举、POD 描述结构、工厂函数签名。没有任何 `.cpp` 实现。

---

## 1. 两条硬约束的满足方式（最重要）

### 1.1 不得依赖任何 FFmpeg 类型

ADR-0010 §2 明确规定。理由：FFmpeg 是 LGPL-2.1-or-later，其链接处置待法务，
将来只有两条路——**接入 FFmpeg（承担 LGPL）** 或 **改走平台原生**
（AVFoundation / MediaExtractor / OH_AVDemuxer，零 LGPL）。

**满足方式**：
- Media 领域接口（demux / frame provider）**不使用任何 `AV*` 类型**，也不引用任何
  FFmpeg 头文件。demux 的产物是本项目自己的 `MediaFrame`（携带 `NativeImageHandle`
  或 `PcmBuffer`），而非 `AVPacket` / `AVFrame`。
- 容器/编码格式以**本项目自己的枚举**表达（`ContainerFormat` / `CodecId`），
  与 FFmpeg 的 `AVCodecID` 解耦。FFmpeg 后端（MEDIA-021 / PALA-013）将来把 `AVCodecID`
  映射到本契约的 `CodecId`，映射发生在 PAL 实现内部，不污染 core 层。
- 这样即便将来从「FFmpeg demux」切到「AVFoundation / MediaExtractor」，core 层与
  其他三端实现**零改动**——这正是 ADR-0010 要求抽象的根本原因。

### 1.2 头文件零平台类型

AGENTS.root.md 红线 #2。不得出现 `id` / `NSString` / `CGFloat` / `CVPixelBufferRef` /
`jobject` / `JNIEnv` / `MTLDevice` / `ID3D11Device` 等，也不得 include 任何平台头
（`<CoreFoundation/...>`、`<jni.h>`、`<android/...>`）。

**满足方式**：
- 所有平台拥有的资源（GPU 纹理、缓冲区、设备、原生图像、文件句柄等）一律用
  **opaque 句柄**表达：在 `common.h` 中声明 `struct CqXxx;` 不完整类型，再用
  `using XxxHandle = CqXxx*;`。头文件只见到「指向不完整结构体的指针」，永远看不到
  底层平台类型，也不需要 include 任何平台头。
- 跨层只走这些 opaque 指针；平台实现在其 `.cpp` 中把 incomplete struct 定义成真正
  的平台资源包装（如 `struct CqTexture { MTLTexture* ...; }`）。
- AppleClang 下「出现平台类型反而能编译通过」，**不能只靠编译证明零平台类型**；
  也不该只靠朴素 grep（会把注释误报）。因此本契约附带**静态门禁脚本**
  `tools/pal/check_pal_headers.py`：扫描 `core/include/cq/pal/**/*.h`，**先剔除注释与
  字符串字面量**，再匹配平台类型 / 平台头 / FFmpeg 类型 / `throw` / 裸 `double`，
  命中即退出码非 0，并接入 CTest（用例 `pal_header_gate`）。零平台类型由
  （a）本契约的 opaque 设计 +（b）该门禁脚本 +（c）评审共同兜底。

---

## 2. 统一使用 base 层类型（红线 #3/#4）

| 场景 | 统一类型 | 禁止 |
|---|---|---|
| 一切时间（pts / duration / seek / clock） | `RationalTime`（timescale=120000 网格） | `double` 秒、裸 `int64_t` 毫秒 |
| 一切错误 / 停止信号 | `Status` / `StatusCode` | 异常、`errno` 直传 |
| 可能阻塞 / 长耗时接口 | 接受 `const CancelToken&` | 无取消能力的阻塞调用 |
| 需背压的管线（解码↔渲染帧队列） | `BoundedQueue<T>` | 无界 `std::queue` |
| 音频线程 | 无锁、无分配 | 热路径分配 / 加锁 |

- `RationalTime` 的 `operator double` 已被 base 层禁止；唯一浮点出口是 `ToSeconds()`，
  仅用于日志/UI，本契约所有接口**不在计算路径使用**。
- `Status::kCancelled(6000)` 的 `IsError()` 为 false——取消是独立停止信号，不是错误。
  所有长任务接口在检测到取消时返回 `kCancelled`，调用方据此做清理而非报错。

---

## 3. 资源所有权与生命周期契约

所有 PAL 资源接口继承 `IPalResource`：

```cpp
class IPalResource {
public:
    virtual ~IPalResource() = default;
    virtual void Destroy() = 0;   // 平台实现在此释放自身（含底层平台资源）
};
```

- **不可跨模块 `delete`**：PAL 实现类可能由平台分配器创建，且与调用方不在同一编译单元，
  因此一律通过 `Destroy()` 释放，而非 `delete`。
- 提供 move-only 的 RAII 包装 `PalPtr<T>`（`common.h`），析构自动调 `Destroy()`，
  工厂函数直接返回 `PalPtr<T>`，既安全又不暴露平台类型。
- 工厂函数遵循 base 层约定：返回 `Status`，资源经 out 参数（`PalPtr<T>&`）传出。

---

## 4. 八领域接口清单（签名摘要）

> 下列为**签名摘要**与设计取舍，完整定义见 `core/include/cq/pal/*.h`。
> 每个领域一个头文件；跨领域共用类型放 `common.h`。

### 4.1 GFX（gfx.h）—— 对齐 ARCH-003 §2.2 概念映射表（12 概念）

薄 GFX HAL，不抽象同步语义细粒度、不隐藏显存分配、平台特化只存在于
Platform-Native shader 层（不泄漏到 core，见 ADR-0002）。

| 概念（ARCH-003 映射） | 接口 | 关键方法（最小集） |
|---|---|---|
| Device | `IGraphicsDevice` | `CreateTexture` / `CreateBuffer` / `CreateRenderTarget` / `CreateShaderModule` / `CreatePipeline` / `CreateSampler` / `CreateFence` / `CreateCommandQueue` / `CreateNativeImageImporter` / `WaitFence` |
| CommandQueue | `ICommandQueue` | `CreateCommandBuffer` / `Submit` |
| CommandBuffer | `ICommandBuffer` | `CreateEncoder` / `Commit` / `WaitUntilCompleted` |
| Encoder | `ICommandEncoder` | `BeginRenderPass` / `SetPipeline` / `SetVertexBuffer` / `SetTexture` / `SetSampler` / `Draw` / `End` |
| Texture | `ITexture` | `GetDesc` / `GetMemoryBytes`（用于 TextureBudget 记账）/ `Destroy` |
| Buffer | `IBuffer` | `GetDesc` / `GetMemoryBytes` / `Destroy` |
| RenderTarget | `IRenderTarget` | `GetColorTexture` / `GetSize` |
| Pipeline | `IPipeline` | `Destroy` |
| ShaderModule | `IShaderModule` | 由 SPIR-V 字节或平台原生源创建 / `Destroy` |
| Sampler | `ISampler` | `Destroy` |
| Fence | `IFence` | `Signal` / `Wait` / `Destroy` |
| ExternalImage | `INativeImageImporter`（GFX-003） | `Import(NativeImageHandle) -> TextureHandle`；导入失败必须能退化为 CPU 拷贝（返回标志位，不崩溃）。由 `IGraphicsDevice::CreateNativeImageImporter` 创建，绑定到具体设备上下文 |

- 描述结构：`GraphicsDeviceDesc`（surface/device 偏好）、`TextureDesc`（格式/宽高/用途标志）、
  `BufferDesc`、`RenderTargetDesc`、`PipelineDesc`（shader 模块 + 顶点布局 + blend）、
  `ShaderModuleDesc`（SPIR-V 字节或平台原生源 + stage）、`SamplerDesc`。
- 格式/用途用平台无关枚举：`TextureFormat`（kR8/kRGBA8/kRGBA16F/kR16F/...）、
  `TextureUsage`（bitmask: kSampled/kRenderTarget/kStorage）、`BufferUsage`
  （kVertex/kIndex/kUniform/kStorage）。
- **零拷贝路径（ExternalImage）**：`INativeImageImporter::Import` 接收 `NativeImageHandle`
  （对应该平台 `CVPixelBuffer` / `AHardwareBuffer` / `OHNativeWindow`），返回 `TextureHandle`。
  由于 Metal/Vulkan 的纹理必须属于某设备上下文，导入器由 `IGraphicsDevice::
  CreateNativeImageImporter` 创建并绑定到该设备——这是 ARCH-003 §3 统一抽象的落点，
  也是对「重复定义」的去冗余：设备只暴露一个创建导入器的入口，不另设 `ImportNativeImage` 方法。
- 工厂：`Status CreateGraphicsDevice(const GraphicsDeviceDesc&, PalPtr<IGraphicsDevice>&)`。

### 4.2 Media（media.h）—— demux / 精确 seek / 帧提供

下游 `MEDIA-010`（`FrameProvider` 接口与语义）将基于本契约的 `IFrameProvider` 实现；
`MEDIA-020`（`SystemFrameProvider`）与 `MEDIA-021`（FFmpeg 后端）共享同一语义。

| 接口 | 职责 |
|---|---|
| `IMediaDemuxer` | 打开容器、枚举流、查询时长/轨道、按 `RationalTime` 精确 seek（语义统一为「精确 seek」，各端内部差异由 PAL 吸收，见 ARCH-004 §4.3）、逐包读取为 `MediaPacket` |
| `IFrameProvider` | 在 demux 之上提供「按 pts 取帧」语义：视频帧给出 `NativeImageHandle`（零拷贝），音频帧给出 `PcmBuffer`；支持正放/倒放/速度曲线（由调用方驱动 seek，接口本身中立） |

- `MediaPacket`：仅描述「压缩数据块」的元数据（`StreamIndex`、pts/dts `RationalTime`、
  `CodecId`、数据指针 + 长度）——**不含任何 `AVPacket`**。
- `MediaFrame`：tagged union（`FrameType` 区分视频/音频）：
  - 视频：`NativeImageHandle image` + `PixelFormat` + pts/duration `RationalTime` + 色彩属性
    （`ColorSpace` 枚举，承接 ARCH-003 §8 色彩管理）。
  - 音频：`PcmBuffer pcm` + pts/duration `RationalTime`。
- `StreamInfo`：轨道类型、编解码器（`CodecId` 枚举）、时间基（以 `RationalTime` 表示）、
  宽高/采样率等。
- **HEIC/HEIF 不在 FFmpeg 支持范围内**（FFmpeg 9.0.2 无该 demuxer）。而 HEIC 是 iPhone
  默认照片格式。因此 **Apple 平台图片导入走原生 API**（ImageIO / Photos / CoreGraphics），
  **不塞进 FFmpeg demux 路径**。本契约把「图片/图像导入」与「视频 demux」分离：
  `INativeImageImporter`（GFX 领域）负责把任意原生图像（含 HEIC）导入为纹理；
  `IMediaDemuxer` 只处理视频/音频容器。图片解码不依赖 FFmpeg 选型。
- 工厂：`Status CreateMediaDemuxer(const MediaSource&, PalPtr<IMediaDemuxer>&)`、
  `Status CreateFrameProvider(const MediaSource&, PalPtr<IFrameProvider>&)`。
- 长任务（打开/seek/读取）接受 `const CancelToken&`。

### 4.3 Audio（audio.h）—— PCM 缓冲与播放/采集

下游 `AUDIO-001`（音频图与 PCM 缓冲管理）、`PALA-030`（AVAudioEngine）、
`PALD-030`（Oboe）依赖。

- `PcmBuffer`：POD 描述——`SampleFormat` 枚举（kInt16/kInt32/kFloat32）、
  声道数、采样率（int）、采样帧数、数据指针 + 字节长度、pts `RationalTime`。
  零平台类型、零分配语义友好（音频线程可无锁使用）。
- `IAudioEngine`：播放/采集抽象——
  - `OpenOutputStream(PcmBuffer 参数)` / `Write(PcmBuffer)` / `Start` / `Stop` / `Close`
  - `OpenInputStream(...)` / `Read(PcmBuffer&)`（采集）
  - 支持 `const CancelToken&` 于采集阻塞读。
- 低延迟回放/采集由平台后端（AVAudioEngine / Oboe）保证；接口层只约定「写入/读取
  PCM 块」与生命周期，不暴露平台音频图细节。
- 工厂：`Status CreateAudioEngine(PalPtr<IAudioEngine>&)`。

### 4.4 Inference（inference.h）—— 推理后端抽象

下游 `AI-001`（`IInferenceBackend`）、`PALA-020`（CoreML）、`PALD-020`（TFLite）依赖。
ADR-0005：共享模型资产不共享推理 SDK（多后端 + 强制 CPU 回退）。

- `InferenceTensor`：张量描述——`DataType` 枚举（kFloat32/kFloat16/kInt32/...）、
  维度（`int64_t dims[]`）、数据指针 + 字节长度、用途（kInput/kOutput）。
- `IInferenceBackend`：
  - `LoadModel(const ModelAsset&)`（资产来源/许可/校验和由 `third_party/models/manifest.toml` 登记）
  - `CreateSession(...)` / `Run(const InferenceTensor inputs[], InferenceTensor outputs[], CancelToken)` 
  - `QueryCapability()`：返回 `CapabilityValue`（yes/degraded/no），承接 `kNpuInference`
    能力查询；后端不可用（无 ANE / 无 NNAPI）时调用方降级 GPU/CPU，接口本身中立。
- 工厂：`Status CreateInferenceBackend(BackendType, PalPtr<IInferenceBackend>&)`。
  `BackendType` 枚举（kCoreML/kTFLite/kCpuReference），但**具体后端由平台实现决定**，
  接口不绑定某一 SDK 类型。

### 4.5 FS（fs.h）—— 文件访问（含 Android Scoped Storage / MediaStore）

下游 `PALD-040`（Scoped Storage / MediaStore）依赖。

- `IFile`：文件对象，继承 `IPalResource`，`Read` / `Write` 为其方法；生命周期由
  `PalPtr<IFile>` 管理（析构 `Destroy()` 即关闭文件）。**与其它资源（Texture/Buffer/
  Pipeline/...）同一套 `PalPtr + Destroy()` 生命周期约定**，不再使用裸 opaque 指针
  （评审要求——避免同接口两套生命周期导致的句柄泄漏）。
- `IFileSystem`：抽象平台文件访问——
  - `Open(const Path&, AccessMode, PalPtr<IFile>&)`（返回 RAII 文件对象）
  - `Stat`（存在性/大小/类型）、`ListDir`、`Delete`、`Rename`、`CreateDir`
  - `ResolveMediaStoreUri`（Android：把 MediaStore URI / 相册资源映射为可打开的 `Path`）
- `Path`：本项目自己的路径抽象（UTF-8 字符串 + 命名空间标志：
  `kAppSpecific` / `kSharedDocuments` / `kMediaStore` / `kTemp`），
  **不含 `jobject` / `ContentResolver` 等平台类型**。Android 的 Scoped Storage 差异
  由 PAL 在 `ResolveMediaStoreUri` 内吸收。
- 工厂：`Status CreateFileSystem(PalPtr<IFileSystem>&)`。

### 4.6 Clock（clock.h）—— 单调时钟

- `IMonotonicClock`：`Now() -> RationalTime`。
  - **与 `RationalTime` 的关系**：时钟刻度以**纳秒**表达，即
    `RationalTime{ value_ns, 1'000'000'000 }`。整数有理数，零浮点，可直接与项目
    timescale=120000 的时间轴做 `Rescale` 对齐（如把 ns 对齐到 120000 网格用于 A/V 同步，
    见 MEDIA-030 的 audio master clock）。
  - 提供 `NowTicks()`（原始 int64 纳秒）作为高性能热路径的轻量出口，但**不进入计算
    语义**——同步计算一律走 `RationalTime`。
- 工厂：`Status CreateMonotonicClock(PalPtr<IMonotonicClock>&)`。

### 4.7 Log（log.h）—— 平台日志后端 sink

base 层已定义 `ILogSink`（CORE-003）。本领域的契约是：**PAL 必须提供一个
`ILogSink` 的平台实现**（iOS→os_log、Android→logcat、鸿蒙→hilog），并通过工厂返回。

- 契约函数（由 PAL 平台实现提供）：
  - `ILogSink* CreatePlatformLogSink();`
  - `void DestroyPlatformLogSink(ILogSink*);`
- 不在此定义任何 os_log/logcat 调用细节（那是 PAL 实现层的事）。core 层通过
  `cq::SetLogSink()` 注入即可，与 base 层解耦。
- 帧级 trace（CORE-003 的 `CQ_LOG_FRAME`）已用 `RationalTime` pts 标识帧，平台 sink
  只需把格式化好的 UTF-8 文本交给对应系统日志，无需理解帧概念。

### 4.8 Capabilities（capabilities.h）—— 能力查询

下游 `CORE-007`（`ICapabilities` 与枚举）将**实现**本契约；此处只**定义接口与枚举**。

- `Capability` 枚举（镜像 ARCH-004 §2）：`kHwDecodeH264` / `kHwDecodeHevc` /
  `kHwDecodeAv1` / `kHwDecodeProres` / `kHwEncodeH264` / `kHwEncodeHevc` /
  `kHwEncodeProres` / `k10BitPipeline` / `kHdrDisplay` / `kComputeShader` /
  `kFloatTexture` / `kExternalMemoryImport` / `kNpuInference`，外加 `kMetal` / `kGLES` /
  `kVulkan`（GPU 后端标识）。
- `CapabilityValue` 枚举：`kNo` / `kYes` / `kDegraded`（能力缺失降级仍要做，见 ARCH-003 §7）。
- `ICapabilities`：`virtual CapabilityValue Query(Capability) const = 0;`。
- 全局入口：`Status SetCapabilitiesBackend(ICapabilities*)`（注入，不接管所有权）、
  `CapabilityValue QueryCapability(Capability)`（委托给已注入后端；未注入返回 `kNo`）。
- **严禁用 `#if __APPLE__` 推断能力**（AGENTS.root.md 红线 #3 / ARCH-004 §2）：Android
  能力由机型决定、Apple 由芯片决定，一律运行时查询。

---

## 5. 关键设计取舍（评审重点）

1. **opaque 指针句柄 vs 整数句柄**：选 opaque 指针（`CqXxx*`）。理由：
   - 类型安全：传错资源类型在编译期暴露，整数句柄做不到。
   - 不暴露底层平台类型，也不需要 include 平台头——天然满足红线 #2。
   - 代价：跨 C ABI 时需转 `uintptr_t`，但那是 `cq_sdk.h` 层的事，不在本契约范围。
   - 纹理预算 `TextureBudget` 用 `int64 id` 记账（CORE-004），平台实现在 `Register`
     时把句柄地址或自增 id 作为 `id` 传入，两者不冲突。

2. **`PalPtr<T>` RAII 包装而非裸 `delete`**：避免跨模块 `delete` 风险，且调用方不易泄漏。
   工厂返回 `PalPtr<T>`，析构自动 `Destroy()`。

3. **Media 与 GFX 共享 `NativeImageHandle`**：视频解码帧、外部图片（HEIC 等）统一用
   `NativeImageHandle` 表达，由 `INativeImageImporter` 转成 `TextureHandle`。这使得
   「iPhone 默认 HEIC 照片」与「解码视频帧」走同一条零拷贝/导入路径，且都不依赖 FFmpeg。

4. **图片解码与视频 demux 分离**：因 HEIC 不在 FFmpeg 支持范围内，把图片导入放在 GFX
   的 `INativeImageImporter`（走 ImageIO/Photos/CoreGraphics 等原生 API），而非塞进
   `IMediaDemuxer`。这是对「FFmpeg 选型可逆」硬约束的直接响应。

5. **Clock 用纳秒 `RationalTime`**：把单调时钟统一为 `RationalTime{ns, 1e9}`，与项目
   时间轴同构，A/V 同步（MEDIA-030）可直接 `Rescale` 对齐，无需浮点。

6. **Capabilities 枚举在 core 冻结、实现在 CORE-007**：本契约只定义枚举与 `ICapabilities`
   接口 + 全局 `QueryCapability`，具体后端实现（读 Metal/芯片/机型）留到 CORE-007，
   符合「接口冻结、实现后做」。

7. **工厂函数返回 `Status` + out 参数**：与 base 层（`AddRational` 等）一致，内核禁用
   异常（ARCH-001），错误一律 `Status` 传播。

---

## 6. 已知待决策 / 风险（明确标出）

- **`PalPtr` 跨 C ABI 暴露**：当前 PAL 接口是 C++ 内部层，不直接是 `cq_sdk.h` 的公共 ABI。
  若后续要求 C ABI 暴露资源句柄，需统一转 `uintptr_t`——留待 BIND 层任务处理，不在本契约。
- **`InferenceTensor` 维度数上限**：暂用固定长度 `int64_t dims[8]`（覆盖常见 NCHW/NHWC），
  若后续出现 >8 维张量需改。属 hypothesis，待 AI-001 实测模型确认。
- **`MediaFrame` 用 tagged struct 而非 `std::variant`**：为减少编译耦合（Media 不强制
  包含 Audio 全量头），用带 `FrameType` 标签的扁平 struct。若下游偏好 variant 可在
  MEDIA-010 调整，但接口语义不变。
- **音频图拓扑不在 `IAudioEngine` 接口内**：AUDIO-001 的「音频图」是 core 层概念，
  本契约只抽象「PCM 输入输出引擎」，混音/效果（AUDIO-004/010）在 core 层基于 `PcmBuffer`
  实现，平台引擎只负责搬运 PCM——避免平台音频框架差异泄漏到 core。
- **`GraphicsDeviceDesc` 是否携带 surface 句柄**：当前用 `NativeImageHandle`/`void*`
  中性表达渲染目标 surface，具体平台在 PAL 实现内 reinterpret。若评审要求更严格类型，
  可改为模板或 `std::any`——但 `std::any` 会引入 `<any>`，倾向保持 `NativeImageHandle`。

---

## 7. 验收（与 BASE 层一致）

- 头文件零平台类型（门禁脚本 `tools/pal/check_pal_headers.py` + 评审；已证明能抓出
  `jobject` 等违规，误报由「先剔除注释/字符串」消除）。
- 零 FFmpeg 类型（门禁脚本扫描 `AV*` / `av_` 与 ffmpeg include，零违规）。
- 新增编译验证 TU `tests/unit/pal_headers_compile.cpp` 自洽编译 + 29 条 `static_assert`，
  注册为 ctest 用例 `pal_headers_compile`。
- 新增门禁用例 `pal_header_gate`（ctest 运行 `check_pal_headers.py`）。
- `cmake --build build -j4` + `ctest --test-dir build` → 原 6 用例 + `pal_headers_compile`
  + `pal_header_gate` 全通过。
- `-Werror` 零警告（含 `-Wconversion` / `-Wshadow` / `-Wold-style-cast`）。

---

## 跨端 UV 原点约定（2026-09-25 订立，PALA-001 实测暴露）

**约定：`uv(0,0)` 表示图像左上角。**

各后端原生约定不同，必须自行转换以对齐本约定：

| 后端 | 纹理坐标原点 | 需做的转换 |
|---|---|---|
| Metal | 左上 | 天然符合；但注意 NDC 是 y-up，`clip(-1,-1)` 为屏幕**左下**，故顶点 UV 需 `uv.y = 1 - (clip.y+1)/2` |
| GLES / Vulkan | **左下** | 需在采样时翻转 `v`，或上传纹理时翻转行序 |

### 为什么必须定死

不做统一转换时，同一张纹理、同一个 RenderGraph 在不同平台会**上下颠倒**。
PALA-001 首次真机渲染就踩到：按 `uv=(clip+1)/2` 直给，图像左上角被画到屏幕左下。

### 各后端验收

纹理绘制用例须**读回像素断言**四角颜色（而非只断言"非清屏色"），
以此证明采样管线通**且**方向正确。PALA-001 的 `pala_metal_render` 用例即此模式。
