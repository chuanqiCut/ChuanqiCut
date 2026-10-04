// SharedUI — 相机基础美颜（CAM-003 追加：磨皮 + 美白）
//
// 平台无关纯函数，与 CameraFilterPreset 同插槽约定：输入 CIImage 输出 CIImage，
// 预览 / 拍照 / 录制三路共用（WYSIWYG）。
//
// 算法档位（诚实定位）：**基础款**——高斯模糊 + 锐化保边的近似磨皮，
// 以及曝光/亮度的小步长美白。精细美型（瘦脸/大眼）依赖人脸关键点驱动的
// Metal 网格形变，归 CAM-012/013（B 期），本结构体预留其插位（顺序：美颜 → 滤镜）。
//
// 所有效果对参数**单调**（滑杆方向可预期），off（0,0）必须恒等直通（可测）。

import CoreImage
import Foundation

/// 美颜参数。0...1，0 = 关闭。
public struct CameraBeautyParams: Equatable, Sendable {

    /// 磨皮强度（0 = 关）。
    public var smoothing: Double
    /// 美白强度（0 = 关）。
    public var brightening: Double

    public init(smoothing: Double = 0, brightening: Double = 0) {
        self.smoothing = min(max(smoothing, 0), 1)
        self.brightening = min(max(brightening, 0), 1)
    }

    /// 全关（直通）。
    public static let off = CameraBeautyParams(smoothing: 0, brightening: 0)

    public var isOff: Bool { smoothing <= 0 && brightening <= 0 }

    /// 应用美颜。off 时原样返回入参（=== 恒等，调用方无需特判）。
    public func apply(to image: CIImage) -> CIImage {
        guard !isOff else { return image }

        var result = image

        // 磨皮：高斯模糊（半径随强度单调）+ 轻度亮度锐化找回边缘轮廓。
        // clampedToExtent 防模糊边缘发黑，最后裁回原 extent。
        if smoothing > 0 {
            let radius = 3.0 + 9.0 * smoothing
            let blurred = result
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: radius,
                ])
                .cropped(to: result.extent)
            result = blurred.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.2 + 0.2 * smoothing,
                kCIInputRadiusKey: 4.0,
            ])
        }

        // 美白：小步长曝光 + 亮度（保守上限，避免过曝死白）。
        if brightening > 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: 0.45 * brightening,
            ])
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.04 * brightening,
                kCIInputSaturationKey: 1.0,
                kCIInputContrastKey: 1.0,
            ])
        }

        return result
    }
}
