// MakeupRenderer — 美妆着色混合（CAM-026 实现层）
//
// 混合语义（每区域）：先在副本上整幅着色，再经区域蒙版 CIBlendWithMask 回原图 ——
// 白（蒙版）区取着色结果、黑区取原图。着色方式：
//   唇色/眼影 = multiply（保明暗结构，口红质感）；腮红 = soft-light（透血色）；
//   眉毛/美瞳 = source-over 半透明叠色（染色不改明暗）。
// 强度 = 着色层与原图的线性插值（对滑杆单调）。
//
// 无锚点（无脸）→ 原样返回（算法驱动定则：无关键点即无效果）。
// 处理链插位：磨皮/美型之后、滤镜之前（妆容贴皮肤，滤镜统一调色）——与卡口径一致。
// 蒙版逐帧由关键点重建（关键点已平滑，蒙版天然稳定）；三角形光栅化为 CPU 一次性
// 成本，1080p 全妆 <2ms [E]（真机实测入 baselines 后定频）。

import CoreImage
import Foundation

extension MakeupAnchors {

    /// FaceObservation → 美妆锚点（关键点已检测器侧平滑）。
    init?(face: FaceObservation) {
        let outer = face.outerLips.points.compactMap { $0 }
        guard outer.count >= 3 else { return nil }
        func pts(_ region: LandmarkRegion) -> [CGPoint] {
            region.points.compactMap { $0 }
        }
        let scale = face.leftPupil.flatMap { left in
            face.rightPupil.map { right in hypot(right.x - left.x, right.y - left.y) }
        } ?? max(face.box.width, face.box.height)
        self.init(outerLips: outer,
                  innerLips: pts(face.innerLips),
                  leftBrow: pts(face.leftEyebrow),
                  rightBrow: pts(face.rightEyebrow),
                  leftEye: pts(face.leftEye),
                  rightEye: pts(face.rightEye),
                  leftPupil: face.leftPupil,
                  rightPupil: face.rightPupil,
                  faceScale: scale)
    }
}

enum MakeupRenderer {

    /// 应用美妆。off / 无锚点 → 原样返回。
    static func apply(to image: CIImage, anchors: MakeupAnchors?,
                      params: MakeupParams) -> CIImage {
        guard !params.isOff, let anchors else { return image }
        let extent = image.extent
        guard extent.width >= 4, extent.height >= 4 else { return image }
        var result = image

        // 唇色（口腔保护在蒙版内完成）。
        if params.lipTint > 0,
           let mask = MakeupMask.lipMask(outer: anchors.outerLips,
                                         inner: anchors.innerLips, in: extent) {
            result = blend(result, color: params.lipColor, strength: params.lipTint,
                           mask: mask, mode: .multiply)
        }
        // 腮红。
        if params.blush > 0,
           let mask = MakeupMask.blushMask(leftEye: anchors.leftEye,
                                           rightEye: anchors.rightEye,
                                           faceScale: anchors.faceScale, in: extent) {
            result = blend(result, color: params.blushColor, strength: params.blush,
                           mask: mask, mode: .softLight)
        }
        // 眼影（左右各自蒙版，逐眼叠加）。
        if params.eyeshadow > 0 {
            for eye in [anchors.leftEye, anchors.rightEye] {
                if let mask = MakeupMask.eyeshadowMask(eye: eye,
                                                       faceScale: anchors.faceScale,
                                                       in: extent) {
                    result = blend(result, color: params.eyeshadowColor,
                                   strength: params.eyeshadow, mask: mask, mode: .multiply)
                }
            }
        }
        // 眉毛。
        if params.brow > 0 {
            for brow in [anchors.leftBrow, anchors.rightBrow] where brow.count >= 3 {
                if let mask = MakeupMask.browMask(brow: brow, in: extent) {
                    result = blend(result, color: params.browColor, strength: params.brow,
                                   mask: mask, mode: .over)
                }
            }
        }
        // 美瞳。
        if params.iris > 0 {
            for pupil in [anchors.leftPupil, anchors.rightPupil].compactMap({ $0 }) {
                if let mask = MakeupMask.irisMask(pupil: pupil,
                                                  faceScale: anchors.faceScale, in: extent) {
                    result = blend(result, color: params.irisColor, strength: params.iris,
                                   mask: mask, mode: .over)
                }
            }
        }
        return result
    }

    private enum BlendMode {
        case multiply, softLight, over
    }

    /// 着色 → 混合 → 蒙版回原图。
    /// multiply/softLight：着色结果与原图按强度插值（CIDissolve t=1-s：s↑ 着色占比↑）；
    /// over：叠色透明度即强度（无需二次插值，双重衰减 [E] 校正）。
    private static func blend(_ image: CIImage, color: SIMD3<Double>,
                              strength: Double, mask: CIImage, mode: BlendMode) -> CIImage {
        let mixed: CIImage
        switch mode {
        case .multiply:
            let tint = CIImage(color: CIColor(red: CGFloat(color.x),
                                              green: CGFloat(color.y),
                                              blue: CGFloat(color.z)))
            let colored = image.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: tint,
            ])
            mixed = colored.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTimeKey: NSNumber(value: 1.0 - strength),
            ])
        case .softLight:
            let tint = CIImage(color: CIColor(red: CGFloat(color.x),
                                              green: CGFloat(color.y),
                                              blue: CGFloat(color.z)))
            let colored = image.applyingFilter("CISoftLightBlendMode", parameters: [
                kCIInputBackgroundImageKey: tint,
            ])
            mixed = colored.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTimeKey: NSNumber(value: 1.0 - strength),
            ])
        case .over:
            let overlay = CIImage(color: CIColor(red: CGFloat(color.x),
                                                  green: CGFloat(color.y),
                                                  blue: CGFloat(color.z),
                                                  alpha: CGFloat(strength * 0.5)))
            mixed = overlay.composited(over: image)
        }
        return mixed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask,
        ])
    }
}
