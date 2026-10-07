// SharedUITests — 相机美颜参数单测（CAM-003 建立，CAM-012 适配）
//
// 纯函数层：off 恒等直通、全参数可应用、参数夹取（0...1）、引擎注入契约。
// （视觉效果本身归真机冒烟；这里锁定的是契约行为。
//   Metal kernel 的算法级验证（单调/保边/耗时）归 tools/qa/beauty_harness，
//   真机人工验收归传哲。）

import XCTest
import CoreImage
@testable import ChuanqiCutCamera

final class CameraBeautyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CameraBeautyEngine.reset()
    }

    override func tearDown() {
        CameraBeautyEngine.reset()
        super.tearDown()
    }

    private func makeSourceImage() -> CIImage {
        CIImage(color: CIColor(red: 0.6, green: 0.5, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    func testOffIsIdentity() {
        let source = makeSourceImage()
        let output = CameraBeautyParams.off.apply(to: source)
        XCTAssertTrue(output === source, "全关必须原样返回入参（三路 WYSIWYG 的直通契约）")
    }

    func testAllStrengthsApply() {
        let source = makeSourceImage()
        for smoothing in [0.0, 0.3, 0.7, 1.0] {
            for brightening in [0.0, 0.3, 0.7, 1.0] {
                let params = CameraBeautyParams(smoothing: smoothing, brightening: brightening)
                let output = params.apply(to: source)
                XCTAssertNotNil(output)
                XCTAssertEqual(output.extent, source.extent,
                               "smoothing=\(smoothing) brightening=\(brightening) 不得改变画面尺寸")
            }
        }
    }

    func testParamsClampedToUnitRange() {
        let over = CameraBeautyParams(smoothing: 1.7, brightening: -0.5)
        XCTAssertEqual(over.smoothing, 1.0, "超上限夹到 1")
        XCTAssertEqual(over.brightening, 0.0, "负值夹到 0（等效关闭该通道）")
        XCTAssertTrue(CameraBeautyParams(smoothing: 0, brightening: -0.5).isOff,
                      "夹取后全零应判定为 off")
    }

    // MARK: - 引擎注入契约（CAM-012）

    private final class InvocationBox: @unchecked Sendable {
        var count = 0
    }

    /// 可清点调用次数的透传引擎（返回输入 + 半透明标记色混合，便于断言生效）。
    private func makeCountingEngine(_ box: InvocationBox) -> CameraBeautySmoothingEngine {
        return { image, strength in
            box.count += 1
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: strength * 0.1,
            ])
        }
    }

    func testEngineOverridesSmoothingWhenEngaged() {
        let box = InvocationBox()
        CameraBeautyEngine.smoothing = makeCountingEngine(box)
        let source = makeSourceImage()
        let output = CameraBeautyParams(smoothing: 0.5, brightening: 0).apply(to: source)
        XCTAssertEqual(box.count, 1, "smoothing > 0 必须走注入引擎")
        XCTAssertNotNil(output)
        XCTAssertEqual(output.extent, source.extent, "引擎结果不得改变画面尺寸（引擎契约）")
    }

    func testOffNeverInvokesEngine() {
        let box = InvocationBox()
        CameraBeautyEngine.smoothing = makeCountingEngine(box)
        let source = makeSourceImage()
        let output = CameraBeautyParams.off.apply(to: source)
        XCTAssertEqual(box.count, 0, "off 直通不得触碰引擎")
        XCTAssertTrue(output === source, "off 恒等直通与引擎安装无关")
    }

    func testBrighteningOnlySkipsEngine() {
        let box = InvocationBox()
        CameraBeautyEngine.smoothing = makeCountingEngine(box)
        _ = CameraBeautyParams(smoothing: 0, brightening: 0.5).apply(to: makeSourceImage())
        XCTAssertEqual(box.count, 0, "引擎只负责磨皮通道；美白仍由本文件实现")
    }

    func testEngineDeclineFallsBackToDefault() {
        CameraBeautyEngine.smoothing = { _, _ in nil }  // 引擎放弃
        let source = makeSourceImage()
        let output = CameraBeautyParams(smoothing: 0.5, brightening: 0).apply(to: source)
        XCTAssertNotNil(output, "引擎放弃后必须回落默认实现，不允许 nil 输出")
        XCTAssertEqual(output.extent, source.extent, "回落路径同样不得改变画面尺寸")
    }
}
