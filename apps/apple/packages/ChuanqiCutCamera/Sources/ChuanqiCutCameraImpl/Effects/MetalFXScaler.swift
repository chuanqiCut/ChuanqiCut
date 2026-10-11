// MetalFXScaler — MetalFX 空间升采样封装（CAM-022，C 期；ADR-0014 §3 App 层资产）
//
// 输入 = CI 中间纹理（采集分辨率），输出 = 帧宽比 × 屏幕级别尺寸的纹理
// （Renderer 侧按 cover 比例计算输出尺寸，保持取景与关闭态逐位一致）。
//
// 支持性运行时查询（**`supportsDevice(_:)`**），不支持 = 调用方跳过 FX 走原链路
// （诚实降级，预览不因 FX 缺失受影响）。
//
// ⚠️ SDK 命名 2026-10-08 在构建机（Xcode 26.6 / iOS SDK 26.5）首次真编译对表，
// 六处与凭记忆写的不一致，已全部按 `MTLFXSpatialScaler.h` 订正（P83/P48 同族，
// 一行级）：`supports`→`supportsDevice`、`*ContentWidth/Height`→`inputWidth/outputWidth`、
// `.sdr`→`.perceptual`、`newSpatialScaler*`→`makeSpatialScaler(device:)`、
// `encodeToCommandBuffer`→`encode(commandBuffer:)`、`inputTexture`→`colorTexture`。
// **下次碰 MetalFX 前先 grep 头文件，别再凭记忆写。**

import Metal
import MetalFX

final class MetalFXScaler: @unchecked Sendable {

    /// 设备支持性查询（A12 起硬件具备；机型差异以运行时结果为准）。
    /// ⚠️ SDK 名是 `supportsDevice(_:)`（MTLFXSpatialScaler.h:95），不是 `supports(_:)`。
    static func isSupported(on device: any MTLDevice) -> Bool {
        MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    private let scaler: MTLFXSpatialScaler

    /// - Parameters: 输入/输出尺寸与颜色纹理格式。
    /// - Returns: 不支持/创建失败时 **nil**（`newSpatialScalerWithDevice:` 是 nullable，
    ///   SDK 名在 Swift 侧为 `newSpatialScaler(device:)`）。诚实降级，不伪造成功。
    ///
    /// ⚠️ SDK 属性名是 `inputWidth/inputHeight/outputWidth/outputHeight`
    /// （MTLFXSpatialScaler.h:46~55）——`*Content*` 那套属于 MTLFXSpatialScaler 实例侧。
    init?(device: any MTLDevice, inputWidth: Int, inputHeight: Int,
          outputWidth: Int, outputHeight: Int, pixelFormat: MTLPixelFormat) {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = pixelFormat
        // 枚举三档：perceptual(0, 默认) / linear(1) / hdr(2)——**没有 sdr**（SDK 26.5 头文件）。
        descriptor.colorProcessingMode = .perceptual
        guard let created = descriptor.makeSpatialScaler(device: device) else { return nil }
        scaler = created
    }

    /// 单帧升采样：把 input 内容缩放进 output（二者须按 init 尺寸创建）。
    func encode(commandBuffer: any MTLCommandBuffer, input: any MTLTexture, output: any MTLTexture) {
        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
    }
}
