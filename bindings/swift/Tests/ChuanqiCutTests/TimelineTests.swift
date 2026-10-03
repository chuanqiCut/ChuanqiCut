// ChuanqiCut — 会话级时间线绑定验收（UIA-009 子步骤 1 / UIA-004 读路径）
//
// 语义重点（与 C 侧 test_c_abi_session.c 分工一致，这里验 Swift 投影）：
//   * 提交异步 —— 「提交 → 轮询版本 → 查询」的最终一致模式
//   * 查询同步读快照 —— 返回真实结构（含 id / RationalTime 原样透传）
//   * digest 真实 —— 加片段后变化
//   * 重叠提交被内核拒绝 —— 版本不推进、片段不出现

import XCTest
@testable import ChuanqiCut

final class TimelineTests: XCTestCase {

    private func waitForVersion(_ session: Session, _ target: UInt64,
                                timeoutMs: Int = 5000) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while session.currentSnapshot.version < target && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return session.currentSnapshot.version >= target
    }

    func testEmptyTimelineIsQueryable() {
        guard let session = Session() else { return XCTFail("Session 创建失败") }
        XCTAssertEqual(session.trackCount(), 0)
        XCTAssertTrue(session.queryTracks().isEmpty)
        XCTAssertTrue(session.queryClips().isEmpty)
        XCTAssertNotEqual(session.currentSnapshot.digest, 0, "内建模型：digest 从构造起真实")
    }

    func testSubmitAndQueryEndToEnd() throws {
        guard let session = Session() else { return XCTFail("Session 创建失败") }
        let digest0 = session.currentSnapshot.digest

        XCTAssertEqual(session.registerAsset(id: 1, path: "/tmp/clip.mp4"), .ok)
        XCTAssertTrue(waitForVersion(session, 1), "registerAsset 后版本推进")
        XCTAssertEqual(session.currentSnapshot.digest, digest0, "素材注册不影响时间线指纹")

        XCTAssertEqual(session.addTrack(kind: 0), .ok)
        XCTAssertTrue(waitForVersion(session, 2))
        let tracks = session.queryTracks()
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(tracks[0].isVideo)
        let trackId = tracks[0].trackId

        let ts = RationalTime.projectTimescale
        XCTAssertEqual(session.addClip(trackId: trackId, assetId: 1,
                                       start: RationalTime(value: 0, timescale: ts),
                                       duration: RationalTime(value: 5000, timescale: ts),
                                       sourceIn: RationalTime(value: 0, timescale: ts)), .ok)
        XCTAssertEqual(session.addClip(trackId: trackId, assetId: 1,
                                       start: RationalTime(value: 8000, timescale: ts),
                                       duration: RationalTime(value: 5000, timescale: ts),
                                       sourceIn: RationalTime(value: 0, timescale: ts)), .ok)
        XCTAssertTrue(waitForVersion(session, 4))

        let clips = session.queryClips()
        XCTAssertEqual(clips.count, 2)
        XCTAssertLessThan(clips[0].start.value, clips[1].start.value, "轨内按 start 升序")
        XCTAssertEqual(clips[0].duration, RationalTime(value: 5000, timescale: ts))
        XCTAssertEqual(clips[0].assetId, 1)
        XCTAssertNotEqual(clips[0].clipId, clips[1].clipId)

        let filtered = session.queryClips(trackId: trackId)
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(session.queryClips(trackId: 999).isEmpty)

        XCTAssertNotEqual(session.currentSnapshot.digest, digest0, "加片段后指纹变化")
    }

    func testOverlappingAddClipIsRejectedAsynchronously() throws {
        guard let session = Session() else { return XCTFail("Session 创建失败") }
        XCTAssertEqual(session.addTrack(kind: 0), .ok)
        XCTAssertTrue(waitForVersion(session, 1))
        let trackId = try XCTUnwrap(session.queryTracks().first?.trackId)

        let ts = RationalTime.projectTimescale
        XCTAssertEqual(session.addClip(trackId: trackId, assetId: 1,
                                       start: RationalTime(value: 0, timescale: ts),
                                       duration: RationalTime(value: 5000, timescale: ts),
                                       sourceIn: RationalTime(value: 0, timescale: ts)), .ok)
        XCTAssertTrue(waitForVersion(session, 2))

        // 与已有片段重叠 → session 线程校验失败：版本不推进、片段不出现。
        let versionBefore = session.currentSnapshot.version
        XCTAssertEqual(session.addClip(trackId: trackId, assetId: 1,
                                       start: RationalTime(value: 2000, timescale: ts),
                                       duration: RationalTime(value: 5000, timescale: ts),
                                       sourceIn: RationalTime(value: 0, timescale: ts)), .ok,
                      "提交本身入队成功（校验在 session 线程）")
        Thread.sleep(forTimeInterval: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(session.currentSnapshot.version, versionBefore, "校验失败：版本不推进")
        XCTAssertEqual(session.queryClips().count, 1, "校验失败：片段不出现")
    }
}
