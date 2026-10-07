// FaceObservation — 中性观测结构（CAM-011）
//
// VisionDetector 的输出契约：与 Vision 类型解耦（消费方 CAM-013 美型 warp /
// CAM-014 贴纸道具只认识本文件，不 import Vision），检测器将来替换（468 点
// 模型 / ARKit 网格）时本结构不变。
//
// 坐标约定（B 期全链契约，与 SharedUI/DetectionSmoothing.swift 一致）：
//   **图像归一化坐标，origin 左上，两轴均 0...1，与像素尺寸/图像方向无关。**
//   采集侧 connection 已把帧转成竖屏（CameraManager.applyPortraitOrientation），
//   观测坐标即竖屏画面内的归一化坐标；「Vision 左下原点 → 本约定」的翻转
//   在检测器转换时经 SharedUI 纯函数完成，消费方无需再翻。
//
// 本文件只放数据结构与纯派生量；帧间平滑数学在 SharedUI（可单测），
// 检测器负责携带平滑状态。

import CoreGraphics
import CoreMedia
import Foundation

// MARK: - 人脸（76 点级关键点）

/// 单个关键点区域。点序保持 Vision 输出序；nil = 该点本帧缺失
/// （低置信度被丢弃；帧间平滑会在检测器侧保持上一帧值）。
public struct LandmarkRegion: Equatable, Sendable {
    public var points: [CGPoint?]

    public init(points: [CGPoint?]) {
        self.points = points
    }
}

/// 人脸观测。各区域为 Vision 原生 12 区域（区域间存在共享端点，如 medianLine
/// 与鼻梁重合；pupil 为推导点）——**点位总数不硬编码 76**，以真机实测对表为准 [E]。
public struct FaceObservation: Sendable {

    // 固定区域序（flattenedPoints / replacing 的排列契约，勿改顺序）：
    // contour → 左右眉 → 左右眼 → 鼻 → 鼻梁 → 中线 → 外/内唇 → 左右瞳。
    public var contour: LandmarkRegion
    public var leftEyebrow: LandmarkRegion
    public var rightEyebrow: LandmarkRegion
    public var leftEye: LandmarkRegion
    public var rightEye: LandmarkRegion
    public var nose: LandmarkRegion
    public var noseCrest: LandmarkRegion
    public var medianLine: LandmarkRegion
    public var outerLips: LandmarkRegion
    public var innerLips: LandmarkRegion
    public var leftPupil: CGPoint?
    public var rightPupil: CGPoint?

    /// 人脸框（图像归一化，origin 左上）。
    public var box: CGRect
    /// 头部姿态角（弧度，Vision 原生定义）；缺失为 nil（不伪造 0）。
    public var yaw: Double?
    public var pitch: Double?
    public var roll: Double?
    /// 整体置信度 0...1。
    public var confidence: Double

    public init(contour: LandmarkRegion, leftEyebrow: LandmarkRegion, rightEyebrow: LandmarkRegion,
                leftEye: LandmarkRegion, rightEye: LandmarkRegion,
                nose: LandmarkRegion, noseCrest: LandmarkRegion, medianLine: LandmarkRegion,
                outerLips: LandmarkRegion, innerLips: LandmarkRegion,
                leftPupil: CGPoint?, rightPupil: CGPoint?,
                box: CGRect, yaw: Double?, pitch: Double?, roll: Double?,
                confidence: Double) {
        self.contour = contour
        self.leftEyebrow = leftEyebrow
        self.rightEyebrow = rightEyebrow
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.nose = nose
        self.noseCrest = noseCrest
        self.medianLine = medianLine
        self.outerLips = outerLips
        self.innerLips = innerLips
        self.leftPupil = leftPupil
        self.rightPupil = rightPupil
        self.box = box
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.confidence = confidence
    }

    /// 区域数组（固定序），flatten/restore 的唯一真源。
    private var orderedRegions: [LandmarkRegion] {
        [contour, leftEyebrow, rightEyebrow, leftEye, rightEye, nose,
         noseCrest, medianLine, outerLips, innerLips]
    }

    /// 全部关键点摊平成一维数组（固定序：orderedRegions 依序 + 左瞳 + 右瞳）。
    /// 供 SharedUI 平滑纯函数消费（一维 [CGPoint?]）。
    public func flattenedPoints() -> [CGPoint?] {
        var flat: [CGPoint?] = orderedRegions.flatMap { $0.points }
        flat.append(leftPupil)
        flat.append(rightPupil)
        return flat
    }

    /// 用摊平数组替换各点（形状须与 flattenedPoints() 一致；
    /// 长度不符时多截少补 nil —— 平滑函数保证形状不变，此分支是防御）。
    public func replacing(flattened: [CGPoint?]) -> FaceObservation {
        var cursor = 0
        func take(_ region: LandmarkRegion) -> LandmarkRegion {
            let n = region.points.count
            let slice = Array(flattened.dropFirst(cursor).prefix(n))
            cursor += n
            let padded = slice + Array(repeating: nil, count: n - slice.count)
            return LandmarkRegion(points: padded)
        }
        var result = self
        result.contour = take(contour)
        result.leftEyebrow = take(leftEyebrow)
        result.rightEyebrow = take(rightEyebrow)
        result.leftEye = take(leftEye)
        result.rightEye = take(rightEye)
        result.nose = take(nose)
        result.noseCrest = take(noseCrest)
        result.medianLine = take(medianLine)
        result.outerLips = take(outerLips)
        result.innerLips = take(innerLips)
        let rest = flattened.dropFirst(cursor)
        result.leftPupil = rest.first ?? nil
        result.rightPupil = rest.dropFirst().first ?? nil
        return result
    }

    /// 眼睛中心（CAM-013/014 锚定原语）：优先瞳孔（Vision 推导点，最稳），
    /// 缺失时退化为眼区域有效点的算术平均。
    public var leftEyeCenter: CGPoint? {
        eyeCenter(pupil: leftPupil, region: leftEye)
    }

    public var rightEyeCenter: CGPoint? {
        eyeCenter(pupil: rightPupil, region: rightEye)
    }

    private func eyeCenter(pupil: CGPoint?, region: LandmarkRegion) -> CGPoint? {
        if let pupil { return pupil }
        let valid = region.points.compactMap { $0 }
        guard !valid.isEmpty else { return nil }
        let sumX = valid.reduce(0.0) { $0 + Double($1.x) }
        let sumY = valid.reduce(0.0) { $0 + Double($1.y) }
        return CGPoint(x: CGFloat(sumX / Double(valid.count)),
                       y: CGFloat(sumY / Double(valid.count)))
    }
}

// MARK: - 人体姿态（iOS 14+，19 关节）

/// 人体关节（中性命名，映射自 VNHumanBodyPoseObservation.JointName）。
public enum BodyJoint: String, CaseIterable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar
    case leftShoulder, rightShoulder, leftElbow, rightElbow
    case leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
    case neck, root   // root = 髋部中心（C 期美体瘦腰/长腿的扩展位）
}

/// 人体姿态观测。单主体策略：检测器取置信度最高的一组（多人体留 C 期美体）。
public struct BodyPoseObservation: Sendable {

    /// 本帧检出的关节（缺失关节不在字典中；平滑状态在检测器侧按
    /// BodyJoint.allCases 固定序摊平处理）。
    public var joints: [BodyJoint: CGPoint]

    public init(joints: [BodyJoint: CGPoint]) {
        self.joints = joints
    }

    public func point(for joint: BodyJoint) -> CGPoint? {
        joints[joint]
    }

    /// 固定序摊平（与 SharedUI smoothKeypoints 对接；未检出为 nil）。
    public func flattenedPoints() -> [CGPoint?] {
        BodyJoint.allCases.map { joints[$0] }
    }

    /// 用摊平数组重建（形状恒为 BodyJoint.allCases 数）。
    public func replacing(flattened: [CGPoint?]) -> BodyPoseObservation {
        var rebuilt: [BodyJoint: CGPoint] = [:]
        for (index, joint) in BodyJoint.allCases.enumerated() where index < flattened.count {
            if let p = flattened[index] {
                rebuilt[joint] = p
            }
        }
        return BodyPoseObservation(joints: rebuilt)
    }
}

// MARK: - 动物（猫/狗）

public enum AnimalSpecies: String, Sendable {
    case cat, dog
}

/// 动物头部关节（B 期贴纸锚定所需子集：眼/耳尖/鼻）。
/// 命名对表自 SDK 头文件（VNTypes.h，iOS 17+）：25 关节中耳分 Top/Middle/Bottom
/// 三点、鼻部为 nose（无 snout）；全 25 关节映射归 C 期宠物美化，本卡不做假全集。
public enum AnimalJoint: String, CaseIterable, Sendable {
    case leftEye, rightEye, leftEarTop, rightEarTop, nose
}

/// 动物观测。Vision 仅识别猫/狗；物种缺失（nil）= 框确认为动物但标签不可辨。
/// pose 仅 iOS 17+（运行时门控，低版本如实为 nil，不做假能力）。
public struct AnimalObservation: Sendable {
    public var species: AnimalSpecies?
    public var box: CGRect
    public var confidence: Double
    public var pose: [AnimalJoint: CGPoint]?

    public init(species: AnimalSpecies?, box: CGRect, confidence: Double,
                pose: [AnimalJoint: CGPoint]?) {
        self.species = species
        self.box = box
        self.confidence = confidence
        self.pose = pose
    }
}

// MARK: - 快照

/// 一帧检测的完整输出。`pts` 为被检测视频帧的呈现时间戳（采集硬件时钟）。
/// 回调在检测队列（见 VisionDetector 线程契约），消费方自行决定跨线程方式。
public struct DetectionSnapshot: Sendable {
    public var pts: CMTime
    public var face: FaceObservation?
    public var body: BodyPoseObservation?
    /// 按置信度降序。
    public var animals: [AnimalObservation]

    public init(pts: CMTime, face: FaceObservation?, body: BodyPoseObservation?,
                animals: [AnimalObservation]) {
        self.pts = pts
        self.face = face
        self.body = body
        self.animals = animals
    }
}
