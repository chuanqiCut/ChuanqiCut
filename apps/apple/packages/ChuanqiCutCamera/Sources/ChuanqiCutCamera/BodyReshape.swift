// ChuanqiCutCamera — 美体参数纯函数（CAM-025，C 期「美体起步」）
//
// 瘦腰/长腿：人体姿态（CAM-011 BodyPoseObservation，单主体策略）→ 位移场控制点。
// 控制点结构直接复用 FaceWarpControl，GPU 复用 face_warp.metal——控制点场与
// 人脸美型（CAM-013）**同构，C 期零新 shader**。
//
// 契约层输入为姿态的**中性投影**（BodyReshapeAnchors，实现层从观测结构提取后
// 喂入——与 CameraReshapeAnchors 同思路），不依赖 Vision/观测类型，macOS 可测。
// 关键点已在检测器侧平滑（CAM-011），此处不做二次平滑。
//
// 坐标契约：归一化 origin 左上（CAM-011 全链契约）。几何假设**人体近直立**：
// 中轴取水平方向（肩中/髋中 x 均值），大幅侧身/躺姿不成立 [E]，不做旋转中轴。
// 位移/半径系数全部 [E]，真机定案后锁数。
//
// 处理链插位（后续接线轮）：美颜 → 美型 warp → **美体 warp** → 滤镜 → 贴纸。

import CoreGraphics
import Foundation

/// 美体滑杆参数。0...1，0 = 关闭；控制点位移对滑杆**线性单调**，off 恒等直通。
public struct BodyReshapeParams: Equatable, Sendable {

    /// 瘦腰强度（0 = 关）。
    public var slimWaist: Double
    /// 长腿强度（0 = 关）。
    public var lengthenLegs: Double

    public init(slimWaist: Double = 0, lengthenLegs: Double = 0) {
        self.slimWaist = min(max(slimWaist, 0), 1)
        self.lengthenLegs = min(max(lengthenLegs, 0), 1)
    }

    /// 全关（直通）。
    public static let off = BodyReshapeParams()

    public var isOff: Bool { slimWaist <= 0 && lengthenLegs <= 0 }
}

/// 美体锚点中性结构（CAM-011 姿态关节的中性投影）。
/// 四关节全部到位才能建立躯干几何——任一缺失整体跳过（不猜，与 013 同纪律）。
public struct BodyReshapeAnchors: Equatable, Sendable {

    public var leftShoulder: CGPoint
    public var rightShoulder: CGPoint
    public var leftHip: CGPoint
    public var rightHip: CGPoint

    public init(leftShoulder: CGPoint, rightShoulder: CGPoint,
                leftHip: CGPoint, rightHip: CGPoint) {
        self.leftShoulder = leftShoulder
        self.rightShoulder = rightShoulder
        self.leftHip = leftHip
        self.rightHip = rightHip
    }
}

/// 美体控制点生成（纯函数）。输出顺序稳定（左腰、右腰、髋），便于数值锁定。
public enum BodyWarpGeometry {

    /// 腰侧水平收缩幅度 = waistGain × strength × 半躯干宽。
    static let waistGain: CGFloat = 0.25                    // [E] 真机定案
    static let waistRadiusToTorsoWidth: CGFloat = 0.6       // [E]
    /// 髋上提幅度（长腿 = 躯干下缘上移、下肢比例变长）= legGain × strength × 躯干长。
    static let legGain: CGFloat = 0.12                      // [E]
    static let legRadiusToTorsoWidth: CGFloat = 0.5         // [E]

    public static func controls(from anchors: BodyReshapeAnchors,
                                params: BodyReshapeParams) -> [FaceWarpControl] {
        guard !params.isOff else { return [] }

        let shoulderMid = CGPoint(x: (anchors.leftShoulder.x + anchors.rightShoulder.x) / 2,
                                  y: (anchors.leftShoulder.y + anchors.rightShoulder.y) / 2)
        let hipMid = CGPoint(x: (anchors.leftHip.x + anchors.rightHip.x) / 2,
                             y: (anchors.leftHip.y + anchors.rightHip.y) / 2)
        let shoulderWidth = hypot(anchors.rightShoulder.x - anchors.leftShoulder.x,
                                  anchors.rightShoulder.y - anchors.leftShoulder.y)
        let hipWidth = hypot(anchors.rightHip.x - anchors.leftHip.x,
                             anchors.rightHip.y - anchors.leftHip.y)
        let torsoWidth = max(shoulderWidth, hipWidth)
        let torsoLength = hypot(hipMid.x - shoulderMid.x, hipMid.y - shoulderMid.y)
        guard torsoWidth > 0, torsoLength > 0 else { return [] }

        var controls: [FaceWarpControl] = []

        // 瘦腰：躯干中段（肩中-髋中垂直中点）左右缘向中轴水平收缩（比例收缩，
        // 与 013 颊点同式）。中轴按直立假设取水平 x（见文件头几何假设）。
        if params.slimWaist > 0 {
            let waistY = (shoulderMid.y + hipMid.y) / 2
            let axisX = (shoulderMid.x + hipMid.x) / 2
            let halfWidth = torsoWidth / 2
            let push = CGFloat(params.slimWaist) * waistGain * halfWidth
            controls.append(FaceWarpControl(
                center: CGPoint(x: axisX - halfWidth, y: waistY),
                radius: waistRadiusToTorsoWidth * torsoWidth,
                offset: CGVector(dx: push, dy: 0)))     // 左缘向右（朝中轴）
            controls.append(FaceWarpControl(
                center: CGPoint(x: axisX + halfWidth, y: waistY),
                radius: waistRadiusToTorsoWidth * torsoWidth,
                offset: CGVector(dx: -push, dy: 0)))    // 右缘向左
        }

        // 长腿：髋中点上提（origin 左上：dy 负 = 视觉向上 = 躯干下缘上移）。
        if params.lengthenLegs > 0 {
            let lift = CGFloat(params.lengthenLegs) * legGain * torsoLength
            controls.append(FaceWarpControl(
                center: hipMid,
                radius: legRadiusToTorsoWidth * torsoWidth,
                offset: CGVector(dx: 0, dy: -lift)))
        }

        return controls
    }
}
