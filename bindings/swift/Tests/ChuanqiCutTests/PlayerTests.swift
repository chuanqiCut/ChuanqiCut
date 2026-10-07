// ChuanqiCut — 播放时钟绑定验收（UIA-010）
//
// 与内核 test_c_abi_player.c 分工：那边验 C 契约，这边验 Swift 投影
// （RationalTime 出入参、isPlaying 的 Bool 化、Session.timelineDuration）。
//
// 语义重点：时刻 = 墙钟的函数（不是帧数累加）；恒为整帧；停止态恒 0。

import XCTest
@testable import ChuanqiCutEngine

final class PlayerTests: XCTestCase {

    private let frameTicks: Int64 = 1001
    private let ts: Int32 = 30000

    /// 轮询到时刻 >= target（超时返回当前值）。同时是断言：时钟若不随墙钟走必超时。
    private func waitUntil(_ player: Player, _ target: Int64,
                           timeoutMs: Int = 5000) -> Int64 {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while player.currentTime.value < target && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return player.currentTime.value
    }

    func testClockAdvancesWithWallClockAndIsFrameAligned() {
        guard let player = Player() else { return XCTFail("Player 创建失败") }

        XCTAssertEqual(player.currentTime, RationalTime(value: 0, timescale: ts),
                       "停止态时刻恒 0")
        XCTAssertFalse(player.isPlaying)

        XCTAssertEqual(player.play(), .ok)
        XCTAssertTrue(player.isPlaying)

        let reached = waitUntil(player, 3000)  // 0.1s
        XCTAssertGreaterThanOrEqual(reached, 3000, "时刻随墙钟推进（非帧数累加）")
        XCTAssertLessThan(reached, 30000, "推进量合理（<1s）")
        XCTAssertEqual(reached % frameTicks, 0, "时刻恒为整帧")

        player.pause()
        XCTAssertFalse(player.isPlaying)
        let frozen = player.currentTime
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(player.currentTime, frozen, "暂停后冻结")

        XCTAssertEqual(player.seek(to: RationalTime(value: 15000, timescale: ts)), .ok)
        XCTAssertEqual(player.currentTime.value, 14 * frameTicks, "seek 量化到整帧（向下）")

        player.stop()
        XCTAssertEqual(player.currentTime.value, 0, "stop 归 0")
    }

    func testBoundaryStopsPlaybackAndLoopRewinds() {
        guard let player = Player() else { return XCTFail("Player 创建失败") }
        XCTAssertEqual(player.setDuration(RationalTime(value: 6000, timescale: ts)), .ok)

        player.play()
        _ = waitUntil(player, 6000)
        XCTAssertEqual(player.currentTime.value, 6000, "超过边界后 clamp 到时长")
        XCTAssertEqual(player.tick(), .ok)
        XCTAssertFalse(player.isPlaying, "播完自然结束 → 停止")
        XCTAssertEqual(player.currentTime.value, 0, "结束后时刻归 0")

        player.setLoop(true)
        player.play()
        _ = waitUntil(player, 6000)
        player.tick()
        XCTAssertTrue(player.isPlaying, "loop 模式：到边界后仍在播放")
        XCTAssertLessThan(player.currentTime.value, 6000, "loop 模式：回绕")
    }

    func testTimelineDurationIsZeroThenReal() {
        guard let session = Session() else { return XCTFail("Session 创建失败") }
        guard let duration = session.timelineDuration() else {
            return XCTFail("时长查询应成功")
        }
        XCTAssertEqual(duration.value, 0, "空时间线时长 0")

        let ts = RationalTime.projectTimescale
        XCTAssertEqual(session.addTrack(kind: 0), .ok)
        let deadline = Date().addingTimeInterval(5)
        while session.currentSnapshot.version < 1 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard let trackId = session.queryTracks().first?.trackId else {
            return XCTFail("轨道未出现")
        }
        XCTAssertEqual(session.addClip(trackId: trackId, assetId: 1,
                                       start: RationalTime(value: 0, timescale: ts),
                                       duration: RationalTime(value: Int64(ts) * 5, timescale: ts),
                                       sourceIn: RationalTime(value: 0, timescale: ts)), .ok)
        let deadline2 = Date().addingTimeInterval(5)
        while session.currentSnapshot.version < 2 && Date() < deadline2 {
            Thread.sleep(forTimeInterval: 0.005)
        }

        let updated = try? XCTUnwrap(session.timelineDuration())
        XCTAssertEqual(updated?.value, Int64(ts) * 5, "时长 = 末片段结束（5s）")
        XCTAssertEqual(updated?.timescale, ts)
    }
}
