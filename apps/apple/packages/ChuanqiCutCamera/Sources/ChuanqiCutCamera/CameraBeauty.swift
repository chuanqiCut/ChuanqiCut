// SharedUI — 相机美颜（CAM-003 建立，CAM-012 改薄封装）
//
// 平台无关纯函数，与 CameraFilterPreset 同插槽约定：输入 CIImage 输出 CIImage，
// 预览 / 拍照 / 录制三路共用（WYSIWYG）。
//
// 职责分层（CAM-012 起）：
//   - 本文件 = **契约层**：参数结构（单调 / off 恒等直通）+ 磨皮算法注入点
//     + 默认实现兜底。调用方（预览/拍照/录制）零改动。
//   - 算法实现 = **可替换**：iOS 侧在启动时把 Metal 双边滤波引擎
//     （iOSApp Camera/Effects/BeautyKernel）装进 CameraBeautyEngine；
//     引擎返回 nil（设备/输入不支持）时自动回落本文件的默认 CI 近似。
//     macOS 等未注入方始终走默认实现 —— 默认实现必须永远保留。
//
// 默认算法档位（诚实定位）：**基础款**——高斯模糊 + 锐化保边的近似磨皮，
// 以及曝光/亮度的小步长美白。精细美型（瘦脸/大眼）归 CAM-013。
//
// 所有效果对参数**单调**（滑杆方向可预期），off（0,0）必须恒等直通（可测）。

import CoreImage
import Foundation

/// 磨皮算法引擎签名：`(输入图, 磨皮强度 0...1) -> 结果图`。
/// 返回 nil = 引擎放弃处理（能力缺失/输入不支持），调用方回落默认实现。
/// 实现要求：对强度单调、不改变 extent、只构造 CIImage DAG（懒执行，线程安全）。
public typealias CameraBeautySmoothingEngine = @Sendable (CIImage, Double) -> CIImage?

/// 磨皮算法注入点。原生侧（iOS App）启动时安装 Metal 引擎；不安装 =
/// 默认 CI 近似。锁保护：主线程写（启动期一次），渲染/录制线程读。
/// 实现说明：Swift 5.9（本机验证工具链）没有 nonisolated(unsafe)，用
/// 锁保护类 + 不可变 static let 持有，两种语言模式（5.9/6.x）都并发安全。
public enum CameraBeautyEngine {

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var impl: CameraBeautySmoothingEngine?
        var smoothing: CameraBeautySmoothingEngine? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return impl
            }
            set {
                lock.lock()
                impl = newValue
                lock.unlock()
            }
        }
    }

    private static let storage = Storage()

    /// 当前磨皮引擎。nil = 默认实现。
    public static var smoothing: CameraBeautySmoothingEngine? {
        get { storage.smoothing }
        set { storage.smoothing = newValue }
    }

    /// 测试隔离用：恢复默认实现。
    public static func reset() {
        smoothing = nil
    }
}

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
    ///
    /// faces 两态（CAM-019 §4；**2026-10-07 修订**：nil 从「全画面兜底」改为「直通」，
    /// 传哲定则：美颜/美型/美体/美妆等一切人像能力必须**算法驱动**，无算法即无效果，
    /// 不得退化为滤镜式全画面修改）：
    ///   nil  = 无检测数据（能力缺失/未接入/首帧前）→ **直通**（旧行为已废除）；
    ///   []   = 检测过但无脸 → **直通**（对齐美型/美体「无脸直通」口径）；
    ///   非空 = 图像归一化人脸框（origin 左上，CAM-011 契约）→ 磨皮/美白
    ///          经羽化蒙版（FaceMask）只作用于人脸区域，背景保持原样。
    public func apply(to image: CIImage, faces: [CGRect]? = nil) -> CIImage {
        guard !isOff else { return image }
        guard let faces, !faces.isEmpty else { return image }
        let mask = faces.flatMap { FaceMask.mask(forNormalizedBoxes: $0, in: image.extent) }

        var result = image

        // 磨皮：注入引擎优先，放弃/未注入回落默认实现；有蒙版则混合回原图。
        if smoothing > 0 {
            let smoothed = CameraBeautyEngine.smoothing?(result, smoothing)
                ?? defaultSmoothing(result, strength: smoothing)
            result = blended(smoothed, over: result, mask: mask)
        }

        // 美白：小步长曝光 + 亮度（保守上限，避免过曝死白）；有蒙版则混合。
        if brightening > 0 {
            var brightened = result.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: 0.45 * brightening,
            ])
            brightened = brightened.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: 0.04 * brightening,
                kCIInputSaturationKey: 1.0,
                kCIInputContrastKey: 1.0,
            ])
            result = blended(brightened, over: result, mask: mask)
        }

        return result
    }

    /// 蒙版混合：白（蒙版）区取处理结果、黑区取原图。mask = nil（含蒙版构造
    /// 失败的兜底）→ 全画面采用处理结果（旧行为）。
    private func blended(_ processed: CIImage, over original: CIImage, mask: CIImage?) -> CIImage {
        guard let mask else { return processed }
        return processed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: original,
            kCIInputMaskImageKey: mask,
        ])
    }

    /// 默认磨皮（A 期口径：高斯模糊 + 亮度锐化近似保边）。
    /// 引擎未注入（macOS）或引擎放弃时走这里，是兜底不是死代码。
    private func defaultSmoothing(_ image: CIImage, strength: Double) -> CIImage {
        // 高斯模糊（半径随强度单调）+ 轻度亮度锐化找回边缘轮廓。
        // clampedToExtent 防模糊边缘发黑，最后裁回原 extent。
        let radius = 3.0 + 9.0 * strength
        let blurred = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: radius,
            ])
            .cropped(to: image.extent)
        return blurred.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: 0.2 + 0.2 * strength,
            kCIInputRadiusKey: 4.0,
        ])
    }
}
