// SharedUI — 检测桥纯数学：关键点帧间平滑 + Vision 坐标映射（CAM-011）
//
// 放 SharedUI 的原因与 CameraFilter/CameraBeauty 相同：纯函数、平台无关，
// 能在 macOS 宿主上单测（iOSApp 的 VisionDetector 消费本文件）。
//
// 坐标约定（B 期全链契约，CAM-013/014 消费方照此理解）：
//   **图像归一化坐标，origin 左上，两轴均 0...1，与像素尺寸无关。**
//   Vision 框架的归一化坐标是 origin 左下，经 vision*ToImageNormalized 映射翻转；
//   映射同时夹取到 0...1（Vision 偶发越界输出，夹取即「观测结构坐标恒在 0...1」
//   契约的执行点）。
//
// 平滑算法：One-Euro 简化款（自适应 EMA）。静止/微抖时用重平滑抗抖，
// 快速移动时 alpha 趋近 1 低延迟跟随——由**帧间位移**自适应，不做双滤波器
// 的完整 One-Euro（低通两级 + 频率截止），B 期精度够用且参数可解释。
// 参数中的默认值均为估算 [E]，真机实测定案。

import CoreGraphics
import Foundation

/// 关键点平滑参数。`strength` 0 = 直通（不平滑），1 = 静止时最重平滑。
public struct KeypointSmoothingParams: Equatable, Sendable {

    /// 平滑强度 0...1。静止时 alpha 下限 = 1 - strength。
    public var strength: Double
    /// 位移 → alpha 的增益：alpha = min(1, alphaMin + speedGain × 位移)。
    /// 越大则越小的移动就越早切换到跟随。默认 12 [E]。
    public var speedGain: Double

    public init(strength: Double = 0.5, speedGain: Double = 12.0) {
        self.strength = min(max(strength, 0), 1)
        self.speedGain = max(speedGain, 0)
    }

    /// 全关（输出恒等于当前帧输入）。
    public static let off = KeypointSmoothingParams(strength: 0, speedGain: 0)
}

/// 关键点序列帧间平滑（纯函数，状态由调用方经 `previous` 携带）。
///
/// 语义（CAM-011 锁定，消费方依赖）：
///   - `previous == nil`（首帧）或与 `current` 形状不一致（模型/区域变更）→
///     重置：原样返回 `current`。
///   - 某点当前缺失（nil）但上一帧存在 → **保持上一帧值**（单点dropout不闪烁）；
///     从未出现过的点输出 nil。
///   - 平滑只作用于两点都存在的点：adaptive EMA，见 KeypointSmoothingParams。
public func smoothKeypoints(previous: [CGPoint?]?, current: [CGPoint?],
                            params: KeypointSmoothingParams) -> [CGPoint?] {
    guard let previous, previous.count == current.count else {
        return current  // 首帧 / 形状变更：重置
    }
    let alphaMin = 1.0 - params.strength
    var output = current
    for i in current.indices {
        guard let c = current[i] else {
            output[i] = previous[i]  // 当前缺失：保持上帧（从未有过则仍为 nil）
            continue
        }
        guard let p = previous[i] else {
            output[i] = c  // 新出现的点：无历史，直取
            continue
        }
        let dx = Double(c.x - p.x)
        let dy = Double(c.y - p.y)
        let displacement = (dx * dx + dy * dy).squareRoot()
        let alpha = min(1.0, alphaMin + params.speedGain * displacement)
        output[i] = CGPoint(x: p.x + CGFloat(alpha) * (c.x - p.x),
                            y: p.y + CGFloat(alpha) * (c.y - p.y))
    }
    return output
}

// MARK: - Vision → 图像归一化坐标映射

/// Vision 归一化点（origin 左下）→ 图像归一化点（origin 左上），夹取到 0...1。
public func visionPointToImageNormalized(_ point: CGPoint) -> CGPoint {
    CGPoint(x: min(max(point.x, 0), 1),
            y: min(max(1 - point.y, 0), 1))
}

/// Vision 归一化矩形（origin 左下）→ 图像归一化矩形（origin 左上），夹取到 0...1。
public func visionRectToImageNormalized(_ rect: CGRect) -> CGRect {
    let flipped = CGRect(x: rect.minX, y: 1 - rect.maxY,
                         width: rect.width, height: rect.height)
    let minX = min(max(flipped.minX, 0), 1)
    let minY = min(max(flipped.minY, 0), 1)
    let maxX = min(max(flipped.maxX, 0), 1)
    let maxY = min(max(flipped.maxY, 0), 1)
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}
