// SharedUITests — 相机美颜参数单测（CAM-003 追加）
//
// 纯函数层：off 恒等直通、全参数可应用、参数夹取（0...1）。
// （视觉效果本身归真机冒烟；这里锁定的是契约行为。）

import XCTest
import CoreImage
@testable import SharedUI

final class CameraBeautyTests: XCTestCase {

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
}
