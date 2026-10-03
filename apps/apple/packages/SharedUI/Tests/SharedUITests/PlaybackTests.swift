// SharedUI — 播放驱动验收（UIA-010）
//
// 覆盖：ViewModel 的播放/暂停/停止，以及「播放头真的被墙钟推着走」。
// 断言的是 **playhead 随真实时间推进**，不是"定时器被调了几次" ——
// 后者测不出累加漂移，前者能。
//
// ⚠️ 已知限制（不是本测试的缺陷，是实现形态）：MVP 的取帧与渲染在主线程，
//    帧率取决于单帧耗时，未实测。见任务卡「剩余风险」。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import XCTest
import ChuanqiCut
@testable import SharedUI

@MainActor
final class PlaybackTests: XCTestCase {

    private var goldenURL: URL { URL(fileURLWithPath: RepoPath.goldenVideo) }

    private func waitForTimelineVersion(_ vm: EditorViewModel, _ minVersion: UInt64,
                                        timeoutMs: Int = 5000) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while vm.timeline.version < minVersion && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return vm.timeline.version >= minVersion
    }

    func testPlaybackDrivesPlayheadByWallClock() throws {
        let vm = try EditorViewModel()
        guard FileManager.default.fileExists(atPath: goldenURL.path) else {
            return XCTFail("golden 夹具缺失：\(goldenURL.path)")
        }

        // 无内容时不得启动播放（UI 按钮同样置灰）
        vm.togglePlayback()
        XCTAssertFalse(vm.isPlaying, "无片段时不播放")

        XCTAssertEqual(vm.importMedia(url: goldenURL), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, 3), "导入落地")

        vm.togglePlayback()
        XCTAssertTrue(vm.isPlaying, "播放启动")

        // 等真实时间流逝：播放头必须跟着走（墙钟驱动，不是帧数累加）
        let started = Date()
        var advanced: RationalTime?
        while Date().timeIntervalSince(started) < 0.6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if vm.playhead.value > 0 { advanced = vm.playhead }
        }
        let reached = try XCTUnwrap(advanced, "播放头应被墙钟推进")
        XCTAssertGreaterThan(reached.value, 0)
        // 0.6s 内推进量应 ≈0.6s（帧网格 1001/30000）：放宽到 [0.2s, 1.5s]
        let seconds = Double(reached.value) / Double(reached.timescale)
        XCTAssertGreaterThan(seconds, 0.2, "推进量 ≈ 真实流逝时间（实测 \(seconds)s）")
        XCTAssertLessThan(seconds, 1.5, "推进量未失控（实测 \(seconds)s）")

        // 暂停 → 冻结
        vm.togglePlayback()
        XCTAssertFalse(vm.isPlaying, "暂停")
        let frozen = vm.playhead
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(vm.playhead, frozen, "暂停后播放头冻结")

        // 停止 → 归 0
        vm.stopPlayback()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.playhead.value, 0, "停止回到 0")
    }
}
