// PortraitBlur — 景深人像虚化（CAM-023，C 期；ADR-0014 §3 App 层资产）
//
// 深度图 → 背景虚化蒙版 → CI 合成。仅服务**拍照路径**（预览虚化归后续轮，
// TASK-CAM-023 验收口径）；处理链插位 = 滤镜之后、贴纸之前（贴纸是叠加物不虚化）。
// 全 CI DAG，无自定义 shader；f 值（aperture 0...1）对虚化半径**线性单调**，
// 0 = 恒等直通。
//
// 算法：视差域（近大远小）归一化 → 近景 mask → 反相 = 背景蒙版 → 羽化（发丝无硬边，
// 验收项）→ CIBlendWithMask 虚化背景。深度图自身先高斯平滑去量化台阶。
//
// 坐标/方向：photo 内嵌 depthData 已随 connection 的呈现设置旋转（与照片同向）[E，
// 真机校验项——若主体/背景反接，翻转视差方向一行]。
// 系数全部 [E]，真机定案后锁数（进统一测试轮数值锁定）。

import AVFoundation
import CoreImage

enum PortraitBlur {

    /// 视差归一上限（DisparityFloat32，米^-1）[E]：粗归一用，设备绝对值差异待真机标定。
    static let disparityNormMax: Double = 8.0
    /// aperture=1 时的背景虚化半径（px）[E]。
    static let maxBlurRadius: CGFloat = 20
    /// 蒙版羽化半径（发丝/边缘过渡，验收「无硬边」）[E]。
    static let featherRadius: CGFloat = 6
    /// 深度图自身平滑半径（去量化台阶/噪声）[E]。
    static let depthSmoothRadius: CGFloat = 3

    /// 人像虚化合成。aperture ≤ 0 / extent 异常 → 原样返回（恒等直通）。
    static func composite(_ image: CIImage, depthData: AVDepthData, aperture: Double) -> CIImage {
        let strength = min(max(aperture, 0), 1)
        guard strength > 0,
              image.extent.width >= 4, image.extent.height >= 4 else { return image }

        // 统一到视差域（近大远小）。
        let disparity = depthData
            .converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
            .depthDataMap
        guard CVPixelBufferGetWidth(disparity) >= 2,
              CVPixelBufferGetHeight(disparity) >= 2 else { return image }

        // 深度图平滑（去台阶）→ 出血采样防边缘发黑。
        var depthImage = CIImage(cvPixelBuffer: disparity).clampedToExtent()
        depthImage = depthImage.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: depthSmoothRadius,
        ])

        // 归一化视差：R=G=B 同缩放（兼容单通道与复制灰度两种 CI 映射），再压灰度、
        // 夹取 0...1 —— 近景（视差大）= 白。
        let scale = CGFloat(1.0 / disparityNormMax)
        let normalized = depthImage.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let nearMask = normalized
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])

        // 背景蒙版 = 1 - 近景 mask，再羽化（发丝过渡）。
        let backgroundMask = nearMask
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: featherRadius])
            .cropped(to: image.extent)

        // 背景虚化 + 蒙版合成（白 = 虚化背景，黑 = 主体原图）。
        let blurred = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: maxBlurRadius * strength,
            ])
            .cropped(to: image.extent)
        return blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: backgroundMask,
        ])
    }
}
