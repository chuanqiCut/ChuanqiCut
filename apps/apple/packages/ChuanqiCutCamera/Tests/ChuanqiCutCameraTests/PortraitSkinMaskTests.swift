// ChuanqiCutCameraTests — 人像皮肤区域蒙版（CAM-027 v1 几何级精修）
//
// 守三件事：
//   1. **契约不破**：`skinMask` 的 extent、nil 语义与 `FaceMask.mask` 完全一致；
//   2. **降级诚实**：无关键点（anchors = nil / 区域点数不足）→ 退回框级椭圆，
//      不伪造语义，也不退化成全画面；
//   3. **注入点零回归**：不安装 = CAM-019 老路径（脸区生效、背景不动）；
//      安装全黑蒙版 = 整图不动。这是给 CameraBeauty 改造的回归防线。
//
// 渲染采样范式同 FaceMaskTests（CIContext + toBitmap，CI y → 位图 y 翻转）。

import XCTest
import CoreImage
@testable import ChuanqiCutCamera

final class PortraitSkinMaskTests: XCTestCase {

    private let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let faceBox = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    override func tearDown() {
        // 注入点是全局状态，必须复位，否则污染同进程其他用例。
        CameraBeautyEngine.semanticMask = nil
        super.tearDown()
    }

    // MARK: - 构造辅助

    private func source() -> CIImage {
        CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: canvas)
    }

    /// 便捷构造：各区域默认留空（= 该区域不参与切除），按需传入点集。
    private func anchors(eye: [CGPoint]? = nil,
                         brow: [CGPoint]? = nil,
                         lips: [CGPoint]? = nil) -> MakeupAnchors {
        let bigTri = [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.3), CGPoint(x: 0.5, y: 0.7)]
        return MakeupAnchors(outerLips: lips ?? [], innerLips: [],
                             leftBrow: brow ?? [], rightBrow: [],
                             leftEye: eye ?? [], rightEye: [],
                             leftPupil: nil, rightPupil: nil,
                             faceScale: 0.35)
    }

    private func sample(_ mask: CIImage, at point: CGPoint) -> UInt8 {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var bitmap = [UInt8](repeating: 200, count: 100 * 100 * 4)
        context.render(mask, toBitmap: &bitmap, rowBytes: 100 * 4,
                       bounds: canvas, format: .RGBA8, colorSpace: nil)
        let x = min(max(Int(point.x.rounded()), 0), 99)
        let yTop = min(max(Int((100 - point.y).rounded()) - 1, 0), 99)
        return bitmap[(yTop * 100 + x) * 4]
    }

    private func luminance(_ image: CIImage, at point: CGPoint) -> Double {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var bitmap = [UInt8](repeating: 0, count: 100 * 100 * 4)
        context.render(image, toBitmap: &bitmap, rowBytes: 100 * 4,
                       bounds: canvas, format: .RGBA8, colorSpace: nil)
        let x = min(max(Int(point.x.rounded()), 0), 99)
        let yTop = min(max(Int((100 - point.y).rounded()) - 1, 0), 99)
        return Double(bitmap[(yTop * 100 + x) * 4])
    }

    // MARK: - nil / 退化语义

    func testNilForEmptyFaceBoxes() {
        XCTAssertNil(PortraitSkinMask.skinMask(for: source(), faceBoxes: [], anchors: nil),
                     "空脸 = nil（与 FaceMask 同语义，不是全画面）")
    }

    func testNilAnchorsFallsBackToBoxMask() {
        let mask = PortraitSkinMask.skinMask(for: source(), faceBoxes: [faceBox], anchors: nil)
        XCTAssertEqual(mask?.extent, canvas, "无关键点 → 框级椭圆，extent 恒定")
        let rect = FaceMask.ciRect(forNormalizedBox: faceBox, in: canvas)
        XCTAssertGreaterThanOrEqual(sample(mask!, at: CGPoint(x: rect.midX, y: rect.midY)), 200,
                                    "无关键点时脸中心仍是处理区（= CAM-019 行为，零回归）")
    }

    func testTooFewKeypointsStillFallsBackToBoxMask() {
        // 所有区域都不足 3 点（几何不可信）→ 不做任何切除。
        let mask = PortraitSkinMask.skinMask(for: source(), faceBoxes: [faceBox],
                                             anchors: anchors(eye: [CGPoint(x: 0.4, y: 0.4)]))
        let rect = FaceMask.ciRect(forNormalizedBox: faceBox, in: canvas)
        XCTAssertNotNil(mask, "点数不足不是错误，退回老路径")
        XCTAssertGreaterThanOrEqual(sample(mask!, at: CGPoint(x: rect.midX, y: rect.midY)), 200,
                                    "没有任何区域被切除 → 脸区保持可用")
    }

    // MARK: - 核心：五官区域被排除

    func testEyeRegionIsExcludedFromSkinArea() {
        let base = PortraitSkinMask.skinMask(for: source(), faceBoxes: [faceBox], anchors: nil)
        let refined = PortraitSkinMask.skinMask(
            for: source(), faceBoxes: [faceBox],
            anchors: anchors(eye: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.3),
                                   CGPoint(x: 0.5, y: 0.7)]))
        XCTAssertEqual(refined?.extent, canvas, "精修后 extent 仍然恒等于画面")

        // 眼部三角形覆盖了脸盒中心 → 那里必须变黑。
        let rect = FaceMask.ciRect(forNormalizedBox: faceBox, in: canvas)
        let eyePoint = CGPoint(x: rect.midX, y: rect.midY)
        let box: UInt8 = sample(base!, at: eyePoint)
        let after: UInt8 = sample(refined!, at: eyePoint)
        XCTAssertLessThan(after, box - 50,
                          "眼区（此处与脸盒中心重叠）必须从皮肤区里被挖掉 —— 卡的验收第一条")
    }

    func testBrowAndLipRegionsAreExcluded() {
        let brow = [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.3), CGPoint(x: 0.5, y: 0.7)]
        let base = PortraitSkinMask.skinMask(for: source(), faceBoxes: [faceBox], anchors: nil)
        let refined = PortraitSkinMask.skinMask(for: source(), faceBoxes: [faceBox],
                                                anchors: anchors(brow: brow, lips: brow))
        let p = CGPoint(x: FaceMask.ciRect(forNormalizedBox: faceBox, in: canvas).midX,
                        y: FaceMask.ciRect(forNormalizedBox: faceBox, in: canvas).midY)
        XCTAssertLessThan(sample(refined!, at: p), sample(base!, at: p) - 50,
                          "眉/唇同样处理区外 —— 这两个部位被磨糊是观感最常见的失败")
    }

    // MARK: - CameraBeauty 注入点（签名零改动的回归防线）

    func testWithoutInjectionCameraBeautyStillRegional() {
        let src = source()
        let out = CameraBeautyParams(smoothing: 0, brightening: 1.0).apply(to: src, faces: [faceBox])
        let rect = FaceMask.ciRect(forNormalizedBox: faceBox, in: canvas)
        XCTAssertGreaterThan(luminance(out, at: CGPoint(x: rect.midX, y: rect.midY)),
                             luminance(src, at: CGPoint(x: rect.midX, y: rect.midY)),
                             "不安装注入点 = 老路径：脸区仍然生效")
        XCTAssertEqual(luminance(out, at: CGPoint(x: 2, y: 2)),
                       luminance(src, at: CGPoint(x: 2, y: 2)), accuracy: 2,
                       "背景不动（区域化语义不因改造而变化）")
    }

    func testInjectedAllBlackMaskMakesBeautyANoOp() {
        CameraBeautyEngine.semanticMask = { image, _ in
            CIImage(color: .black).cropped(to: image.extent)
        }
        let src = source()
        let out = CameraBeautyParams(smoothing: 0, brightening: 1.0).apply(to: src, faces: [faceBox])
        let rect = FaceMask.ciRect(forNormalizedBox: faceBox, in: canvas)
        XCTAssertEqual(luminance(out, at: CGPoint(x: rect.midX, y: rect.midY)),
                       luminance(src, at: CGPoint(x: rect.midX, y: rect.midY)), accuracy: 2,
                       "注入全黑蒙版 → 美颜完全不作用（证明蒙版真的是唯一作用区）")
    }
}
