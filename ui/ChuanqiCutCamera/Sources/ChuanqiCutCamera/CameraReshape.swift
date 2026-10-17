// ChuanqiCutCamera — 美型形变参数纯函数（CAM-013，B 期）
//
// 契约层职责（对齐 CameraBeauty / FaceMask 分层惯例）：
//   - 滑杆参数结构（单调 / off 恒等直通）；
//   - 由关键锚点生成**局部圆域位移场控制点**（归一化坐标）。
// 消费方：实现层 Effects/FaceWarp（GPU warp，下一轮接入）把控制点展开成逐像素
// 采样偏移；处理链插位锁定 磨皮 → 美型 warp → 滤镜（TASK-CAM-013 验收项，
// 变更须同步三处消费方）。本文件不含 GPU/Metal 代码，macOS 宿主可编译可单测。
//
// 坐标契约：归一化坐标，origin **左上**（CAM-011 全链契约，同 FaceMask 输入口）。
// GPU 侧自行把归一化位移乘以帧宽/高换算像素——本层无 extent 依赖。
// 前摄镜像在 connection 层（buffer 已镜像，关键点与画面同源），本层不做镜像处理。
//
// 算法口径（RESEARCH-002 §5；位移/半径系数全部 [E]，真机人工定案后锁数）：
//   大眼     = 上睑上推 + 下睑下推（成对反向局部平移 → 视觉放大）；
//   下巴收缩 = 下颌最低点向脸心（上）平移；
//   瘦脸     = 左右颊轮廓点向中线水平收缩（「整体经纬收缩」的 v1 简化，
//              只做水平维；垂直收缩待真机观感反馈再加）。
// 每项效果独立降级：对应锚点缺失只跳过该项，不影响其他项。

import CoreGraphics
import Foundation

/// 美型滑杆参数。0...1，0 = 关闭；控制点位移对滑杆**线性单调**，off 恒等直通。
public struct CameraReshapeParams: Equatable, Sendable {

    /// 瘦脸强度（0 = 关）。
    public var slimFace: Double
    /// 大眼强度（0 = 关）。
    public var enlargeEye: Double
    /// 下巴收缩强度（0 = 关）。
    public var chinShrink: Double

    public init(slimFace: Double = 0, enlargeEye: Double = 0, chinShrink: Double = 0) {
        self.slimFace = min(max(slimFace, 0), 1)
        self.enlargeEye = min(max(enlargeEye, 0), 1)
        self.chinShrink = min(max(chinShrink, 0), 1)
    }

    /// 全关（直通）。
    public static let off = CameraReshapeParams()

    public var isOff: Bool { slimFace <= 0 && enlargeEye <= 0 && chinShrink <= 0 }
}

/// 美型锚点中性结构：实现层从 FaceObservation（Vision 关键点）提取后喂入；
/// 契约层不依赖 Vision 类型（与 FaceMask 收 [CGRect] 同思路），macOS 可测。
/// 可选字段 = 该项效果的条件（缺失时对应效果跳过，不做兜底猜测）。
public struct CameraReshapeAnchors: Equatable, Sendable {

    /// 左眼区域中心（归一化）。
    public var leftEyeCenter: CGPoint?
    /// 左眼区域半高（眼闭合时趋 0，该项自动失效）。
    public var leftEyeHalfHeight: CGFloat?
    /// 右眼区域中心。
    public var rightEyeCenter: CGPoint?
    public var rightEyeHalfHeight: CGFloat?
    /// 下颌最低点（视觉意义下的下巴尖，归一化 y 最大）。
    public var chin: CGPoint?
    /// 面部左边缘轮廓点（归一化 x 最小）。
    public var cheekLeft: CGPoint?
    /// 面部右边缘轮廓点（归一化 x 最大）。
    public var cheekRight: CGPoint?
    /// 脸中心（收缩目标参考，如双瞳中点或脸框中心）。
    public var faceCenter: CGPoint
    /// 归一化脸尺度基准（如双瞳距/脸框对角），所有作用半径的参照。
    public var faceScale: CGFloat
    /// 头部 roll（弧度，Vision 口径右倾为正）；美型 warp 不消费，
    /// 贴纸锚定（StickerAnchor）与美型共用本结构时携带。
    public var roll: Double?

    public init(leftEyeCenter: CGPoint? = nil, leftEyeHalfHeight: CGFloat? = nil,
                rightEyeCenter: CGPoint? = nil, rightEyeHalfHeight: CGFloat? = nil,
                chin: CGPoint? = nil, cheekLeft: CGPoint? = nil, cheekRight: CGPoint? = nil,
                faceCenter: CGPoint, faceScale: CGFloat, roll: Double? = nil) {
        self.leftEyeCenter = leftEyeCenter
        self.leftEyeHalfHeight = leftEyeHalfHeight
        self.rightEyeCenter = rightEyeCenter
        self.rightEyeHalfHeight = rightEyeHalfHeight
        self.chin = chin
        self.cheekLeft = cheekLeft
        self.cheekRight = cheekRight
        self.faceCenter = faceCenter
        self.faceScale = faceScale
        self.roll = roll
    }
}

/// 局部圆域位移场控制点：圆域中心处的采样位移为 offset，随距心距离羽化衰减
/// 到边缘为 0（衰减曲线由 GPU 实现定义，平滑钟形）。归一化坐标。
public struct FaceWarpControl: Equatable, Sendable {
    public var center: CGPoint
    /// 作用半径（归一化，> 0）。
    public var radius: CGFloat
    /// 中心采样点位移（归一化；y 向下为正——origin 左上坐标系）。
    public var offset: CGVector

    public init(center: CGPoint, radius: CGFloat, offset: CGVector) {
        self.center = center
        self.radius = radius
        self.offset = offset
    }
}

/// 控制点生成（纯函数）。params.isOff → 空数组（恒等直通）；输出顺序稳定
/// （左眼、右眼、下巴、左颊、右颊），便于单测数值锁定与 GPU 端回归比对。
public enum FaceWarpGeometry {

    /// 大眼：上/下睑推移幅度 = eyeGain × strength × 眼半高；作用半径随眼径。
    static let eyeGain: CGFloat = 0.45            // [E] 真机定案
    static let eyeRadiusToHalfHeight: CGFloat = 2.6  // [E]
    /// 下巴：上推幅度 = chinGain × strength × 脸尺度。
    static let chinGain: CGFloat = 0.18           // [E]
    static let chinRadiusToFaceScale: CGFloat = 0.4  // [E]
    /// 瘦脸：颊点向中线水平收缩幅度 ∝ strength × 该颊点到中线距离（比例收缩
    /// 保证几何一致性）；作用半径随脸尺度。
    static let slimGain: CGFloat = 0.25           // [E]
    static let slimRadiusToFaceScale: CGFloat = 0.55  // [E]

    public static func controls(from anchors: CameraReshapeAnchors,
                                params: CameraReshapeParams) -> [FaceWarpControl] {
        guard !params.isOff, anchors.faceScale > 0 else { return [] }
        var controls: [FaceWarpControl] = []

        // 大眼：每只眼一对反向平移控制点（origin 左上：上推 = dy 负）。
        let eyes: [(CGPoint?, CGFloat?)] = [
            (anchors.leftEyeCenter, anchors.leftEyeHalfHeight),
            (anchors.rightEyeCenter, anchors.rightEyeHalfHeight),
        ]
        if params.enlargeEye > 0 {
            for (center, halfHeight) in eyes {
                guard let c = center, let hh = halfHeight, hh > 0 else { continue }
                let push = CGFloat(params.enlargeEye) * eyeGain * hh
                let radius = eyeRadiusToHalfHeight * hh
                controls.append(FaceWarpControl(
                    center: CGPoint(x: c.x, y: c.y - hh), radius: radius,
                    offset: CGVector(dx: 0, dy: -push)))
                controls.append(FaceWarpControl(
                    center: CGPoint(x: c.x, y: c.y + hh), radius: radius,
                    offset: CGVector(dx: 0, dy: push)))
            }
        }

        // 下巴收缩：下巴尖向上（向脸心）平移。
        if params.chinShrink > 0, let chin = anchors.chin {
            let push = CGFloat(params.chinShrink) * chinGain * anchors.faceScale
            controls.append(FaceWarpControl(
                center: chin,
                radius: chinRadiusToFaceScale * anchors.faceScale,
                offset: CGVector(dx: 0, dy: -push)))
        }

        // 瘦脸：左颊向右、右颊向左（朝 faceCenter 水平收缩）。
        if params.slimFace > 0 {
            for cheek in [anchors.cheekLeft, anchors.cheekRight] {
                guard let cheek = cheek else { continue }
                let toCenter = anchors.faceCenter.x - cheek.x
                guard toCenter != 0 else { continue }
                let push = CGFloat(params.slimFace) * slimGain * toCenter  // 符号 = 方向
                controls.append(FaceWarpControl(
                    center: cheek,
                    radius: slimRadiusToFaceScale * anchors.faceScale,
                    offset: CGVector(dx: push, dy: 0)))
            }
        }

        return controls
    }
}
