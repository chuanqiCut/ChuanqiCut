// SharedUITests — 人脸区域蒙版纯函数 + CameraBeauty faces 三态契约（CAM-019）
//
// 坐标翻转 / 外扩夹取 / 框平滑 / 蒙版几何为纯函数断言；蒙版与区域化效果经
// macOS 宿主 CIContext 实渲染采样（与 beauty_harness 同思路，宽容差）。
// 真机视觉验收归传哲；检测桥（VisionDetector）在 iOSApp target，不在本测试面。

import XCTest
import CoreImage
@testable import ChuanqiCutCamera

final class FaceMaskTests: XCTestCase {

    private let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)

    // MARK: - 坐标链（归一化左上 → CI 左下）

    func testCiRectFlipsYAndExpands() {
        let rect = FaceMask.ciRect(forNormalizedBox: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.4),
                                   in: canvas)
        let expected = CGRect(x: 15.5, y: 44, width: 39, height: 52)
        XCTAssertEqual(rect.minX, expected.minX, accuracy: 0.001, "x 外扩")
        XCTAssertEqual(rect.minY, expected.minY, accuracy: 0.001, "y 翻转后下边缘")
        XCTAssertEqual(rect.width, expected.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, expected.height, accuracy: 0.001)
        // 脸的视觉顶部（归一化 minY）必须映射到 CI 高 y —— 翻错方向画面会上下颠倒。
        XCTAssertEqual(rect.maxY, 96, accuracy: 0.001, "y 翻转方向：脸顶 = CI 高 y")
    }

    func testCiRectClampsAtCanvasEdges() {
        let edge = FaceMask.ciRect(forNormalizedBox: CGRect(x: 0.9, y: 0.9, width: 0.2, height: 0.2),
                                   in: canvas)
        XCTAssertLessThanOrEqual(edge.maxX, canvas.maxX + 0.001, "右缘出血框夹取")
        XCTAssertGreaterThanOrEqual(edge.minY, canvas.minY - 0.001, "下缘出血框夹取")
    }

    // MARK: - 框平滑

    func testSmoothedBoxStrengthZeroFollowsCurrent() {
        let output = FaceMask.smoothedBox(
            previous: CGRect(x: 0, y: 0, width: 10, height: 10),
            current: CGRect(x: 5, y: 5, width: 10, height: 10),
            params: KeypointSmoothingParams(strength: 0, speedGain: 0))
        XCTAssertEqual(output, CGRect(x: 5, y: 5, width: 10, height: 10), "strength 0 = 完全跟随")
    }

    func testSmoothedBoxMaxStrengthHoldsOnJitter() {
        let output = FaceMask.smoothedBox(
            previous: CGRect(x: 0, y: 0, width: 10, height: 10),
            current: CGRect(x: 5, y: 5, width: 10, height: 10),
            params: KeypointSmoothingParams(strength: 1, speedGain: 0))
        XCTAssertEqual(output, CGRect(x: 0, y: 0, width: 10, height: 10),
                       "静止/微抖时最重平滑 = 保持上一帧")
    }

    func testSmoothedBoxFirstFrameTakesCurrent() {
        let current = CGRect(x: 5, y: 5, width: 10, height: 10)
        let output = FaceMask.smoothedBox(previous: nil, current: current,
                                          params: KeypointSmoothingParams(strength: 1))
        XCTAssertEqual(output, current, "首帧/复位后直取")
    }

    // MARK: - 蒙版 DAG

    func testMaskNilForEmptyFaces() {
        XCTAssertNil(FaceMask.mask(forNormalizedBoxes: [], in: canvas), "空脸 = nil")
    }

    func testMaskExtentEqualsCanvas() {
        let mask = FaceMask.mask(forNormalizedBoxes: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)],
                                 in: canvas)
        XCTAssertEqual(mask?.extent, canvas,
                       "蒙版 extent 恒等于画面（黑底显式定义，不靠采样巧合）")
    }

    /// 宿主 CPU/GPU 渲染采样（宽容差断言几何，不做像素级比对）。
    private func renderMask(_ mask: CIImage, at point: CGPoint) -> UInt8 {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var bitmap = [UInt8](repeating: 200, count: 100 * 100 * 4)
        context.render(mask, toBitmap: &bitmap, rowBytes: 100 * 4,
                       bounds: canvas, format: .RGBA8, colorSpace: nil)
        let x = min(max(Int(point.x.rounded()), 0), 99)
        // toBitmap 首行 = bounds 顶部：CI y → 位图 y 翻转。
        let yTop = min(max(Int((100 - point.y).rounded()) - 1, 0), 99)
        return bitmap[(yTop * 100 + x) * 4]
    }

    func testMaskRendersCoreWhiteOutsideBlack() {
        let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        guard let mask = FaceMask.mask(forNormalizedBoxes: [box], in: canvas) else {
            return XCTFail("正常脸必须产出蒙版")
        }
        let rect = FaceMask.ciRect(forNormalizedBox: box, in: canvas)
        XCTAssertGreaterThanOrEqual(renderMask(mask, at: CGPoint(x: rect.midX, y: rect.midY)), 200,
                                    "蒙版中心实心白（处理区）")
        XCTAssertLessThanOrEqual(renderMask(mask, at: CGPoint(x: 2, y: 2)), 25,
                                 "远处角落黑（保持原样区）")
    }

    func testMaskDegenerateBoxRendersAllBlack() {
        guard let mask = FaceMask.mask(forNormalizedBoxes: [CGRect(x: 0.5, y: 0.5, width: 0, height: 0)],
                                       in: canvas) else {
            return XCTFail("退化框应产出全黑蒙版（直通），不是 nil（全画面）")
        }
        XCTAssertEqual(mask.extent, canvas)
        XCTAssertLessThanOrEqual(renderMask(mask, at: CGPoint(x: 50, y: 50)), 25,
                                 "退化框 → 全黑 = 效果直通（比 nil 全画面兜底更保守）")
    }

    // MARK: - CameraBeauty faces 三态契约（SPEC-CAM-018-019 §4）

    private func makeSourceImage() -> CIImage {
        CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testFacesEmptyIsIdentityPassthrough() {
        let source = makeSourceImage()
        let params = CameraBeautyParams(smoothing: 0.8, brightening: 0.8)
        let output = params.apply(to: source, faces: [])
        XCTAssertTrue(output === source, "检测过但无脸 → 直通（对齐美型无脸直通口径）")
    }

    func testFacesNilKeepsLegacyFullFrameBehavior() {
        let source = makeSourceImage()
        let params = CameraBeautyParams(smoothing: 0, brightening: 0.8)
        let output = params.apply(to: source, faces: nil)
        XCTAssertFalse(output === source, "faces = nil（未接检测）→ 全画面美白（旧行为）")
        XCTAssertEqual(output.extent, source.extent)
    }

    func testRegionalBrighteningOnlyAffectsFaceRegion() {
        let source = makeSourceImage()
        let params = CameraBeautyParams(smoothing: 0, brightening: 1.0)
        let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let output = params.apply(to: source, faces: [box])

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func luminance(_ image: CIImage, at point: CGPoint) -> Double {
            var bitmap = [UInt8](repeating: 0, count: 100 * 100 * 4)
            context.render(image, toBitmap: &bitmap, rowBytes: 100 * 4,
                           bounds: canvas, format: .RGBA8, colorSpace: nil)
            let x = min(max(Int(point.x.rounded()), 0), 99)
            let yTop = min(max(Int((100 - point.y).rounded()) - 1, 0), 99)
            return Double(bitmap[(yTop * 100 + x) * 4])
        }
        let rect = FaceMask.ciRect(forNormalizedBox: box, in: canvas)
        let facePoint = CGPoint(x: rect.midX, y: rect.midY)
        let backgroundPoint = CGPoint(x: 2, y: 2)

        XCTAssertGreaterThan(luminance(output, at: facePoint),
                             luminance(source, at: facePoint),
                             "脸区内比原图亮")
        XCTAssertEqual(luminance(output, at: backgroundPoint),
                       luminance(source, at: backgroundPoint),
                       accuracy: 2,
                       "背景必须与原图一致 —— 美白不越出蒙版（用户验收核心项）")
    }
}
