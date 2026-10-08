// ChuanqiCutCamera — 美妆参数与区域蒙版纯函数（CAM-026，C 期）
//
// 五类区域美妆：唇色/腮红/眼影/眉毛/美瞳。算法驱动定则（传哲 2026-10-07）：
// 蒙版一律由**关键点区域**生成（无关键点 = 无效果，不退化为全画面着色）。
//
// 契约层职责（对齐 CameraBeauty/FaceMask 分层惯例）：
//   - 妆容参数结构（各强度 0...1 线性单调，off 恒等直通）+ 色值（归一化 RGB）；
//   - 关键点区域 → CI 蒙版 DAG（唇多边形含口腔保护、眉/眼影凸包+羽化、美瞳圆域）。
// 消费方：实现层 Effects/MakeupRenderer（混合语义：唇/眼影 multiply、腮红 soft-light、
// 美瞳/眉毛 source-over 带强度）。
//
// 坐标契约：关键点为图像归一化 origin 左上（CAM-011）；CI 蒙版构造做 y 翻转
//（同 FaceMask.ciRect 惯例）。羽化半径与外扩比例全 [E]，真机定案后锁数。

import CoreImage
import Foundation

/// 美妆滑杆参数（各区域独立强度 + 颜色）。
public struct MakeupParams: Equatable, Sendable {

    /// 唇色（0 = 关）。
    public var lipTint: Double
    public var lipColor: SIMD3<Double>

    /// 腮红（0 = 关）。
    public var blush: Double
    public var blushColor: SIMD3<Double>

    /// 眼影（0 = 关）。
    public var eyeshadow: Double
    public var eyeshadowColor: SIMD3<Double>

    /// 眉毛（0 = 关；染色/加深）。
    public var brow: Double
    public var browColor: SIMD3<Double>

    /// 美瞳（0 = 关）。
    public var iris: Double
    public var irisColor: SIMD3<Double>

    public init(lipTint: Double = 0, lipColor: SIMD3<Double> = SIMD3(0.85, 0.15, 0.25),
                blush: Double = 0, blushColor: SIMD3<Double> = SIMD3(0.95, 0.35, 0.35),
                eyeshadow: Double = 0, eyeshadowColor: SIMD3<Double> = SIMD3(0.55, 0.35, 0.5),
                brow: Double = 0, browColor: SIMD3<Double> = SIMD3(0.2, 0.13, 0.1),
                iris: Double = 0, irisColor: SIMD3<Double> = SIMD3(0.3, 0.55, 0.85)) {
        self.lipTint = min(max(lipTint, 0), 1)
        self.lipColor = lipColor
        self.blush = min(max(blush, 0), 1)
        self.blushColor = blushColor
        self.eyeshadow = min(max(eyeshadow, 0), 1)
        self.eyeshadowColor = eyeshadowColor
        self.brow = min(max(brow, 0), 1)
        self.browColor = browColor
        self.iris = min(max(iris, 0), 1)
        self.irisColor = irisColor
    }

    public static let off = MakeupParams()

    public var isOff: Bool {
        lipTint <= 0 && blush <= 0 && eyeshadow <= 0 && brow <= 0 && iris <= 0
    }

    /// 预设妆容包（UI 快捷入口；设计定稿后扩充）。
    public static let presets: [String: MakeupParams] = [
        "自然": MakeupParams(lipTint: 0.35, blush: 0.2, eyeshadow: 0.15, brow: 0.25, iris: 0),
        "元气": MakeupParams(lipTint: 0.55, blush: 0.4, eyeshadow: 0.2, brow: 0.3, iris: 0.2),
        "浓颜": MakeupParams(lipTint: 0.8, blush: 0.5, eyeshadow: 0.55, brow: 0.5, iris: 0.35),
    ]
}

/// 美妆锚点中性结构：实现层从 FaceObservation 提取（区域点集/瞳位），契约层
/// 不依赖 Vision 类型（macOS 可测）。
public struct MakeupAnchors: Equatable, Sendable {
    /// 外唇轮廓闭合序点（空 = 该帧跳过唇妆）。
    public var outerLips: [CGPoint]
    /// 内唇轮廓（口腔保护：内唇区域不染色）。
    public var innerLips: [CGPoint]
    /// 左/右眉点集。
    public var leftBrow: [CGPoint]
    public var rightBrow: [CGPoint]
    /// 左/右眼窝点集（眼影区域 = 眼点外扩上移）。
    public var leftEye: [CGPoint]
    public var rightEye: [CGPoint]
    /// 左/右瞳位（美瞳圆心；nil = 无瞳点跳过美瞳）。
    public var leftPupil: CGPoint?
    public var rightPupil: CGPoint?
    /// 归一化脸尺度（瞳距；作用半径参照）。
    public var faceScale: CGFloat

    public init(outerLips: [CGPoint], innerLips: [CGPoint],
                leftBrow: [CGPoint], rightBrow: [CGPoint],
                leftEye: [CGPoint], rightEye: [CGPoint],
                leftPupil: CGPoint?, rightPupil: CGPoint?,
                faceScale: CGFloat) {
        self.outerLips = outerLips
        self.innerLips = innerLips
        self.leftBrow = leftBrow
        self.rightBrow = rightBrow
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftPupil = leftPupil
        self.rightPupil = rightPupil
        self.faceScale = faceScale
    }
}

/// 区域蒙版构造（纯函数，输出 CI 蒙版 DAG；白 = 着色区）。
public enum MakeupMask {

    static let featherRadius: CGFloat = 0.02     // 归一化 [E]
    static let shadowLiftRatio: CGFloat = 0.35   // 眼影上移（× 眼高）[E]
    static let irisRadiusRatio: CGFloat = 0.35   // 美瞳半径（× faceScale）[E]
    static let blushRadiusRatio: CGFloat = 0.7   // 腮红半径（× faceScale）[E]
    static let blushOffsetRatio: CGFloat = 0.65  // 腮红中心（颧骨：眼下下方）[E]

    /// 归一化点 → CI 像素（y 翻转）。
    static func ciPoint(_ p: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: p.x * extent.width, y: (1 - p.y) * extent.height)
    }

    /// 点集凸包（Andrew monotone chain；≥3 点有效）。
    public static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        let pts = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// 多边形蒙版：黑底 + 白多边形（羽化）。CI 无原生多边形填充——
    /// 用三角扇剖分逐个叠加（凸多边形精确；凹多边形先取凸包，唇形可接受 [E]）。
    public static func polygonMask(points: [CGPoint], in extent: CGRect) -> CIImage? {
        let hull = convexHull(points)
        guard hull.count >= 3 else { return nil }
        let ci = hull.map { ciPoint($0, in: extent) }
        var mask = CIImage(color: .black).cropped(to: extent)
        let anchor = ci[0]
        for i in 1..<(ci.count - 1) {
            let tri = triangleMask(a: anchor, b: ci[i], c: ci[i + 1], in: extent)
            mask = tri.composited(over: mask)
        }
        return mask.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: featherRadius * extent.height,
        ]).cropped(to: extent)
    }

    /// 三角形蒙版：白三角 + 羽化边缘（把三角形画进位图再转 CI——CI 无多边形原语，
    /// CPU 填充一次性成本，1080p 下 <0.5ms [E]，美妆 15-30Hz 蒙版缓存复用不逐帧重建）。
    private static func triangleMask(a: CGPoint, b: CGPoint, c: CGPoint, in extent: CGRect) -> CIImage {
        let width = max(Int(extent.width.rounded()), 1)
        let height = max(Int(extent.height.rounded()), 1)
        var bitmap = [UInt8](repeating: 0, count: width * height * 4)
        // 半平面光栅化（扫描线）：任一点在三角形内 = 三个叉积同号。
        func inside(_ p: CGPoint) -> Bool {
            func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
                (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
            }
            let d1 = cross(a, b, p), d2 = cross(b, c, p), d3 = cross(c, a, p)
            let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
            let hasPos = d1 > 0 || d2 > 0 || d3 > 0
            return !(hasNeg && hasPos)
        }
        let minX = max(Int(floor(min(a.x, min(b.x, c.x)))), 0)
        let maxX = min(Int(ceil(max(a.x, max(b.x, c.x)))), width - 1)
        let minY = max(Int(floor(min(a.y, min(b.y, c.y)))), 0)
        let maxY = min(Int(ceil(max(a.y, max(b.y, c.y)))), height - 1)
        guard minX <= maxX, minY <= maxY else {
            return CIImage(color: .black).cropped(to: extent)
        }
        for y in minY...maxY {
            for x in minX...maxX {
                if inside(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    let offset = ((height - 1 - y) * width + x) * 4  // CI 位图首行 = 顶部
                    bitmap[offset] = 255
                    bitmap[offset + 1] = 255
                    bitmap[offset + 2] = 255
                    bitmap[offset + 3] = 255
                }
            }
        }
        return CIImage(bitmapData: Data(bitmap), bytesPerRow: width * 4,
                       size: extent.size, format: .RGBA8, colorSpace: nil)
    }

    /// 唇部蒙版：外唇多边形 − 内唇（口腔/牙齿保护，验收项）。
    /// 减法 = 外唇 ∩ 内唇反相（内唇白区变黑 = 不染色）。
    public static func lipMask(outer: [CGPoint], inner: [CGPoint], in extent: CGRect) -> CIImage? {
        guard let outerMask = polygonMask(points: outer, in: extent) else { return nil }
        guard !inner.isEmpty, let innerMask = polygonMask(points: inner, in: extent) else {
            return outerMask
        }
        let innerInverted = innerMask.applyingFilter("CIColorInvert")
        return multiply(outerMask, innerInverted)
    }

    /// 蒙版相乘（白∩白）。
    static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: b,
        ])
    }

    /// 腮红蒙版：双眼中心外下侧两枚羽化椭圆（颧骨）。
    public static func blushMask(leftEye: [CGPoint], rightEye: [CGPoint],
                                 faceScale: CGFloat, in extent: CGRect) -> CIImage? {
        func center(_ pts: [CGPoint]) -> CGPoint? {
            guard !pts.isEmpty else { return nil }
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
        }
        guard let le = center(leftEye), let re = center(rightEye) else { return nil }
        let radius = blushRadiusRatio * faceScale
        var mask = CIImage(color: .black).cropped(to: extent)
        for eye in [le, re] {
            let center = CGPoint(x: eye.x, y: eye.y + blushOffsetRatio * faceScale)
            guard let spot = radialMask(center: center, radius: radius, in: extent) else { continue }
            mask = spot.composited(over: mask)
        }
        return mask
    }

    /// 眼影蒙版：眼点凸包外扩 + 上移。
    public static func eyeshadowMask(eye: [CGPoint], faceScale: CGFloat, in extent: CGRect) -> CIImage? {
        guard eye.count >= 3 else { return nil }
        let ys = eye.map { $0.y }
        let eyeHeight = (ys.max() ?? 0) - (ys.min() ?? 0)
        let lifted = eye.map { CGPoint(x: $0.x, y: $0.y - shadowLiftRatio * max(eyeHeight, faceScale * 0.1)) }
        // 外扩：凸包后向形心外推 15% [E]。
        guard let hull = convexHull(lifted).nonEmpty else { return nil }
        let centroid = hull.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let c = CGPoint(x: centroid.x / CGFloat(hull.count), y: centroid.y / CGFloat(hull.count))
        let expanded = hull.map { p in
            CGPoint(x: c.x + (p.x - c.x) * 1.15, y: c.y + (p.y - c.y) * 1.15)
        }
        return polygonMask(points: expanded, in: extent)
    }

    /// 美瞳蒙版：瞳位羽化圆。
    public static func irisMask(pupil: CGPoint, faceScale: CGFloat, in extent: CGRect) -> CIImage? {
        radialMask(center: pupil, radius: irisRadiusRatio * faceScale, in: extent)
    }

    /// 眉毛蒙版：眉点凸包。
    public static func browMask(brow: [CGPoint], in extent: CGRect) -> CIImage? {
        polygonMask(points: brow, in: extent)
    }

    /// 羽化径向蒙版（solid 60% → 边缘 0，FaceMask 同惯例）。
    static func radialMask(center: CGPoint, radius: CGFloat, in extent: CGRect) -> CIImage? {
        guard radius > 0, let filter = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: ciPoint(center, in: extent).x,
                                    y: ciPoint(center, in: extent).y),
            "inputRadius0": NSNumber(value: Double(radius * extent.height * 0.6)),
            "inputRadius1": NSNumber(value: Double(radius * extent.height)),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ]), let output = filter.outputImage else { return nil }
        return output.cropped(to: extent)
    }
}

private extension Array {
    var nonEmpty: [Element]? { isEmpty ? nil : self }
}
