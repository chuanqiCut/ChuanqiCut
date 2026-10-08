// ChuanqiCutCamera — 人像皮肤区域蒙版（CAM-027 v1：几何级精修）
//
// 卡的落点：把美颜/磨皮的作用区从「脸框椭圆」升级为「语义 ∩ 脸框」——让发际、
// 眉毛、眼睛、唇不再被磨皮波及（"磨皮=糊"的第一根因就是这些部位给磨平了）。
//
// 分层（沿用 CAM-012 / CAM-019 的惯例）：
//   - 本文件 = **契约层纯函数**：输入（人脸框 + 关键点点集），输出 CI 蒙版 DAG。
//     零 Vision／零 UIKit 依赖 → macOS 上可 typecheck、可单测。
//   - 实现层（Detection/PortraitSemantics.swift）只负责把当前帧锚点喂进来并安装
//     注入点，不放算法。
//
// v1 定性与诚实降级（不要把这当成语义分割）：
//   - **v1 = 几何级精修**：脸框椭圆 ∩ 「非五官区」。五官切除复用 CAM-026
//     `MakeupMask` 那套关键点多边形工艺，不多一套轮子。
//   - **不做 YCbCr 肤色聚类**：卡 risk 里写的 v1 肤色域路线需要逐像素条件分支，
//     CI 侧没有廉价的 branchless 门函数（`CIColorPolynomial` 三次多项式去近似
//     smoothstep，精度无法自证），留给 **CAM-028 模型路线**
//     （VNGeneratePersonSegmentationRequest／自训练分割）——那里才是能
//     真正把精度做出来的地方。
//   - **anchors = nil（本帧无关键点）→ 返回框级蒙版**，不伪造语义。
//     定则：无算法即无效果，宁可退回老行为也不猜。
//   - **头发分割本期不做**：`VNGenerateHairMaskRequest` 是 iOS 17+ API，而本机
//     iPhoneSimulator SDK 是 15.0，符号不存在（已核验）——写上去必然编不过。
//     要用它，得等移植到带 iOS 17+ SDK 的工具链，并配 `@available` 运行时门控。
//
// 坐标契约：人脸框 = 图像归一化（origin 左上，0...1）；点集同为 CAM-011 观测坐标。
// 归一化 → CI 像素的 y 翻转由 FaceMask / MakeupMask 各做一次，这里不再二次翻转。

import CoreImage
import Foundation

/// 语义皮肤蒙版引擎签名：`(输入图, 归一化人脸框) -> 蒙版图`。
/// 返回 nil = 该帧不接管，调用方回落到框级椭圆蒙版（`FaceMask.mask`）。
public typealias PortraitSkinMaskEngine = @Sendable (CIImage, [CGRect]) -> CIImage?

public enum PortraitSkinMask {

    /// 排除区羽化半径（归一化 × extent.height）[E，真机人工定案]。
    public static let exclusionFeather: CGFloat = 0.012

    /// 皮肤区域蒙版：白 = 作用区（皮肤候选），黑 = 保持原样。
    ///
    /// - anchors = nil：**框级椭圆蒙版**（与 CAM-019 完全一致，零回归）；
    /// - anchors 非空：框级蒙版 ∩ 「眼/眉/唇以外的区域」；
    /// - 返回 nil：只在空 faceBoxes／退化 extent 时（语义与 `FaceMask.mask` 一致）。
    public static func skinMask(for image: CIImage, faceBoxes: [CGRect],
                                anchors: MakeupAnchors?) -> CIImage? {
        let extent = image.extent
        guard let base = FaceMask.mask(forNormalizedBoxes: faceBoxes, in: extent) else {
            return nil
        }
        guard let anchors else { return base }
        guard let keep = keepRegion(anchors: anchors, in: extent) else { return base }
        return multiply(base, keep).cropped(to: extent)
    }

    // MARK: - 内部构造

    /// 「保留区」蒙版（白 = 皮肤候选区）= 「五官排除区」羽化后反相。
    /// 某个子区域构造失败（点数不足）时**只少排一块**，不抛、不返回 nil ——
    /// 部分几何不可信时，宁可少排一块，也不要排出个残缺形状。
    private static func keepRegion(anchors: MakeupAnchors, in extent: CGRect) -> CIImage? {
        guard extent.width >= 2, extent.height >= 2 else { return nil }

        var excluded = CIImage(color: .black).cropped(to: extent)
        var didExclude = false

        // 眼：眼窝凸包整块排除（眼白/睫毛是磨皮最容易被糊掉的地方）。
        for eye in [anchors.leftEye, anchors.rightEye] where eye.count >= 3 {
            if let piece = polygonSafe(eye, in: extent) {
                excluded = piece.composited(over: excluded)
                didExclude = true
            }
        }
        // 眉：毛流高对比区，磨皮会把眉形软化。
        for brow in [anchors.leftBrow, anchors.rightBrow] where brow.count >= 3 {
            if let piece = polygonSafe(brow, in: extent) {
                excluded = piece.composited(over: excluded)
                didExclude = true
            }
        }
        // 唇：整唇排除（含口腔，观测输出的 outerLips 本来就是闭合多边形）。
        if anchors.outerLips.count >= 3,
           let piece = polygonSafe(anchors.outerLips, in: extent) {
            excluded = piece.composited(over: excluded)
            didExclude = true
        }

        // 一个区域都没排掉 → 保留区恒等，省掉一次无意义的 CI 计算。
        guard didExclude else { return nil }

        let radius = max(exclusionFeather * extent.height, 1.0)
        let softened = excluded.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: NSNumber(value: Double(radius)),
        ]).cropped(to: extent)
        return softened.applyingFilter("CIColorInvert").cropped(to: extent)
    }

    /// MakeupMask.polygonMask 的防御壳：点数不足返回 nil（内部已保证 ≥3 才三角化）。
    private static func polygonSafe(_ points: [CGPoint], in extent: CGRect) -> CIImage? {
        guard points.count >= 3 else { return nil }
        return MakeupMask.polygonMask(points: points, in: extent)
    }

    /// 蒙版相乘（白 ∩ 白）。与 `MakeupMask.multiply` 同惯例。
    private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: b,
        ])
    }
}
