// BeautyDetectionPlanTests — 检测计划纯函数单测（CAM-033）
//
// 开关矩阵是「检测成本」的契约：任何回归（该关的没关）直接体现为真机
// 检测开销回升 —— 用例即验收（SPEC-CAM-033 §3.P1）。

import XCTest
@testable import ChuanqiCutCamera

final class BeautyDetectionPlanTests: XCTestCase {

    // MARK: 开关矩阵

    /// 全关 + metadata 可用 = **零 Vision**（本卡的核心验收）。
    func testAllOffWithMetadataIsEmpty() {
        let plan = BeautyDetectionPlan.requests(
            for: .off, faceRectNeeded: false, metadataFacesAvailable: true)
        XCTAssertTrue(plan.isEmpty, "美颜全关 + metadata 脸框可用 = 零 Vision 调用")
    }

    /// 仅磨皮 + metadata 可用 = 仍零 Vision（脸框来自采集栈）。
    func testFaceRectOnlyWithMetadataIsEmpty() {
        let plan = BeautyDetectionPlan.requests(
            for: .off, faceRectNeeded: true, metadataFacesAvailable: true)
        XCTAssertTrue(plan.isEmpty, "磨皮脸框走 metadataOutput，不需要 Vision")
    }

    /// 仅磨皮 + metadata 不可用 = 单阶段兜底框（不是 landmarks）。
    func testFaceRectOnlyWithoutMetadataFallsBackToRectangles() {
        let plan = BeautyDetectionPlan.requests(
            for: .off, faceRectNeeded: true, metadataFacesAvailable: false)
        XCTAssertEqual(plan, [.faceRectangles])
    }

    /// 磨皮关 + metadata 不可用 = 也不跑兜底框（没有需要框的功能）。
    func testAllOffWithoutMetadataIsEmpty() {
        let plan = BeautyDetectionPlan.requests(
            for: .off, faceRectNeeded: false, metadataFacesAvailable: false)
        XCTAssertTrue(plan.isEmpty)
    }

    /// 美型开 = landmarks（锚点级），与磨皮/是否 metadata 无关。
    func testFaceAnchorsNeedLandmarks() {
        let plan = BeautyDetectionPlan.requests(
            for: BeautyFeatureFlags(faceAnchors: true),
            faceRectNeeded: true, metadataFacesAvailable: true)
        XCTAssertEqual(plan, [.faceLandmarks])
    }

    /// 美体开 = bodyPose（与脸无关的功能独立启停）。
    func testBodyAnchorsNeedBodyPose() {
        let plan = BeautyDetectionPlan.requests(
            for: BeautyFeatureFlags(bodyAnchors: true),
            faceRectNeeded: false, metadataFacesAvailable: true)
        XCTAssertEqual(plan, [.bodyPose])
    }

    /// 宠物贴纸 = animal + animalPose（无脸时锚宠物眼的兜底依赖两者）。
    func testAnimalStickerNeedsAnimalAndPose() {
        let plan = BeautyDetectionPlan.requests(
            for: BeautyFeatureFlags(animalSticker: true),
            faceRectNeeded: false, metadataFacesAvailable: true)
        XCTAssertEqual(plan, [.animal, .animalPose])
    }

    /// 全开（美型+美体+宠物+磨皮）= 除兜底框外的全部请求。
    func testAllFeaturesFullSet() {
        let plan = BeautyDetectionPlan.requests(
            for: BeautyFeatureFlags(faceAnchors: true, bodyAnchors: true, animalSticker: true),
            faceRectNeeded: true, metadataFacesAvailable: true)
        XCTAssertEqual(plan, [.faceLandmarks, .bodyPose, .animal, .animalPose])
    }

    // MARK: metadata 脸框坐标契约（2026-10-11 真机定标：前摄转置映射）

    /// 定标数据回放：sensor bounds (0.4382,0.1982,0.2693,0.4763) 转置后应与
    /// 同帧 Vision 框 (0.2237,0.4480,0.4832,0.2721) 对齐（实测误差 ≤0.026）。
    func testContractRectFrontCameraTranspose() {
        let out = MetadataFaceGeometry.contractRect(
            fromSensorBounds: CGRect(x: 0.4382, y: 0.1982, width: 0.2693, height: 0.4763),
            mirrored: true)!
        XCTAssertEqual(out.minX, 0.1982, accuracy: 1e-9, "x_f = y_s")
        XCTAssertEqual(out.minY, 0.4382, accuracy: 1e-9, "y_f = x_s")
        XCTAssertEqual(out.width, 0.4763, accuracy: 1e-9, "w_f = h_s")
        XCTAssertEqual(out.height, 0.2693, accuracy: 1e-9, "h_f = w_s")
        // 与 Vision 对照框的位置误差
        XCTAssertEqual(out.midX, 0.432, accuracy: 0.03, "vision 中心 x=0.432")
        XCTAssertEqual(out.midY, 0.584, accuracy: 0.03, "vision 中心 y=0.584")
    }

    /// 后摄映射未定标 → nil（调用方丢框，plan 走 Vision 兜底）。
    func testContractRectBackCameraReturnsNil() {
        XCTAssertNil(MetadataFaceGeometry.contractRect(
            fromSensorBounds: CGRect(x: 0.4, y: 0.2, width: 0.3, height: 0.4),
            mirrored: false))
    }
}
