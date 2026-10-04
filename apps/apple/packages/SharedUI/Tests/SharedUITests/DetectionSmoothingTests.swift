// SharedUITests — 检测桥纯数学单测（CAM-011）
//
// 锁定契约：平滑收敛/直通/保持语义（TASK-CAM-011 验收）+ Vision→图像坐标映射。
// 全部确定性数值，无随机序列。（Vision 真机检测耗时不在单测范围，归 baselines 埋点。）

import XCTest
import CoreGraphics
@testable import SharedUI

final class DetectionSmoothingTests: XCTestCase {

    private let defaultParams = KeypointSmoothingParams(strength: 0.5, speedGain: 12.0)

    /// 可选点容差断言（accuracy 重载要求非可选 FloatingPoint，CGFloat? 不适用）。
    private func assertNear(_ a: CGPoint?, _ b: CGPoint?, _ message: String = "",
                            accuracy: Double = 1e-12,
                            file: StaticString = #filePath, line: UInt = #line) {
        switch (a, b) {
        case (nil, nil):
            return
        case (let lhs?, let rhs?):
            XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, "\(message)（x 分量）",
                           file: file, line: line)
            XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, "\(message)（y 分量）",
                           file: file, line: line)
        default:
            XCTFail("\(message)：一方为 nil 另一方不为 nil（\(String(describing: a)) vs \(String(describing: b))）",
                    file: file, line: line)
        }
    }

    // MARK: 参数夹取

    func testParamsClamped() {
        let over = KeypointSmoothingParams(strength: 1.7, speedGain: -5)
        XCTAssertEqual(over.strength, 1.0, accuracy: 1e-12, "strength 超上限夹到 1")
        XCTAssertEqual(over.speedGain, 0.0, accuracy: 1e-12, "speedGain 负值夹到 0")
        XCTAssertEqual(KeypointSmoothingParams.off.strength, 0.0, accuracy: 1e-12)
    }

    // MARK: 直通/重置语义

    func testOffStrengthIsPassthrough() {
        let current: [CGPoint?] = [CGPoint(x: 0.1, y: 0.2), nil, CGPoint(x: 0.9, y: 0.8)]
        let previous: [CGPoint?] = [CGPoint(x: 0.5, y: 0.5), nil, CGPoint(x: 0.5, y: 0.5)]
        let output = smoothKeypoints(previous: previous, current: current,
                                     params: .off)
        XCTAssertEqual(output.count, current.count)
        for (out, cur) in zip(output, current) {
            assertNear(out, cur, "strength 0 必须逐点直通（strength=0 时 alphaMin=1）")
        }
    }

    func testFirstFrameResetsToCurrent() {
        let current: [CGPoint?] = [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.6, y: 0.7)]
        let output = smoothKeypoints(previous: nil, current: current, params: defaultParams)
        for (out, cur) in zip(output, current) {
            XCTAssertEqual(out, cur)
        }
    }

    func testShapeChangeResetsToCurrent() {
        let previous: [CGPoint?] = Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 3)
        let current: [CGPoint?] = [CGPoint(x: 0.1, y: 0.1)]
        let output = smoothKeypoints(previous: previous, current: current, params: defaultParams)
        XCTAssertEqual(output.count, current.count, "形状变更按重置处理，返回当前帧形状")
        XCTAssertEqual(output[0], current[0])
    }

    // MARK: 缺失点保持 / 新点直取

    func testMissingPointHoldsPrevious() {
        let previous: [CGPoint?] = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.7, y: 0.7)]
        let current: [CGPoint?] = [CGPoint(x: 0.6, y: 0.6), nil]
        let output = smoothKeypoints(previous: previous, current: current,
                                     params: KeypointSmoothingParams(strength: 0.9, speedGain: 12))
        XCTAssertNotNil(output[0], "存在点正常平滑输出")
        XCTAssertEqual(output[1]?.x ?? -1, 0.7, accuracy: 1e-12,
                       "当前缺失的点保持上一帧值（单点 dropout 不闪烁）")
        XCTAssertEqual(output[1]?.y ?? -1, 0.7, accuracy: 1e-12)
    }

    func testNeverSeenPointStaysNil() {
        let output = smoothKeypoints(previous: [nil],
                                     current: [nil], params: defaultParams)
        XCTAssertNil(output[0], "从未出现过的点如实输出 nil（不伪造）")
    }

    func testNewAppearingPointTakesCurrent() {
        let output = smoothKeypoints(previous: [nil],
                                     current: [CGPoint(x: 0.3, y: 0.3)], params: defaultParams)
        XCTAssertEqual(output[0], CGPoint(x: 0.3, y: 0.3), "新出现的点无历史，直取当前帧")
    }

    // MARK: 收敛与自适应

    /// 交替微抖序列：平滑后幅度必须显著小于输入抖动，且收敛回中心值。
    func testJitterConverges() {
        let jitter: CGFloat = 0.003
        var value: CGPoint? = CGPoint(x: 0.5, y: 0.5)   // 首帧直通
        var previous: [CGPoint?]? = nil
        for frame in 0..<60 {
            let offset: CGFloat = (frame % 2 == 0) ? jitter : -jitter
            let current = [CGPoint(x: 0.5 + offset, y: 0.5 + offset)]
            let output = smoothKeypoints(previous: previous, current: current,
                                         params: KeypointSmoothingParams(strength: 0.8))
            previous = output
            value = output[0]
        }
        XCTAssertEqual(value?.x ?? -1, 0.5, accuracy: 0.001, "微抖序列必须收敛回中心值")
        let residual = abs((value?.x ?? 0) - 0.5)
        XCTAssertLessThan(residual, jitter, "输出残差必须小于输入抖动幅度（平滑生效）")
    }

    /// 大位移低延迟跟随：快速移动（超阈值位移）alpha 封顶 1，精确跟到新位置。
    func testFastMotionFollowsExactly() {
        let output = smoothKeypoints(previous: [CGPoint(x: 0.5, y: 0.5)],
                                     current: [CGPoint(x: 0.7, y: 0.4)], params: defaultParams)
        XCTAssertEqual(output[0], CGPoint(x: 0.7, y: 0.4),
                       "0.2 归一化位移在默认增益下应精确跟随（自适应低延迟）")
    }

    /// 强度单调：同一位移，strength 越大输出离上一帧越近。
    func testStrengthMonotonicity() {
        let previous = [CGPoint(x: 0.5, y: 0.5)]
        let current = [CGPoint(x: 0.505, y: 0.5)]
        func distanceFromPrevious(strength: Double) -> Double {
            let params = KeypointSmoothingParams(strength: strength, speedGain: 12)
            let out = smoothKeypoints(previous: previous, current: current, params: params)[0]!
            return Double(out.x - 0.5)
        }
        let soft = distanceFromPrevious(strength: 0.3)
        let hard = distanceFromPrevious(strength: 0.9)
        XCTAssertGreaterThan(soft, 0, "弱平滑应有可感知跟随")
        XCTAssertLessThan(hard, soft, "强平滑对同一位移的残差必须更小（滑杆方向可预期）")
    }

    // MARK: Vision → 图像归一化映射

    func testVisionPointMapping() {
        XCTAssertEqual(visionPointToImageNormalized(CGPoint(x: 0.25, y: 0.75)),
                       CGPoint(x: 0.25, y: 0.25), "y 翻转（Vision 左下原点 → 图像左上原点）")
        XCTAssertEqual(visionPointToImageNormalized(CGPoint(x: 0.5, y: -0.2)),
                       CGPoint(x: 0.5, y: 1.0), "越界下翻夹到 1")
        XCTAssertEqual(visionPointToImageNormalized(CGPoint(x: 1.3, y: 0.5)),
                       CGPoint(x: 1.0, y: 0.5), "越界右夹到 1")
    }

    func testVisionRectMapping() {
        let rect = visionRectToImageNormalized(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        // 不做 CGRect 整体精确相等：1 − maxY 的浮点结果带机器精度误差。
        XCTAssertEqual(rect.minX, 0.1, accuracy: 1e-12)
        XCTAssertEqual(rect.minY, 0.4, accuracy: 1e-12, "翻转后 origin.y = 1 − maxY")
        XCTAssertEqual(rect.width, 0.3, accuracy: 1e-12, "宽高不变")
        XCTAssertEqual(rect.height, 0.4, accuracy: 1e-12)
    }

    func testVisionRectMappingClamps() {
        let rect = visionRectToImageNormalized(CGRect(x: 0.1, y: -0.2, width: 0.3, height: 0.5))
        XCTAssertEqual(rect.minY, 0.7, accuracy: 1e-12)
        XCTAssertEqual(rect.height, 0.3, accuracy: 1e-12, "越界部分被夹取")
        XCTAssertLessThanOrEqual(rect.maxY, 1.0)
        XCTAssertGreaterThanOrEqual(rect.minX, 0.0)
    }
}
