// CameraFormatSelector — 采集 format 选择的纯逻辑（2026-10-09，MultiCam 崩溃修复配套）
//
// 为什么抽成纯函数：相机 Impl 层（AVCapture）在 SPM 测试宿主里跑不了，而这次事故
// 的根因正是「选择条件」——漏掉一个约束就会在真机抛异常。选择条件必须与 AVCapture
// 解耦，才能被单测真正守住。
//
// 契约：
//   - 只在覆盖目标帧率的 format 里选；
//   - `multiCam == true` 时只认 `isMultiCamSupported` 的 format（Apple 硬性约束：
//     MultiCamSession 下 device.activeFormat 只能落在 multiCamSupported 的
//     子集里，否则会话起不来/崩溃）；
//   - 同分时取分辨率最接近目标的一个（先宽度差、再高度差），保持选择稳定。
//
// ⚠️ 本文件只描述**选择规则**，不碰 AVCapture 设备状态，故可跨平台（macOS）测试。

import Foundation

public struct CameraFormatCandidate {
    public let width: Int
    public let height: Int
    public let minFrameRate: Double
    public let maxFrameRate: Double
    /// AVCaptureDeviceFormat.isMultiCamSupported（单摄场景无此约束，传 true 即可）。
    public let multiCamSupported: Bool

    public init(width: Int, height: Int,
                minFrameRate: Double, maxFrameRate: Double,
                multiCamSupported: Bool) {
        self.width = width
        self.height = height
        self.minFrameRate = minFrameRate
        self.maxFrameRate = maxFrameRate
        self.multiCamSupported = multiCamSupported
    }
}

public enum CameraFormatSelector {
    /// 返回候选里最合适的一个下标；无可用返回 nil（调用方据此**如实降级**，不要伪造成功）。
    /// - Parameter multiCam: 当前会话是否为 AVCaptureMultiCamSession。
    ///
    /// ⚠️ 附带事实（AVCaptureSession.h 原文）：MultiCamSession 的 sessionPreset 恒为
    /// inputPriority，**不可设置**——对它 `setSessionPreset:` 会直接抛
    /// NSInvalidArgumentException 崩溃。故 multiCam 路径的采集档位只能落在设备
    /// activeFormat 上，本函数就是那条路径的选择器。
    public static func bestIndex(in candidates: [CameraFormatCandidate],
                                 targetWidth: Int,
                                 targetHeight: Int,
                                 frameRate: Double,
                                 multiCam: Bool) -> Int? {
        var best: Int?
        var bestScore = Int.max
        for (idx, c) in candidates.enumerated() {
            guard frameRate >= c.minFrameRate, frameRate <= c.maxFrameRate else { continue }
            if multiCam, !c.multiCamSupported { continue }
            let score = abs(c.width - targetWidth) + abs(c.height - targetHeight)
            if score < bestScore {
                bestScore = score
                best = idx
            }
        }
        return best
    }
}
