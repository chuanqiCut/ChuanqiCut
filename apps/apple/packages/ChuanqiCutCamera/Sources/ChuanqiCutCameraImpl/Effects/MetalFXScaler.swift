// MetalFXScaler — MetalFX 空间升采样封装（CAM-022，C 期；ADR-0014 §3 App 层资产）
//
// 输入 = CI 中间纹理（采集分辨率），输出 = 帧宽比 × 屏幕级别尺寸的纹理
// （Renderer 侧按 cover 比例计算输出尺寸，保持取景与关闭态逐位一致）。
//
// 支持性运行时查询（MTLFXSpatialScalerDescriptor.supports(device:)），不支持 =
// 调用方跳过 FX 走原链路（诚实降级，预览不因 FX 缺失受影响）。iOS 16+ API，
// 部署目标 16.0 无需门控；颜色工作流 SDR（相机预览现状）。
//
// ⚠️ 实现层不在 SPM target（iOS 专属，podspec frameworks 含 MetalFX），本文件
// 的 SDK 命名（descriptor 属性/encode 入口）未经本机编译验证——构建机首编译
// 如有出入按 SDK 头文件对表（P48/P83 同族，一行级修正）。

import Metal
import MetalFX

final class MetalFXScaler: @unchecked Sendable {

    /// 设备支持性查询（A12 起硬件具备；机型差异以运行时结果为准）。
    static func isSupported(on device: any MTLDevice) -> Bool {
        MTLFXSpatialScalerDescriptor.supports(device)
    }

    private let scaler: MTLFXSpatialScaler

    /// - Parameters: 输入/输出内容尺寸（内容宽高，非纹理必须等大——纹理由调用方
    ///   创建并按需大于内容尺寸）与颜色纹理格式。
    init(device: any MTLDevice, inputWidth: Int, inputHeight: Int,
         outputWidth: Int, outputHeight: Int, pixelFormat: MTLPixelFormat) {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputContentWidth = inputWidth
        descriptor.inputContentHeight = inputHeight
        descriptor.outputContentWidth = outputWidth
        descriptor.outputContentHeight = outputHeight
        descriptor.colorTextureFormat = pixelFormat
        descriptor.colorProcessingMode = .sdr
        scaler = descriptor.newSpatialScaler(device: device)
    }

    /// 单帧升采样：把 input 内容缩放进 output（二者须按 init 尺寸创建）。
    func encode(commandBuffer: any MTLCommandBuffer, input: any MTLTexture, output: any MTLTexture) {
        scaler.inputTexture = input
        scaler.outputTexture = output
        scaler.encode(to: commandBuffer)
    }
}
