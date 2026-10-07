// SharedUITests — 相机滤镜预设单测（CAM-003）
//
// 纯函数层测试：预设可应用、原图直通恒等、展示名唯一。
// （渲染链路本身依赖 MTKView + 相机设备，归真机冒烟，见 TASK-CAM-003。）

import XCTest
import CoreImage
@testable import ChuanqiCutCamera

final class CameraFilterTests: XCTestCase {

    /// 任意非空 CIImage（1x1 纯色足够，滤镜链不依赖尺寸）。
    private func makeSourceImage() -> CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.4, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    func testAllPresetsApply() {
        let source = makeSourceImage()
        for preset in CameraFilterPreset.allCases {
            let output = preset.apply(to: source)
            XCTAssertNotNil(output, "\(preset.rawValue) 应返回非 nil（不伪造成功）")
            if let output {
                XCTAssertFalse(output.extent.isEmpty, "\(preset.rawValue) 输出不应为空 extent")
            }
        }
    }

    func testNoneIsIdentity() {
        let source = makeSourceImage()
        let output = CameraFilterPreset.none.apply(to: source)
        XCTAssertTrue(output === source, "none 必须原样返回入参（直通语义）")
    }

    func testDisplayNamesUnique() {
        let names = CameraFilterPreset.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "展示名必须唯一（UI 选择器依赖）")
        XCTAssertEqual(names.count, 8, "预设数量变化时须同步相机页滤镜条与测试")
    }

    func testPresetsHaveChineseNames() {
        for preset in CameraFilterPreset.allCases {
            XCTAssertFalse(preset.displayName.isEmpty, "\(preset.rawValue) 展示名不得为空")
        }
    }
}
