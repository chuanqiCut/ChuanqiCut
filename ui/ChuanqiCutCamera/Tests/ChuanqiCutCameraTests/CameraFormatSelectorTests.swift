import XCTest
@testable import ChuanqiCutCamera

/// 采集 format 选择规则的回归测试（2026-10-09 真机 MultiCam 崩溃修复配套）。
///
/// 崩溃回放：`AVCaptureMultiCamSession` 上设 `sessionPreset = .hd1920x1080` 抛
/// `NSInvalidArgumentException`。修复把 multiCam 路径改为逐设备选 activeFormat，
/// 而 MultiCam 下 activeFormat 还有一条硬约束（multiCamSupported 子集）。
/// 这里的用例就是守这两条选择条件不被后续改动悄悄丢掉。
final class CameraFormatSelectorTests: XCTestCase {

    private let hd = CameraFormatCandidate(width: 1280, height: 720,
                                           minFrameRate: 30, maxFrameRate: 60,
                                           multiCamSupported: true)
    private let fhd = CameraFormatCandidate(width: 1920, height: 1080,
                                            minFrameRate: 30, maxFrameRate: 60,
                                            multiCamSupported: true)
    private let uhd = CameraFormatCandidate(width: 3840, height: 2160,
                                            minFrameRate: 24, maxFrameRate: 30,
                                            multiCamSupported: false)
    private let lowFps = CameraFormatCandidate(width: 1920, height: 1080,
                                               minFrameRate: 15, maxFrameRate: 24,
                                               multiCamSupported: true)

    func testPicksClosestResolutionForTarget() {
        let idx = CameraFormatSelector.bestIndex(in: [hd, fhd],
                                                 targetWidth: 1920, targetHeight: 1080,
                                                 frameRate: 30, multiCam: false)
        XCTAssertEqual(idx, 1, "1080p 目标必须选中 1920x1080，而不是默认第一个")
    }

    func testRejectsFormatNotCoveringFrameRate() {
        let idx = CameraFormatSelector.bestIndex(in: [lowFps],
                                                 targetWidth: 1920, targetHeight: 1080,
                                                 frameRate: 30, multiCam: false)
        XCTAssertNil(idx, "帧率区间不覆盖的 format 不能被选中（否则设备侧配置失败）")
    }

    func testMultiCamOnlyAcceptsMultiCamSupportedFormats() {
        // 4K 在本例中是唯一分辨率匹配的候选，但它不支持 multiCam ——
        // 漏掉这条约束就是真机崩溃的同类错误。
        let idx = CameraFormatSelector.bestIndex(in: [uhd],
                                                 targetWidth: 3840, targetHeight: 2160,
                                                 frameRate: 30, multiCam: true)
        XCTAssertNil(idx)

        let ok = CameraFormatSelector.bestIndex(in: [uhd, fhd],
                                                targetWidth: 3840, targetHeight: 2160,
                                                frameRate: 30, multiCam: true)
        XCTAssertEqual(ok, 1, "multiCam 下必须退到支持 multiCam 的次优分辨率")
    }

    func testSingleCamIgnoresMultiCamConstraint() {
        let idx = CameraFormatSelector.bestIndex(in: [uhd],
                                                 targetWidth: 3840, targetHeight: 2160,
                                                 frameRate: 30, multiCam: false)
        XCTAssertEqual(idx, 0, "单摄可设置任意 activeFormat，不应被 multiCam 约束误伤")
    }

    func testEmptyCandidatesReturnsNil() {
        XCTAssertNil(CameraFormatSelector.bestIndex(in: [],
                                                    targetWidth: 1920, targetHeight: 1080,
                                                    frameRate: 30, multiCam: true))
    }
}
