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

**状态**：已完成并通过 ctest（`pala_encode`，14 项检查全绿；全量 19/19 通过）。

**⚠️ 接口缺口（已报告 team-lead）**：冻结契约 `docs/specs/PAL-接口契约.md` §4.2 **只定义了 `IMediaDemuxer` / `IFrameProvider`，没有 muxer/encoder 接口**；`core/**` 已冻结、本任务禁止改动。因此本期**未**新增 frozen `IMediaMuxer`，而是按 PALA-011 既定先例（`media_decode.h` 平台内部头）把编码能力做成平台内部类 `AppleVideoEncoder`。跨平台冻结接口 `IMediaMuxer` 待 EXPORT-001（core/src/export/*，本期未实现）落地时补齐，届时本能力作为 Apple 实现接入。验收要求是「能导出可被验证的 H.264 MP4」——已达成。

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
- 全量 ctest：19/19 通过（含 `pal_header_gate` 零平台类型门禁、新增 `pala_encode`），无回归。

**测试**：`tests/unit/test_media_encode_apple.cpp`（仅 `if(APPLE)` 构建），登记为 `pala_encode`。无缓冲输出（`setvbuf(stdout,nullptr,_IONBF,0)`）。

**后续任务**：
- EXPORT-001：定义 frozen `IMediaMuxer` 跨平台接口（core/src/export/*）与导出控制器（状态机/进度/取消），本 `AppleVideoEncoder` 作为 Apple 实现接入。
- 精确码率/质量档位（目前 all-intra + 20 Mbps 上限仅作验收，生产档位需与导出控制器协商）。
- 音频轨封装（本期仅视频；带音轨样本的 `gf_1080p_with_audio.mp4` 留待音频封装）。

## 相关
ARCH-004 §3、`PALA-0xx` 任务、ADR-0009（RationalTime 网格）、EXPORT-001
