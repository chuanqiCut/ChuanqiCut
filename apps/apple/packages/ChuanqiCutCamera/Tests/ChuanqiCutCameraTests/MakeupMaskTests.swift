// ChuanqiCutCameraTests — 美妆区域蒙版纯函数（CAM-026）
//
// 覆盖顺序：纯几何（凸包 / 坐标翻转）→ 单区域蒙版（存在性与 extent 契约）→
// 宿主实渲染采样验证「挖空」语义（唇内 / perseverance etc.）→ 参数的夹取与直通。
// 渲染采样范式照 FaceMaskTests（CIContext + toBitmap，CI y → 位图 y 翻转，宽容差）。
// 真机观感归传哲；本文件的职责是**蒙版几何与单调性**可被机器守住。

import XCTest
import CoreImage
@testable import ChuanqiCutCamera

final class MakeupMaskTests: XCTestCase {

    private let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)

    // MARK: - 纯几何

    func testConvexHullOfSquareDropsInteriorPoints() {
        let pts = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2),
                   CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8),
                   CGPoint(x: 0.5, y: 0.5)]          // 内部点必须被吐出来
        let hull = MakeupMask.convexHull(pts)
        XCTAssertEqual(hull.count, 4, "方形的凸包只有 4 个角，内部点被剔除")
        XCTAssertFalse(hull.contains(CGPoint(x: 0.5, y: 0.5)), "形心不应留在凸包里")
    }

    func testConvexHullReturnsInputWhenTooFewPoints() {
        let two = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)]
        XCTAssertEqual(MakeupMask.convexHull(two), two, "<3 点原样返回（无法构成多边形）")
    }

    func testCiPointFlipsNormalizedYToCIPixels() {
        let p = MakeupMask.ciPoint(CGPoint(x: 0.25, y: 0.25), in: canvas)
        XCTAssertEqual(p.x, 25, accuracy: 0.001)
        XCTAssertEqual(p.y, 75, accuracy: 0.001, "归一化 y（左上起）→ CI y 需翻转")
    }

    // MARK: - 单区域蒙版契约

    func testPolygonMaskNilForTooFewPoints() {
        XCTAssertNil(MakeupMask.polygonMask(points: [CGPoint(x: 0.1, y: 0.1)], in: canvas),
                     "点数不足以三角化 → nil（调用方跳过该区域）")
    }

    func testPolygonMaskExtentEqualsCanvas() {
        let tri = [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.5, y: 0.6)]
        XCTAssertEqual(MakeupMask.polygonMask(points: tri, in: canvas)?.extent, canvas,
                       "蒙版 extent 恒等于画面（P81：CIRadialGradient/Gaussian 后必须 cropped 回）")
    }

    func testRadialMaskExtentIsCroppedBack() {
        let mask = MakeupMask.irisMask(pupil: CGPoint(x: 0.5, y: 0.5), faceScale: 0.2, in: canvas)
        XCTAssertEqual(mask?.extent, canvas,
                       "径向渐变 extent 天然有限，必须夹回画面 extent")
    }

    func testBlushMaskNilWithoutEyePoints() {
        XCTAssertNil(MakeupMask.blushMask(leftEye: [], rightEye: [], faceScale: 0.2, in: canvas),
                     "无眼位 = 无腮红参考点 → nil（不做全画面兜底，算法驱动定则）")
    }

    func testEyeshadowMaskNilForTooFewEyePoints() {
        XCTAssertNil(MakeupMask.eyeshadowMask(eye: [CGPoint(x: 0.4, y: 0.4)],
                                              faceScale: 0.2, in: canvas),
                     "眼窝点不足 → nil")
    }

    // MARK: - 渲染采样：蒙版黑白语义

    /// 采样某点亮度（0...255）。`toBitmap` 首行 = bounds 顶部 → CI y 需翻转。
    private func sample(_ mask: CIImage, at point: CGPoint, _ canvas: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> UInt8 {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var bitmap = [UInt8](repeating: 200, count: 100 * 100 * 4)
        context.render(mask, toBitmap: &bitmap, rowBytes: 100 * 4,
                       bounds: canvas, format: .RGBA8, colorSpace: nil)
        let x = min(max(Int(point.x.rounded()), 0), 99)
        let yTop = min(max(Int((100 - point.y).rounded()) - 1, 0), 99)
        return bitmap[(yTop * 100 + x) * 4]
    }

    func testPolygonMaskRendersWhiteInsideBlackOutside() {
        let tri = [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.5, y: 0.6)]
        guard let mask = MakeupMask.polygonMask(points: tri, in: canvas) else {
            return XCTFail("三点应产出三角形蒙版")
        }
        XCTAssertGreaterThanOrEqual(sample(mask, at: CGPoint(x: 50, y: 45)), 200, "多边形内 = 白（着色区）")
        XCTAssertLessThanOrEqual(sample(mask, at: CGPoint(x: 3, y: 3)), 25, "多边形外 = 黑（保持原样）")
    }

    func testLipMaskCarvesOutInnerLips() {
        // 外唇 = 大方；内唇 = 同心小方（口腔/牙齿保护：唇妆不得染到牙）。
        let outer = [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4),
                     CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.4, y: 0.6)]
        let inner = [CGPoint(x: 0.46, y: 0.46), CGPoint(x: 0.54, y: 0.46),
                     CGPoint(x: 0.54, y: 0.54), CGPoint(x: 0.46, y: 0.54)]
        let center = CGPoint(x: 50, y: 50)

        guard let outerOnly = MakeupMask.lipMask(outer: outer, inner: [], in: canvas) else {
            return XCTFail("无内唇点时应退化为整块外唇蒙版")
        }
        XCTAssertGreaterThanOrEqual(sample(outerOnly, at: center), 200, "未给内唇 → 唇中心仍着色")

        guard let carved = MakeupMask.lipMask(outer: outer, inner: inner, in: canvas) else {
            return XCTFail("外唇 + 内唇应产出挖空蒙版")
        }
        XCTAssertLessThan(sample(carved, at: center), sample(outerOnly, at: center) - 50,
                          "口腔区域必须显著变暗 —— 牙齿保护的机器防线（真机观感项归传哲）")
        XCTAssertEqual(carved.extent, canvas)
    }

    // MARK: - 参数契约

    func testParamsClampStrengthIntoUnitRange() {
        let wild = MakeupParams(lipTint: 3.0, blush: -1.0, eyeshadow: 0.5, brow: 0.5, iris: 0.5)
        XCTAssertEqual(wild.lipTint, 1.0, "上溢夹到 1（滑杆语义单调，不做截断意外行为）")
        XCTAssertEqual(wild.blush, 0.0, "下溢夹到 0")
    }

    func testOffIsIdentity() {
        XCTAssertTrue(MakeupParams.off.isOff, "off 恒等于全 0")
        XCTAssertFalse(MakeupParams.presets["自然"]?.isOff ?? true, "预设必须真的有效果")
    }

    func testPresetsHaveExpectedNames() {
        XCTAssertEqual(Set(MakeupParams.presets.keys), ["自然", "元气", "浓颜"],
                       "UI 面板写死这三个键名，改了要同步 CameraView")
    }
}
