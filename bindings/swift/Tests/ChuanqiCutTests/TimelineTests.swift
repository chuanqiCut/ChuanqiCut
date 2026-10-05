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

    func testAssetQueryAndProbeDuration() throws {
        guard let session = Session() else { return XCTFail("Session 创建失败") }
        // golden 夹具路径唯一真源 = TestPaths（P30：禁止手写 #filePath 上溯链）
        let golden = TestPaths.goldenVideo
        guard FileManager.default.fileExists(atPath: golden) else {
            return XCTFail("golden 夹具缺失：\(golden)")
        }

        XCTAssertTrue(session.queryAssets().isEmpty, "初始素材表为空")
        XCTAssertEqual(session.registerAsset(id: 7, path: golden), .ok)
        XCTAssertTrue(waitForVersion(session, 1))

        // 查询（读快照；registerAsset 发布新快照 —— UIA-009 子步骤 2 语义）
        let assets = session.queryAssets()
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets[0].assetId, 7)
        XCTAssertEqual(assets[0].path, golden)
        XCTAssertFalse(assets[0].pathTruncated)
        XCTAssertEqual(session.assetCount(), 1)

        // 时长探测（同步打开容器；golden 是 ~3s 彩条）
        let duration = try XCTUnwrap(session.probeMediaDuration(path: golden),
                                     "探测应成功")
        XCTAssertGreaterThan(duration.value, 0)
        XCTAssertGreaterThan(duration.timescale, 0)
        let seconds = Double(duration.value) / Double(duration.timescale)
        XCTAssertGreaterThan(seconds, 0.5, "时长 \(seconds)s 合理")
        XCTAssertLessThan(seconds, 30, "时长 \(seconds)s 合理")

        // 探测不存在的文件 → nil（不是崩溃）
        XCTAssertNil(session.probeMediaDuration(path: "/tmp/definitely_missing_cq.mp4"))
    }

    // MARK: - 编辑与撤销（UIA-005）

    /// 同步点：提交一条必定成功的哨兵并等它落地。
    ///
    /// 为什么不能直接「提交后 sleep」：被内核拒绝的提交**不推进版本**，
    /// 光等版本推进永远等不到；而单纯 sleep 只是赌时长。session 队列 FIFO，
    /// 哨兵落地 ⇒ 它之前的所有提交（含被拒的）都已执行完。
    ///
    /// - Parameters:
    ///   - base: **提交这批变更之前**读到的版本号。⚠️ 必须是提交前读的：
    ///     若在提交后才读，异步任务可能已经落地，基准版本号偏大 ⇒ 目标版本
    ///     永远达不到 ⇒ 超时（首版就是这么错的，5s 超时失败）。
    ///   - k: 这批变更里预期**成功**的条数（预期被拒的不计）。
    ///     哨兵落地时版本恰好 == base + k + 1。
    @discardableResult
    private func drain(_ session: Session, from base: UInt64, expecting k: UInt64) -> Bool {
        guard session.submit("test-sentinel") { .ok } == .ok else { return false }
        return waitForVersion(session, base + k + 1)
    }

    func testMoveAndTrimRoundTripWithUndoRedo() throws {
        guard let session = Session() else { return XCTFail("Session 创建失败") }
        let ts = RationalTime.projectTimescale
        let t = { (v: Int64) in RationalTime(value: v, timescale: ts) }

        var base = session.currentSnapshot.version
        XCTAssertEqual(session.registerAsset(id: 1, path: "/tmp/a.mp4"), .ok)
        XCTAssertEqual(session.addTrack(kind: 0), .ok)
        XCTAssertTrue(drain(session, from: base, expecting: 2), "register + addTrack 落地")

        let trackId = try XCTUnwrap(session.queryTracks().first?.trackId)
        base = session.currentSnapshot.version
        XCTAssertEqual(session.addClip(trackId: trackId, assetId: 1,
                                       start: t(0), duration: t(5000), sourceIn: t(0)), .ok)
        XCTAssertEqual(session.addClip(trackId: trackId, assetId: 1,
                                       start: t(8000), duration: t(5000), sourceIn: t(0)), .ok)
        XCTAssertTrue(drain(session, from: base, expecting: 2), "两个片段落地")

        let clipA = try XCTUnwrap(session.queryClips().first?.clipId)
        XCTAssertTrue(session.canUndo, "有命令历史 → canUndo 为 true")
        XCTAssertFalse(session.canRedo, "未撤销过 → canRedo 为 false")

        // ---- move：合法 ----
        base = session.currentSnapshot.version
        XCTAssertEqual(session.moveClip(clipId: clipA, start: t(1000)), .ok)
        XCTAssertTrue(drain(session, from: base, expecting: 1))
        XCTAssertEqual(session.queryClips().first?.start, t(1000), "move 生效（内核真值）")

        // ---- move：与 B 重叠 → 被拒（版本只推进哨兵那一次）----
        base = session.currentSnapshot.version
        XCTAssertEqual(session.moveClip(clipId: clipA, start: t(7000)), .ok,
                       "提交本身入队成功")
        XCTAssertTrue(drain(session, from: base, expecting: 0), "哨兵落地 ⇒ 重叠 move 已执行完")
        XCTAssertEqual(session.currentSnapshot.version, base + 1,
                       "重叠 move 被拒：版本只推进哨兵")
        XCTAssertEqual(session.queryClips().first?.start, t(1000), "被拒：start 未变")

        // ---- trim：合法（只改 duration，不动 sourceIn）----
        base = session.currentSnapshot.version
        XCTAssertEqual(session.trimClip(clipId: clipA, duration: t(3000)), .ok)
        XCTAssertTrue(drain(session, from: base, expecting: 1))
        XCTAssertEqual(session.queryClips().first?.duration, t(3000), "trim 生效")
        XCTAssertEqual(session.queryClips().first?.sourceIn, t(0), "trim 不动 sourceIn")

        // ---- trim：duration = 0 → 被拒 ----
        base = session.currentSnapshot.version
        XCTAssertEqual(session.trimClip(clipId: clipA, duration: t(0)), .ok)
        XCTAssertTrue(drain(session, from: base, expecting: 0))
        XCTAssertEqual(session.queryClips().first?.duration, t(3000), "duration=0 被拒")

        // ---- undo ×2 → 回到 move 之前 ----
        base = session.currentSnapshot.version
        XCTAssertEqual(session.undo(), .ok)
        XCTAssertTrue(drain(session, from: base, expecting: 1))
        XCTAssertEqual(session.queryClips().first?.duration, t(5000), "undo trim")
        XCTAssertTrue(session.canRedo, "撤销后可重做")

        base = session.currentSnapshot.version
        XCTAssertEqual(session.undo(), .ok)
        XCTAssertTrue(drain(session, from: base, expecting: 1))
        XCTAssertEqual(session.queryClips().first?.start, t(0), "undo move")

        // ---- redo ×2 → 再前进 ----
        base = session.currentSnapshot.version
        XCTAssertEqual(session.redo(), .ok)
        XCTAssertTrue(drain(session, from: base, expecting: 1))
        XCTAssertEqual(session.queryClips().first?.start, t(1000), "redo move")

        base = session.currentSnapshot.version
        XCTAssertEqual(session.redo(), .ok)
        XCTAssertTrue(drain(session, from: base, expecting: 1))
        XCTAssertEqual(session.queryClips().first?.duration, t(3000), "redo trim")
        XCTAssertFalse(session.canRedo, "redo 到底")
        XCTAssertTrue(session.canUndo)
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
