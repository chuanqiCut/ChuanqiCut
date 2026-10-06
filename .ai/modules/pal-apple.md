# 模块：Apple 平台适配（PAL）

**边界**：`pal/apple/`、`apps/apple/`、`bindings/swift/`

## 目标
iOS 16+ / macOS 13+，**Apple Silicon 基线**（原方案以 Intel Mac 为基线已废弃，见 RESEARCH-001 F6）。

## 技术映射
| 能力 | 实现 |
|---|---|
| 解封装 | AVAssetReader（顺序）/ FFmpeg（精确 seek） |
| 硬解 | VideoToolbox `VTDecompressionSession` |
| 硬编 | **MVP: `AVAssetWriterInputPixelBufferAdaptor`**（系统内部走 VT）；精确码率控制时再上 `VTCompressionSession` |
| 封装 | AVAssetWriter |
| GPU | Metal |
| 零拷贝 | `CVPixelBuffer` → `CVMetalTextureCache` → `MTLTexture` |
| 音频 | AVAudioEngine |
| 推理 | CoreML（是否命中 ANE 需实测） |
| 相册 | PhotoKit + PHPicker |

## 工程结构
`iOSApp` + `MacApp` **两个 target** + `SharedUI` Swift package。
**不用 Mac Catalyst**（窗口/菜单/键盘妥协，编辑器是大交互量应用）。SwiftUI 代码共享目标 ≥80%。

## 硬约束
1. 解码时设置 `kCVPixelBufferMetalCompatibilityKey=true`
2. `CVMetalTextureCache` 按 device 持有并复用
3. 后台导出处理 `beginBackgroundTask` 与低功耗约束
4. Swift/ObjC++ 只做适配与绑定，**业务逻辑不得写在 Swift 侧**

## 验证
```bash
xcodebuild -workspace apps/apple/ChuanqiCut.xcworkspace -scheme iOSApp build
xcodebuild -workspace apps/apple/ChuanqiCut.xcworkspace -scheme MacApp build
# 零拷贝验证：Instruments 确认无 memcpy
```

## PALA-002：CVPixelBuffer → CVMetalTexture 零拷贝（已实现，2026-09-26）

**状态**：已完成并通过 ctest（`pala_native_image`，31 项检查全绿；全量 16/16 通过）。

**实现位置**：`pal/apple/gfx_metal.mm`
- `CqNativeImageImporter : INativeImageImporter`（与 `CqDevice` 同文件，`cv_keepalive_` 字段已加在 `CqTexture` 上以延长 CVMetalTextureRef/IOSurface 生命周期）。
- 零拷贝关键：`CVMetalTextureCacheCreateTextureFromImage`（`MTLPixelFormatBGRA8Unorm`）+ `CVMetalTextureGetTexture`，**全程无 `replaceRegion`、无像素缓冲拷贝**。纹理与源 `CVPixelBuffer` 共享同一 IOSurface。
- `CqDevice::CreateNativeImageImporter` 现已接上真实实现（PALA-001 里原为 `kInternal` 占位），按 `id<MTLDevice>` 创建并复用 `CVMetalTextureCacheRef`。
- **退化路径（契约要求「导入失败仍可用」）**：当零拷贝不成立（如 buffer 未设 `kCVPixelBufferMetalCompatibilityKey`、或格式非 32BGRA）时，锁定基址 + `replaceRegion` 拷进 BGRA8Unorm 纹理，`out_cpu_fallback=true`。返回 `Status::kFormatUnsupported` 当格式不可接受。
- 辅助（apple 命名空间，纯 C++ 测试 TU 可调用，声明于 `gfx_metal_internal.h`）：
  - `GetImportedTextureIosurfaceId(TextureHandle)` —— 返回纹理背后 IOSurface ID（零拷贝证据）。
  - `BenchmarkNativeImageImport(dev, zero_handle, cpu_handle, iters, out_zero_ms, out_cpu_ms)` —— 耗时代差证明。
  - `DestroyTexture(TextureHandle)` —— 释放 importer 产出的裸 `TextureHandle`（core 中 `CqTexture` 为不完整类型，测试无法自行 `Destroy`）。
- 链接：已在 `pal/apple/CMakeLists.txt` 显式登记 `IOSurface` 框架（零拷贝路径用到 `IOSurfaceGetID`）。

**零拷贝实测证据（本机 Intel Mac / macOS 15.4 / AppleClang 17）**：
- IOSurface 一致性：合成 1920×1080 帧 源 IOSurface ID == 导入纹理 IOSurface ID（193==193）；真实 `gf_1080p_h264.mp4` 首帧同样 1691==1691 → 物理零拷贝成立。
- 耗时：零拷贝 ≈0.003 ms/次 vs CPU 退化 ≈5.1 ms/次，**约 1500× 代差**（CPU 退化含整帧 8MB memcpy）。
- 端到端：PALA-010 demux + PALA-011 硬解（硬解=YES）首帧 → 本 importer 导入 → PALA-001 离屏渲染读回，**中心像素 (0,190,0,255) ≈ 真值 (0,188,0,255)**。
- **UV 原点约定**：经全屏三角形（uv.y 翻转，uv(0,0)=图像左上）绘制，渲染顶部像素==源顶部行、底部像素==源底部行（源顶=绿(0,190,0)、源底=(62,0,119)），证明**未上下颠倒**。
- 注意（已记入 pitfalls E8）：BGRA8Unorm 采样返回的是逻辑 RGBA，着色器直接 `return c`，**不要**手动 R/B 交换。

**测试**：`tests/unit/test_native_image_importer_apple.cpp`（仅 `if(APPLE)` 构建），已在 `tests/CMakeLists.txt` 登记为 `pala_native_image`，并显式链接 CoreVideo/IOSurface。

**后续任务**：
- `PALA-003`（若设立）：把 importer 接到预览渲染图（RenderGraph），替换当前测试里的手工全屏三角形管线。
- 多帧/实时管线：CVMetalTextureCache 在频繁 Import 时需 `CVMetalTextureCacheFlush` 控制膨胀（当前测试每次用完即 `Destroy`，已验证无泄漏；持续播放场景需评估）。
- HEVC 硬解（PALA-011 范围）打通后，importer 对 32BGRA 同样适用，无需改动。

## PALA-012：H.264 编码与 MP4 封装（AVAssetWriter + PixelBufferAdaptor）（已实现，2026-09-27）

**状态**：已完成并通过 ctest（`pala_encode` 14 项 + `pala_muxer` 16 项 + `pala_muxer_audio` 17 项全绿；全量 22/22 通过）。

**跨平台接缝（已补齐）**：冻结契约 `core/include/cq/pal/media.h` 已定义 `IMediaMuxer`（含 `Open / AddVideoTrack / AddAudioTrack / WriteVideoFrame / WriteAudioFrame / Finish / Cancel`）。`AppleMediaMuxer`（`pal/apple/media_muxer.{h,mm}`）实现该接口，把 `NativeImageHandle` 经 `GetCvPixelBuffer` 转回 `CVPixelBufferRef` 委托给 `AppleVideoEncoder`；全程平台类型只出现在 `pal/apple/` 的 .mm，core 头零平台类型。`WriteAudioFrame` / `AddAudioTrack` 的 AAC 音频能力见下方「音频轨（AAC 封装）」小节。

**实现位置**：`pal/apple/media_encode.{h,mm}`
- `AppleVideoEncoder`（平台内部头，仅 Apple TU 包含；pImpl 隔离 AVFoundation ObjC 对象，使 `media_encode.h` 保持纯 C++）。
- 编码+封装：`AVAssetWriter`（`AVFileTypeMPEG4` → .mp4，`AVVideoCodecTypeH264`）+ `AVAssetWriterInputPixelBufferAdaptor`。
- **无色彩转换**：输入 `CVPixelBuffer`（BGRA 或 NV12）按**源格式 1:1 拷入 encoder 自管 buffer** 再 `appendPixelBuffer:withPresentationTime:`。刻意不做 RGB↔YUV 转换，从根上规避「通道交换类 bug」（PALA-002 教训：绿条 R==B 会让此类 bug 被掩盖）。
- **无时间漂移**：每帧 PTS = `RationalTime` 直接转 `CMTime`（`CMTimeMake(pts.value, pts.timescale)`），`writer.movieTimeScale` 设为同一网格（120000，ADR-0009），样本 PTS 与项目时间轴同构，杜绝累积漂移。`startSessionAtSourceTime:` 在首个样本 append 前用首帧 PTS 启动。
- **收尾/取消**：`Finish()` 阻塞等待 `finishWritingWithCompletionHandler:`；`Cancel()` 调 `cancelWriting` 并删除半成品文件（取消是独立停止信号，非错误，与 `Status::kCancelled` 语义闭合）。
- 错误路径：writer 非 Writing 态 / `append` 返回 NO 且 writer Failed / Open 创建失败 / `canAddInput` / `startWriting` 失败 → 均返回 `kEncodeError` 等明确 `Status`；轨道已结束、写入器状态不对均有对应分支。
- **硬件编码探针**：Open 时用一次性 `VTCompressionSession`（带 `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder`）查询本机是否真能硬件编码，`IsHardwareAccelerated()` 如实上报；不可用则 AVAssetWriter 走软件回退，仍能导出 H.264。
- 接受 `const CancelToken&`：背压等待（`input.isReadyForMoreMediaData`）期间以 1ms 轮询响应取消，返回 `kCancelled`（非错误）。

**CMake 登记（三处，防「符号未定义」链接陷阱）**：`pal/apple/CMakeLists.txt` 的 `add_library` 源列表、`set_source_files_properties(... -fobjc-arc)`、框架链接（AVFoundation/CoreMedia/VideoToolbox/CoreVideo 已在既有 `find_library`+`target_link_libraries` 中，AVAssetWriter 不需要新框架）。测试 `cq_tests_pala_encode` 在 `tests/CMakeLists.txt` 的 `if(APPLE)` 块登记。

**端到端实测证据（本机 Intel Mac / macOS 15.4 / AppleClang 17 / i7-9750H）**：
- 链路：`gf_1080p_h264.mp4`（150 帧 @30fps H.264 1920×1080）→ PALA-010 真实 demux → PALA-011 硬解（**硬解=YES**）→ `AppleVideoEncoder` 写前 60 帧 → 落盘 `/tmp/cq_pala_encode_out.mp4`。
- **ffprobe 验证产出**：`codec_name=h264`、`width=1920 height=1080`、`nb_read_frames=60`（== 写入帧数 N）、`format_name=mov,mp4,m4a,3gp,3g2,mj2`、`duration=2.000000`（== N/30s，帧数/帧率吻合）。文件可被 ffprobe 正常解析（非损坏）。文件大小 ≈195 KB（SMPTE 彩条全 I 帧且内容平坦，压缩极好；码率上限 20 Mbps）。
- **像素正确性**：重解码产出首帧中心像素 `(R,G,B,A)=(0,190,1,255)` ≈ 真值 `(0,188,0,255)`，且 `g > r+30 && g > b+30`（绿主导、通道顺序未颠倒）。**刻意选绿条而非底部紫条 (62,0,119)** 以暴露 RGB 交换类 bug。
- **硬编是否真生效**：本机 H.264 硬件编码能力探针 = **YES（可用）**；AVAssetWriter 在可用时默认走 VT 硬件路径，故本次导出应为硬件编码。诚实边界：AVAssetWriter 未在 API 层面暴露「本次是否真硬件」的运行时回读，本 SDK 未强制，这是如实声明的限制。
- 取消路径冒烟：`Open` 后 `Cancel` 安全中止并删除半成品文件（断言文件不存在）。
- 全量 ctest：22/22 通过（含 `pal_header_gate` 零平台类型门禁、`pala_encode` / `pala_muxer` / `pala_muxer_audio`），无回归。

**测试**：`tests/unit/test_media_encode_apple.cpp`（仅 `if(APPLE)` 构建），登记为 `pala_encode`。无缓冲输出（`setvbuf(stdout,nullptr,_IONBF,0)`）。

**后续任务**：
- EXPORT-001：定义 frozen 导出控制器（状态机/进度/取消），本 `AppleMediaMuxer` 作为 Apple 实现接入。
- 精确码率/质量档位（目前 all-intra + 20 Mbps 上限仅作验收，生产档位需与导出控制器协商）。

## PALA-012 音频轨（AAC 封装）（已实现，2026-09-28）

**状态**：已完成并通过 ctest（`pala_muxer_audio`，17 项检查全绿）。ffprobe 实测产出文件含 `codec=aac / sample_rate=48000 / channels=2`，时长与写入吻合，端到端真打通。

**接口**：`IMediaMuxer::AddAudioTrack(const AudioTrackConfig&)` + `WriteAudioFrame(const PcmBuffer&, const RationalTime&, const CancelToken&)`（`media.h` 既有签名，本任务只做实现，未改接口）。

**实现位置**：`pal/apple/media_encode.{h,mm}`（`AppleVideoEncoder` 扩展，与视频共用同一 `AVAssetWriter`）。
- **共用 writer、惰性 startWriting**：AVAssetWriter 要求所有 `AVAssetWriterInput` 在 `startWriting` 之前 `addInput`。原 `Open()` 内即 `startWriting` 会让事后 `AddAudioTrack` 失效，故改为「首个样本（视频或音频）写入时惰性 `startWriting`」。视频轨 `AddVideoTrack` 先于音频轨 `AddAudioTrack`（契约要求，writer 由视频轨建立），两者都在首个 append 前完成 `addInput`，不破坏 AVFoundation 时序约束。
- **AAC 音频输入**：`AddAudioTrack` 按 `AudioTrackConfig`（采样率/声道/码率档位 `BitrateTier`）建 `AVAssetWriterInput`（`kAudioFormatMPEG4AAC`，码率 64k/128k/192k/256k 映射低/中/高/无损）。非 AAC codec 如实返回 `kEncodeUnsupported`。
- **PCM → AAC**：`WriteAudioFrame` 按 `PcmBuffer` 实际格式（本期 `kFloat32` / `kInt16`）构造线性 PCM 的 `CMFormatDescription`（`AudioStreamBasicDescription`）+ `CMBlockBuffer`，产出 `CMSampleBuffer` 喂给 AAC 输入；AVFoundation 内部编码为 AAC。每样本时长 `CMTimeMake(1, sample_rate)`，首样本 PTS 经 `startSessionAtSourceTime:` 设定会话起点（取视频/音频首个样本 PTS 的 min，正常导出两轨均从 0 起）。调用方按 PTS 非递减喂块，音频块 PTS 用项目网格 120000、非整除须显式舍入。
- **背压/取消**：与视频一致，`audio_input.isReadyForMoreMediaData` 忙时 1ms 轮询，被取消返回 `kCancelled`（非错误）。`Finish` 同时 `markAsFinished` 视频与音频输入后 `finishWriting`。
- 关键路径加 `CQ_PERF_SCOPE(PerfStage::kMux, pts)` 性能埋点。

**CMake 登记**：`pal/apple/CMakeLists.txt` 新增 `AudioToolbox` 框架链接（`AudioStreamBasicDescription` / `CMAudioFormatDescriptionCreate`）；测试 `cq_tests_pala_muxer_audio` 在 `tests/CMakeLists.txt` 的 `if(APPLE)` 块登记，显式链接 CoreVideo。

**端到端实测证据（本机 Intel Mac / macOS 15.4 / AppleClang 17）**：
- 链路：合成 BGRA CVPixelBuffer（640×360 视频轨）+ 合成 float32 立体声 440 Hz 正弦 PCM（100 块 × 1024 样本 @48000 ≈ 2.133 s）→ `IMediaMuxer`（`AppleMediaMuxer` → `AppleVideoEncoder`）→ 落盘 `/tmp/cq_muxer_audio_out.mp4`。
- **ffprobe 验证产出**：`index=1 codec_name=aac codec_type=audio sample_rate=48000 channels=2`；视频轨 `codec=h264` 同时存在；`stream duration=2.133333` 与写入时长吻合。
- **契约验证**：`AddVideoTrack` 前 `AddAudioTrack` → 错误（writer 未建立）；`AddAudioTrack(kMp3)` → `kEncodeUnsupported`；`AddAudioTrack` 前 `WriteAudioFrame` → 错误。均如实返回，不伪造。

**已知限制（诚实报告，非「源音轨已打通」）**：
- **源音频回路未打通**：仓库 `tests/golden/frames/gf_1080p_with_audio.mp4`（aac / 44100 Hz / mono）虽可被 PALA-010 解封装出音频包（`MediaPacket{codec=kAac}`），但 PALA-010 是 **passthrough demux，不含解码**，没有 AAC→PCM 解码器把压缩包转成 `PcmBuffer` 喂入 `WriteAudioFrame`。因此「从源文件取音频写回」卡在**解码环节（AUDIO-001 本期未实现）**，本任务只验证了「合成 PCM 能写出 AAC 音轨」。
- `WriteAudioFrame` 仅支持 `kFloat32` / `kInt16`；`kInt32` / `kFloat64` 返回 `kEncodeUnsupported`。

**测试**：`tests/unit/test_media_muxer_audio_apple.cpp`（仅 `if(APPLE)` 构建），登记为 `pala_muxer_audio`。无缓冲输出。

**后续任务**：
- AUDIO-001：实现 AAC→PCM 解码，打通「源文件音频 → WriteAudioFrame」回路（届时需把 44100/mono 源映射为对应 `AudioTrackConfig`）。
- 多语言/多音轨、`AVChannelLayoutKey` 显式布局、采样率/声道与 `AudioTrackConfig` 不一致时的重采样策略。

## 相关
ARCH-004 §3、`PALA-0xx` 任务、ADR-0009（RationalTime 网格）、EXPORT-001

## PALA-011 重排与 Flush 语义修正（MEDIA-021，2026-10-04，ADR-0014）

`VideoToolboxDecoder` 的三条硬规则（均为逐帧 pts 断言实测暴露，勿回退）：

1. **输出回调按完成序（≈dts 序），不是显示序**（P39）。`PopFrame` 按
   「显示序连续性」重排弹出：队列最小 pts 帧可弹 ⇔
   `pts == 上一弹出帧 pts + 其 duration`；不匹配时等在途帧（pending 非空）
   或返回 kIoNotFound 让 provider 继续喂包。无需知道 B 帧深度，VFR 兼容。
2. **回调携带 dts 做完成登记**：`DecodeFrame` 传 `CFRetain(sbuf)` 作
   sourceFrameRefCon，回调取 dts 后 CFRelease；成败都从 `pending_dts_pts_`
   移除（丢帧/解错的包不能永远压住重排等待）。**Feed 登记必须发生在
   DecodeFrame 之前**（回调可能在另一线程立即完成）。
3. **Flush = 先 `WaitForAsynchronousFrames` 再清队**（P41）：在途回调可能在
   Flush 后到达，只清缓冲会把上一解码区间的旧帧漏进新序列首弹。
   首帧时长兜底用 **dts 差**（P40：B 帧文件前两包 pts 差 = (bframes+1) 帧）。

回归：`pala_decode` / `frame_provider_apple` / `media_sequential_real`。

## PALA-011 增补（MEDIA-022，2026-10-05）：HEVC 硬解支持

- `VideoToolboxDecoder::Open` 接受 **H.264 + HEVC**（'hvc1'/'hev1'；杜比视界
  'dvh1'/'dvhe' 按 HEVC 基底尝试）。demuxer 侧 HEVC 映射/IRAP 判定本就绪。
- **两个实测坑（golden `gf_1080p_hevc.mp4` = 'hev1' 8-bit 4:2:0）**：
  1. demuxer `VideoCodecToCq` 原先不认 'hev1'/'dvh1'/'dvhe' → 报 kUnknown；
  2. **VT 解码器按 'hvc1' 注册**，'hev1' 格式描述建会话返回 **-12906
     kVTUnsupportedDecompressionErr** —— 修法：用同一份 hvcC 重建
     subtype='hvc1' 的 `CMVideoFormatDescription`（码流与参数集相同，差别只在
     随流参数集允许性）。iPhone 实拍 = 'hvc1' 不受影响。
- 验收：`pala_decode` 参数化为 H.264 + HEVC 双节（150 帧/pts 单调/像素/端到端）；
  probe（完整解码管线打开）对 HEVC golden 返回 0。
- 绑定层：`probeMediaDurationDetailed`（失败透传原始状态码）+ `Status: Error`；
  UI 文案按 1000/2000/2001 分级（SharedUI `Status.userText`）。

## PALA-011 增补（MEDIA-025，2026-10-06）：解码色彩空间管理

- `VideoToolboxDecoder::Open` 读源色彩标签（CMFormatDescription 扩展 ColorPrimaries/
  TransferFunction/YCbCrMatrix）；HDR 判定纯函数 `IsHdrColorSource`（HLG/PQ 传递函数
  或 2020 原色域+非 709 传递 → 转；**标签缺失 = 不转换，行为同旧**）。
- HDR 源对 VT 会话设 `kVTPixelTransferPropertyKey_Destination{ColorPrimaries,
  TransferFunction,YCbCrMatrix}` = ITU_R_709_2 —— 解码+色彩转换 VT 内部一体完成；
  属性被拒时如实日志并保持旧行为（不 fail Open）。
- 诊断：`Open 完成` 行带源标签与转换状态。⚠️ 'hvc1' 重建会丢色彩扩展——标签必须
  在重建前从原 fd 读取（MEDIA-022 与 025 的顺序耦合）。
