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

## 相关
ARCH-004 §3、`PALA-0xx` 任务
