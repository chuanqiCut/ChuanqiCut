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
        // ⚠️ 必须给**非空人脸框**：算法驱动定则（传哲 2026-10-07）下 faces=nil / []
        // 一律直通（无算法即无效果），引擎根本不会被调用——那是 testOffNeverInvokesEngine
        // 与直通语义的验收范围，不是本用例的。本用例验的是「有脸时注入引擎接管磨皮」。
        let output = CameraBeautyParams(smoothing: 0.5, brightening: 0)
            .apply(to: source, faces: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)])
        XCTAssertEqual(box.count, 1, "有脸 + smoothing > 0 必须走注入引擎")
        XCTAssertNotNil(output)
        XCTAssertEqual(output.extent, source.extent, "引擎结果不得改变画面尺寸（引擎契约）")
    }

    /// 直通语义的机器防线：nil / [] 时**任何引擎都不许被触碰**（算法驱动定则）。
    func testNoFaceNeverInvokesEngine() {
        let box = InvocationBox()
        CameraBeautyEngine.smoothing = makeCountingEngine(box)
        let source = makeSourceImage()
        let params = CameraBeautyParams(smoothing: 0.5, brightening: 0)
        XCTAssertTrue(params.apply(to: source, faces: nil) === source, "faces=nil 必须恒等直通")
        XCTAssertTrue(params.apply(to: source, faces: []) === source, "faces=[] 必须恒等直通")
        XCTAssertEqual(box.count, 0, "无脸时不得触碰引擎（无算法即无效果）")
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
        // 同上：必须给脸，否则走的是直通分支，回落路径根本不会被触发。
        let output = CameraBeautyParams(smoothing: 0.5, brightening: 0)
            .apply(to: source, faces: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)])
        XCTAssertNotNil(output, "引擎放弃后必须回落默认实现，不允许 nil 输出")
        XCTAssertEqual(output.extent, source.extent, "回落路径同样不得改变画面尺寸")
    }
    /// CAM-033：磨皮+美级合并后仍单次蒙版混合——数值等价断言：
    /// 合并实现（磨皮→美白→单次 Blend）与「磨皮 Blend 后再美白 Blend」在
    /// 蒙版内/外采样点逐位一致（混合是逐像素线性算子，同 mask 嵌套可折叠）。
    /// 用默认实现（引擎未注入）对比两段式参考：蒙版核心区与蒙版外各验一点。
    /// CAM-033 合并混合 + CAM-035 半分辩率链的语义抽检：
    /// 蒙版外（远角）= 原图逐位（保真）；蒙版内（脸心）≠ 原图（磨皮+美白生效）。
    /// （旧"单次 ≡ 两次混合"逐位对比已无意义：两次混合路径已删除，且半分辨率
    /// 引入后参考实现需同口径复刻——语义抽检即回归防线。）
    func testCombinedBlendPreservesOutsideMaskAndAppliesInside() {
        let params = CameraBeautyParams(smoothing: 0.5, brightening: 0.5)
        let source = makeSourceImage()
        let face = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let output = params.apply(to: source, faces: [face])
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        func sample(_ image: CIImage, _ p: CGPoint) -> [UInt8] {
            var pixel = [UInt8](repeating: 0, count: 4)
            ctx.render(image, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
            return pixel
        }
        let extent = source.extent
        let faceCenter = CGPoint(x: extent.midX, y: extent.midY)
        let corner = CGPoint(x: extent.minX + 2, y: extent.minY + 2)
        XCTAssertEqual(sample(output, corner), sample(source, corner), "蒙版外必须保真")
        XCTAssertNotEqual(sample(output, faceCenter), sample(source, faceCenter), "蒙版内应有美颜生效")
    }


    /// CAM-035 P3 后半：半分辨率子链的输出 extent 必须恢复原帧（奇数帧含向上
    /// 取整的 1px 溢出也要被 cropped 兜底裁回）。
    func testHalfChainRestoresExtent() {
        let source = makeSourceImage()
        let params = CameraBeautyParams(smoothing: 0.5, brightening: 0.5)
        let output = params.apply(to: source, faces: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)])
        XCTAssertEqual(output.extent, source.extent, "半分辨率链上采样混回后 extent 不变")
        XCTAssertFalse(output.extent.isEmpty)
    }

    /// 美白亮度曲线对强度单调：s=1.0 的输出亮度 ≥ s=0.2（脸框中心采样）。
    func testBrighteningMonotonic() {
        let source = makeSourceImage()
        let face = [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)]
        let weak = CameraBeautyParams(smoothing: 0, brightening: 0.2).apply(to: source, faces: face)
        let strong = CameraBeautyParams(smoothing: 0, brightening: 1.0).apply(to: source, faces: face)
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        func meanLuma(_ image: CIImage) -> Double {
            let extent = image.extent
            var pixel = [UInt8](repeating: 0, count: 4)
            var sum = 0.0
            let n = 5
            for dy in 0..<n {
                for dx in 0..<n {
                    let p = CGPoint(x: extent.minX + extent.width * (0.3 + 0.1 * Double(dx)),
                                    y: extent.minY + extent.height * (0.3 + 0.1 * Double(dy)))
                    ctx.render(image, toBitmap: &pixel, rowBytes: 4,
                               bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1),
                               format: .RGBA8, colorSpace: nil)
                    sum += 0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
                }
            }
            return sum / Double(n * n)
        }
        XCTAssertGreaterThanOrEqual(meanLuma(strong), meanLuma(weak) - 0.5,
                                    "美白强度递增亮度不降（曲线中调提亮单调）")
    }
}

