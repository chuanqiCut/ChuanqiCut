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

## 相关
ARCH-004 §3、`PALA-0xx` 任务
