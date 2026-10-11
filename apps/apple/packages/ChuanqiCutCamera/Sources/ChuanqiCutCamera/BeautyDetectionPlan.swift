// BeautyDetectionPlan — 美颜检测计划（CAM-033，RESEARCH-015 决策 1）
//
// 职责单一：**功能开关 → Vision 请求集合** 的纯函数 + metadata 脸框坐标契约转换。
// 抽到契约层的原因与 CameraFormatSelector（P93/P94）同构：把「哪些检测该跑」的
// 规则从 Impl 拎出来单测，Impl 只做装配与线程。
//
// 背景（真机日志实证，池 [15]）：此前 3~4 个 Vision 请求 30Hz 全家桶常开
//（FaceLandmarks + HumanBodyPose + RecognizeAnimals[+AnimalBodyPose]），用户没开
// 美体/宠物贴纸也照跑 —— 检测是「慢」的最大可省项。本文件把请求集合收敛为
// **按需**：磨皮/美白只需要脸框（采集栈 metadataOutput 白送，零 Vision 成本），
// landmark 只在美型/人脸贴纸需要锚点时跑，人体/动物只在对应功能开启时跑。

import CoreGraphics
import Foundation

/// Vision 请求种类（Impl 层据 Set 装配 VNRequest；此处不 import Vision，保持契约层平台无关）。
public enum BeautyVisionRequest: String, Sendable, CaseIterable, Hashable {
    /// 人脸关键点（美型 warp / 人脸贴纸锚点）。
    case faceLandmarks
    /// 单阶段人脸框（磨皮蒙版兜底：metadataOutput 不可用时）。
    case faceRectangles
    /// 人体关节（美体）。
    case bodyPose
    /// 动物识别（宠物贴纸）。
    case animal
    /// 动物姿态（宠物眼锚；Impl 层另有 iOS 17 运行时门控）。
    case animalPose
}

/// 美颜相关功能的开启状态（ViewModel 装配；语义 = 「该功能有可感知效果」）。
public struct BeautyFeatureFlags: Sendable, Equatable {
    /// 美型或人脸贴纸开启（需要 landmark 锚点）。
    public var faceAnchors: Bool
    /// 美体开启（需要人体关节）。
    public var bodyAnchors: Bool
    /// 宠物贴纸选中（需要动物识别 + 动物眼锚）。
    public var animalSticker: Bool

    public init(faceAnchors: Bool = false, bodyAnchors: Bool = false, animalSticker: Bool = false) {
        self.faceAnchors = faceAnchors
        self.bodyAnchors = bodyAnchors
        self.animalSticker = animalSticker
    }

    /// 全关（预览零检测开销的判据）。
    public static let off = BeautyFeatureFlags()
}

public enum BeautyDetectionPlan {

    /// 功能开关 → 应跑的 Vision 请求集合。
    ///
    /// - Parameters:
    ///   - flags: 锚点类功能开关（美型/贴纸/美体）。
    ///   - faceRectNeeded: 磨皮或美白开启（需要脸框做蒙版）。
    ///   - metadataFacesAvailable: 采集栈 metadataOutput 人脸框可用（设备/会话支持）。
    ///     可用时脸框**不走 Vision**（零检测成本）；不可用且需要框时兜底单阶段
    ///     faceRectangles（比 landmarks 便宜：无关键点对齐）。
    /// - Returns: 应发送的请求集合；空集 = 本次会话零 Vision 调用，Impl 层据此
    ///     跳过 perform（磨皮关 + 无锚点功能时）。
    public static func requests(for flags: BeautyFeatureFlags,
                                faceRectNeeded: Bool,
                                metadataFacesAvailable: Bool) -> Set<BeautyVisionRequest> {
        var result: Set<BeautyVisionRequest> = []
        if flags.faceAnchors {
            result.insert(.faceLandmarks)
        } else if faceRectNeeded, !metadataFacesAvailable {
            result.insert(.faceRectangles)
        }
        if flags.bodyAnchors { result.insert(.bodyPose) }
        if flags.animalSticker {
            result.insert(.animal)
            result.insert(.animalPose)
        }
        return result
    }
}

/// AVCaptureMetadataOutput 脸框 → CAM-011 契约坐标（图像归一化 origin 左上 0...1）。
public enum MetadataFaceGeometry {

    /// Impl 层已用 `AVCaptureOutput.outputRectConverted(fromMetadataOutputRect:)`
    /// 把 metadata 坐标转到**视频帧图像**坐标（考虑 connection 旋转）。此处只做
    /// 契约侧剩余补偿：前摄镜像。
    ///
    /// ⚠️ 真机标定项（SPEC-CAM-033 开放问题 1）：`outputRectConverted` 对镜像的
    /// 处理语义未经真机核验，镜像翻转以参数注入、标定后如需修正只改调用方传参
    /// 或此函数，不动其他层。
    ///
    /// 坐标系事实（AVFoundation 文档）：metadata/output rect origin = 左上、0...1
    /// 归一化 —— 与 CAM-011 契约同向，无 y 翻转（区别于 Vision 的 origin 左下）。
    public static func contractRect(fromConvertedRect rect: CGRect, mirrored: Bool) -> CGRect {
        guard mirrored else { return rect }
        // 水平镜像：x' = 1 - maxX（宽高不变）
        return CGRect(x: 1 - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
