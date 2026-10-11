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

    // MARK: metadata 脸框坐标契约

    /// 非镜像 = 透传（AVFoundation metadata/output rect 与契约同向：origin 左上）。
    func testContractRectPassthroughWhenNotMirrored() {
        let rect = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        XCTAssertEqual(MetadataFaceGeometry.contractRect(fromConvertedRect: rect, mirrored: false), rect)
    }

    /// 镜像 = 水平翻转（x' = 1 - maxX），y 与尺寸不变。
    func testContractRectMirrorsHorizontally() {
        let out = MetadataFaceGeometry.contractRect(
            fromConvertedRect: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5),
            mirrored: true)
        XCTAssertEqual(out.minX, 0.4, accuracy: 1e-9, "1 - (0.2+0.4)")
        XCTAssertEqual(out.minY, 0.3)
        XCTAssertEqual(out.width, 0.4)
        XCTAssertEqual(out.height, 0.5)
    }
}
