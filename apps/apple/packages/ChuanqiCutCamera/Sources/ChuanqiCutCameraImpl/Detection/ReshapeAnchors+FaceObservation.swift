// ReshapeAnchors+FaceObservation — 观测结构 → 美型/贴纸锚点提取（CAM-013/014）
//
// 实现层唯一的 FaceObservation → CameraReshapeAnchors 转换点：契约层锚点
// 结构不依赖 Vision/观测类型（与 FaceMask 收 [CGRect] 同思路），提取放
// 实现层在检测回调侧一次完成，消费方（warp/贴纸）只认识锚点结构。
//
// 输入关键点已经过检测器帧间平滑（CAM-011，VisionDetector.detect 内
// smoothKeypoints），此处**不做二次平滑**。锚点派生自已平滑的点，
// FaceBoxStore 内的框级平滑（羽化蒙版用）与本结构互不影响。

import CoreGraphics
import Foundation

extension CameraReshapeAnchors {

    /// 从人脸观测提取锚点（归一化 origin 左上契约）。轮廓缺失（无有效点）
    /// 返回 nil —— 消费方整帧跳过美型/贴纸，不做部分猜测。
    init?(face: FaceObservation) {
        let contour = face.contour.points.compactMap { $0 }
        guard !contour.isEmpty else { return nil }

        // 眼半高：眼区域有效点 y 极差之半（眼闭合时趋 0 → 效果自动失效）。
        func eyeHalfHeight(_ region: LandmarkRegion) -> CGFloat? {
            let ys = region.points.compactMap { $0?.y }
            guard ys.count >= 2 else { return nil }
            let half = (ys.max()! - ys.min()!) / 2
            return half > 0 ? half : nil
        }

        // 下巴 = 轮廓 y 最大点（origin 左上：y 大 = 视觉最低）；
        // 左右颊 = 轮廓 x 极值点。
        let chin = contour.max { $0.y < $1.y }
        let cheekLeft = contour.min { $0.x < $1.x }
        let cheekRight = contour.max { $0.x < $1.x }

        // 尺度基准：双瞳距优先（最稳），缺瞳退化为脸框长边。
        let scale = face.leftPupil.flatMap { left in
            face.rightPupil.map { right in hypot(right.x - left.x, right.y - left.y) }
        } ?? max(face.box.width, face.box.height)

        self.init(leftEyeCenter: face.leftEyeCenter,
                  leftEyeHalfHeight: eyeHalfHeight(face.leftEye),
                  rightEyeCenter: face.rightEyeCenter,
                  rightEyeHalfHeight: eyeHalfHeight(face.rightEye),
                  chin: chin, cheekLeft: cheekLeft, cheekRight: cheekRight,
                  faceCenter: CGPoint(x: face.box.midX, y: face.box.midY),
                  faceScale: scale, roll: face.roll)
    }
}
