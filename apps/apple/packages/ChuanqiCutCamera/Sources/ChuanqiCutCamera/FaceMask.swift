// SharedUI — 人脸区域羽化蒙版纯函数（CAM-019，SPEC-CAM-018-019 §4）
//
// 坐标链：检测桥输出 = 图像归一化坐标（origin 左上，0...1，CAM-011 全链契约）；
// CoreImage 几何 = 像素坐标（origin 左下）。本文件负责归一化→CI 的 y 翻转、
// 外扩与蒙版 DAG 构造（只构造 CIImage，懒执行，不改 extent 语义）。
//
// 三态语义在 CameraBeautyParams.apply(to:faces:)（nil=全画面 / []=直通 / 非空=蒙版）；
// 本文件只管「有脸 → 蒙版」。无脸返回 nil 由调用方决定兜底行为。

import CoreImage
import Foundation

public enum FaceMask {

    /// 框外扩比例（侧脸/发际/下颌余量）[E，真机人工定案]。
    public static let boxExpansion: CGFloat = 0.15
    /// 蒙版核心实心区半径 / 框半宽（其余部分线性羽化到透明）[E]。
    public static let solidCoreRatio: CGFloat = 0.56

    /// 归一化框（origin 左上）→ CI 空间像素 CGRect（origin 左下，y 翻转），
    /// 按 boxExpansion 外扩并夹取进归一化 0...1（越界脸不越出画面）。
    public static func ciRect(forNormalizedBox box: CGRect, in extent: CGRect) -> CGRect {
        func clamp01(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        let minX = clamp01(box.minX - box.width * boxExpansion)
        let maxX = clamp01(box.maxX + box.width * boxExpansion)
        let minY = clamp01(box.minY - box.height * boxExpansion)
        let maxY = clamp01(box.maxY + box.height * boxExpansion)
        let width = (maxX - minX) * extent.width
        let height = (maxY - minY) * extent.height
        // y 翻转：归一化 maxY = 画面下方 → CI 低 y。CI rect 的 y 取翻后的下边缘。
        return CGRect(x: minX * extent.width,
                      y: extent.height - maxY * extent.height,
                      width: width,
                      height: height)
    }

    /// 人脸框帧间平滑：两角点复用 smoothKeypoints（首帧直取、dropout 保持、
    /// 自适应 EMA）。previous 为 nil（首帧/复位）时原样返回 current。
    public static func smoothedBox(previous: CGRect?, current: CGRect,
                                   params: KeypointSmoothingParams) -> CGRect {
        guard let previous else { return current }
        let prevCorners = [previous.origin, CGPoint(x: previous.maxX, y: previous.maxY)]
        let currCorners = [current.origin, CGPoint(x: current.maxX, y: current.maxY)]
        let flat = smoothKeypoints(previous: prevCorners, current: currCorners, params: params)
        guard let a = flat[0], let b = flat[1] else { return current }  // 平滑保形状，防御分支
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// 蒙版 DAG：黑底全画面 + 每脸一个羽化椭圆（白=处理区，黑=保持原样），
    /// source-over 累加。黑底保证 extent 恒等于画面 extent（cropped 只做交集，
    /// 椭圆若不叠底则 extent = 椭圆矩形，蒙版语义靠采样巧合而非显式定义）。
    /// 退化脸框 → 椭圆被跳过 → 全黑蒙版（= 直通，比 nil 兜底更保守）。
    /// nil 仅留给：空 faces / 退化 extent。
    public static func mask(forNormalizedBoxes faces: [CGRect], in extent: CGRect) -> CIImage? {
        guard !faces.isEmpty, extent.width >= 1, extent.height >= 1 else { return nil }
        var accumulated = CIImage(color: .black).cropped(to: extent)
        for box in faces {
            guard let ellipse = ellipse(forNormalizedBox: box, in: extent) else { continue }
            accumulated = ellipse.composited(over: accumulated)
        }
        return accumulated.cropped(to: extent)
    }

    /// 单脸椭圆：单位空间径向渐变（solidCoreRatio/2 实心 → 0.5 透明），
    /// 经非均匀仿射映射到 ciRect —— 椭圆羽化宽度随框纵横比缩放，可接受 [E]。
    private static func ellipse(forNormalizedBox box: CGRect, in extent: CGRect) -> CIImage? {
        let rect = ciRect(forNormalizedBox: box, in: extent)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        guard let filter = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0.5, y: 0.5),
            "inputRadius0": NSNumber(value: Double(solidCoreRatio * 0.5)),
            "inputRadius1": NSNumber(value: 0.5),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ]), let output = filter.outputImage else {
            return nil
        }
        let unitToRect = CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height,
                                           tx: rect.minX, ty: rect.minY)
        return output.transformed(by: unitToRect)
    }
}
