// ChuanqiCutCamera — 贴纸/头部道具锚定纯函数（CAM-014，B 期）
//
// 锚定模型（TASK-CAM-014 实现要点）：双眼中心 = 位置、双眼间距 = 尺度、
// 眼线角度 + 头部 roll = 旋转；帧间平滑复用 CAM-011（消费方在检测回调侧对
// 输入关键点先平滑，本层无状态、纯函数）。数值锁定走单测（统一测试轮补齐）。
//
// 坐标契约：归一化坐标，origin **左上**（CAM-011 全链契约）；y 向下为正，
// 因此 atan2 得到的正角 = 屏幕顺时针。前摄镜像在 connection 层（buffer 已
// 镜像，关键点与画面同源），本层不做镜像补偿。
//
// v1 边界（诚实定位）：2D 仿射锚定（位置/等比缩放/平面旋转）。yaw/pitch 的
// 3D 透视贴合、多贴纸层级规则归 GPU 叠加 pass 与资产格式（下一轮）；
// 锚点垂直偏移按资产类型经 liftRatio 配置（眼镜 ≈ 0、帽子 > 0）。

import CoreGraphics
import Foundation

/// 贴纸锚定姿态：GPU 叠加 pass 与 UI 选择条预览共用的输入（WYSIWYG 同源）。
public struct StickerPlacement: Equatable, Sendable {
    /// 归一化锚点中心（贴纸纹理中心要对齐的点）。
    public var center: CGPoint
    /// 等比缩放系数 = 实际双眼间距 / 基准双眼间距。
    public var scale: CGFloat
    /// 平面旋转（弧度，屏幕顺时针为正）= 眼线角 + 头部 roll。
    public var rotationRadians: CGFloat

    public init(center: CGPoint, scale: CGFloat, rotationRadians: CGFloat) {
        self.center = center
        self.scale = scale
        self.rotationRadians = rotationRadians
    }
}

/// 人/宠通用双眼锚点（CAM-024）：人脸路径从 FaceObservation 派生（实现层），
/// 动物路径从 AnimalObservation.pose 的双眼关节派生——锚定数学对两者**同构**，
/// 本结构让 StickerAnchor/StickerOverlay 零重复复用。
public struct StickerEyeAnchor: Equatable, Sendable {
    /// 左眼（图像归一化 origin 左上）。
    public let leftEye: CGPoint
    /// 右眼。
    public let rightEye: CGPoint

    public init(leftEye: CGPoint, rightEye: CGPoint) {
        self.leftEye = leftEye
        self.rightEye = rightEye
    }
}

public enum StickerAnchor {

    /// 基准双眼间距（归一化）：贴纸资产在**此间距下按原生尺寸 1:1 锚定**。
    /// 0.16 [E]——正面脸双眼间距常见归一化区间的下沿，资产定稿后校准锁数。
    public static let referenceEyeDistance: CGFloat = 0.16

    /// 默认头顶上移系数：锚点中心在双眼中点上方 headTopLift × 眼距处
    /// （归一化 y 向下为正，向上 = y 减小）。帽子/发饰类默认值 [E]；
    /// 眼镜类资产传 0，嘴部道具传负值——按资产在 liftRatio 里覆写。
    public static let headTopLiftRatio: CGFloat = 0.55

    /// 单贴纸锚定。任一眼睛关键点缺失 → nil（上层跳过该贴纸，不猜位置）。
    ///
    /// - Parameters:
    ///   - liftRatio: 锚点相对双眼中点的垂直偏移（× 眼距，向上为正）。
    ///   - referenceEyeDistance: 基准眼距（资产标定值，默认全局常量）。
    ///   - roll: 头部 roll（弧度，Vision 口径右倾为正），直接叠加进屏幕旋转 [E]。
    public static func placement(eyeLeft: CGPoint?, eyeRight: CGPoint?,
                                 roll: Double? = nil,
                                 liftRatio: CGFloat = StickerAnchor.headTopLiftRatio,
                                 referenceEyeDistance: CGFloat = StickerAnchor.referenceEyeDistance) -> StickerPlacement? {
        guard let left = eyeLeft, let right = eyeRight,
              referenceEyeDistance > 0 else { return nil }
        let dx = right.x - left.x
        let dy = right.y - left.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0, distance.isFinite else { return nil }
        let mid = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        return StickerPlacement(
            center: CGPoint(x: mid.x, y: mid.y - distance * liftRatio),
            scale: distance / referenceEyeDistance,
            rotationRadians: atan2(dy, dx) + (roll.map { CGFloat($0) } ?? 0))
    }

    /// 人/宠通用双眼锚点入口（CAM-024）：与 eyeLeft/eyeRight 版本同一数学。
    public static func placement(eyeAnchor: StickerEyeAnchor,
                                 roll: Double? = nil,
                                 liftRatio: CGFloat = StickerAnchor.headTopLiftRatio,
                                 referenceEyeDistance: CGFloat = StickerAnchor.referenceEyeDistance) -> StickerPlacement? {
        placement(eyeLeft: eyeAnchor.leftEye, eyeRight: eyeAnchor.rightEye,
                  roll: roll, liftRatio: liftRatio,
                  referenceEyeDistance: referenceEyeDistance)
    }

    /// 多贴纸批量锚定：输入与输出按序对应，单张失败（nil 眼点）该位为 nil，
    /// 不影响其余（上层跳过 nil 位渲染）。v1 不做遮挡排序——层级规则归资产格式。
    public static func placements(_ stickers: [(eyeLeft: CGPoint?, eyeRight: CGPoint?,
                                                roll: Double?, liftRatio: CGFloat?)],
                                  referenceEyeDistance: CGFloat = StickerAnchor.referenceEyeDistance) -> [StickerPlacement?] {
        stickers.map { sticker in
            placement(eyeLeft: sticker.eyeLeft, eyeRight: sticker.eyeRight,
                      roll: sticker.roll,
                      liftRatio: sticker.liftRatio ?? headTopLiftRatio,
                      referenceEyeDistance: referenceEyeDistance)
        }
    }
}
