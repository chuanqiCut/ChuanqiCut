// SharedUI — 素材导入流程验收（UIA-009 子步骤 3）
//
// 覆盖：importMedia（探测时长 → 注册素材 → 建轨 → 追加片段）的最终一致：
//   * 素材库出现条目（含文件存在标记）
//   * 时间线出现片段（追加在视频轨，起点 0）
//   * 重复导入追加不重叠
// 文件失效标记（exists == false）单独验证（D3：MVP 引用原路径）。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import XCTest
import ChuanqiCut
@testable import SharedUI

@MainActor
final class MediaImportTests: XCTestCase {

    private var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // 1 → Tests/SharedUITests
            .deletingLastPathComponent()   // 2 → Tests
            .deletingLastPathComponent()   // 3 → SharedUI 包根
            .deletingLastPathComponent()   // 4 → packages
            .deletingLastPathComponent()   // 5 → apple
            .deletingLastPathComponent()   // 6 → apps
            .deletingLastPathComponent()   // 7 → 仓库根
            .appendingPathComponent("tests/golden/frames/gf_1080p_h264.mp4")
    }

    @discardableResult
    private func waitForTimelineVersion(_ viewModel: EditorViewModel, _ minVersion: UInt64,
                                        timeoutMs: Int = 5000) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while viewModel.timeline.version < minVersion && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return viewModel.timeline.version >= minVersion
    }

    func testImportAppendsClipAndPopulatesLibrary() throws {
        let viewModel = try EditorViewModel()
        let url = goldenURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return XCTFail("golden 夹具缺失：\(url.path)")
        }

        XCTAssertEqual(viewModel.importMedia(url: url), .ok, "导入应成功")

        // 素材库：1 条且文件存在（D3：引用原路径）
        XCTAssertEqual(viewModel.mediaLibrary.count, 1)
        XCTAssertTrue(viewModel.mediaLibrary[0].exists)
        XCTAssertFalse(viewModel.mediaLibrary[0].pathTruncated)

        // 时间线：等提交生效后出现片段（起点 0，时长 ≈ 素材时长）
        XCTAssertTrue(waitForTimelineVersion(viewModel, 3), "导入产生的变更应推进到 v3")
        XCTAssertEqual(viewModel.timeline.clips.count, 1, "视频轨自动创建并追加片段")
        XCTAssertEqual(viewModel.timeline.clips[0].start.value, 0)
        XCTAssertGreaterThan(viewModel.timeline.clips[0].duration.value, 0)

        // 二次导入：追加在上一片段之后（不重叠）
        XCTAssertEqual(viewModel.importMedia(url: url), .ok)
        XCTAssertTrue(waitForTimelineVersion(viewModel, viewModel.timeline.version + 2))
        XCTAssertEqual(viewModel.timeline.clips.count, 2)
        XCTAssertNotEqual(viewModel.timeline.clips[0].start.value,
                          viewModel.timeline.clips[1].start.value)
    }

    func testImportInvalidFileFailsCleanly() throws {
        let viewModel = try EditorViewModel()
        let missing = URL(fileURLWithPath: "/tmp/definitely_missing_cq_media.mp4")
        let status = viewModel.importMedia(url: missing)
        XCTAssertNotEqual(status, .ok, "打不开的文件导入应失败")
        XCTAssertTrue(viewModel.mediaLibrary.isEmpty, "失败的导入不留素材条目")
        XCTAssertTrue(viewModel.timeline.clips.isEmpty, "失败的导入不建片段")
    }

    func testLibraryMarksMissingFileAsInvalid() throws {
        // 拷贝 golden 到临时位置导入（不污染仓库夹具），删文件后验证失效标记（D3）
        let viewModel = try EditorViewModel()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cq_import_test_\(Int.random(in: 0...999_999)).mp4")
        try FileManager.default.copyItem(at: goldenURL, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertEqual(viewModel.importMedia(url: tmp), .ok)
        XCTAssertTrue(waitForTimelineVersion(viewModel, 3))
        XCTAssertTrue(viewModel.mediaLibrary[0].exists, "前置：文件存在")

        try FileManager.default.removeItem(at: tmp)
        viewModel.refreshTimeline()  // 重新查询内核素材表 + 重算 exists
        XCTAssertFalse(viewModel.mediaLibrary[0].exists, "文件被移走后应标记失效")
    }
}
