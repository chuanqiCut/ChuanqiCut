// ChuanqiCut — Swift 绑定预览验收（BIND-003 子步骤 6）
//
// 与 C 侧 test_c_abi_preview.c 的分工一致：这里证明 **Swift 投影的契约语义**
// （创建 / 状态码 / 诊断量 / 句柄有效性）。像素正确性由 SharedUI 测试覆盖
// （离屏 RT 是 private 存储，读回必须经 blit —— PreviewFrameRenderer 的用例做）。
//
// UIA-009 子步骤 2 收口后：模型装配走 **Session**（异步提交 + 轮询版本），
// Previewer 挂 session 渲染（本地 registerAsset/addClip 已删除）。
//
// 运行：cd bindings/swift && swift test --disable-sandbox

import XCTest
import Metal
@testable import ChuanqiCut

final class PreviewTests: XCTestCase {

    /// 仓库根（golden 夹具位于 tests/golden/frames/）。从本文件位置上溯五级：
    /// 文件 → ChuanqiCutTests → Tests → swift → bindings → 仓库根。
    private var goldenVideo: String {
        TestPaths.goldenVideo
    }

    /// 轮询版本推进（提交异步；RunLoop 泵给 observer/内核线程让路）。
    @discardableResult
    private func waitForVersion(_ session: Session, _ target: UInt64,
                                timeoutMs: Int = 5000) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while session.currentSnapshot.version < target && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return session.currentSnapshot.version >= target
    }

    /// 会话装配：注册素材 + 视频轨 + 0~5s 单片段（用 golden 夹具）。
    private func assembleTimeline(_ session: Session) throws -> UInt64 {
        XCTAssertEqual(session.registerAsset(id: 1, path: goldenVideo), .ok)
        XCTAssertEqual(session.addTrack(kind: 0), .ok)
        XCTAssertTrue(waitForVersion(session, 2), "素材与轨道生效")
        let trackId = try XCTUnwrap(session.queryTracks().first?.trackId)
        let ts = RationalTime.projectTimescale
        XCTAssertEqual(session.addClip(trackId: trackId, assetId: 1,
                                       start: RationalTime(value: 0, timescale: ts),
                                       duration: RationalTime(value: 5 * Int64(ts), timescale: ts),
                                       sourceIn: RationalTime(value: 0, timescale: ts)), .ok)
        XCTAssertTrue(waitForVersion(session, 3))
        return trackId
    }

    // MARK: 创建与降级

    func testInvalidSizeReturnsNil() {
        guard let session = Session() else { return XCTFail("Session 创建失败") }
        XCTAssertNil(Previewer(session: session, width: 0, height: 64))
        XCTAssertNil(Previewer(session: session, width: 64, height: 0))
    }

    /// 内核预览后端（图形设备 / blit pass / 帧提供器）齐备时创建成功。
    func testCreateSucceedsWithBackends() throws {
        let session = try XCTUnwrap(Session())
        _ = try assembleTimeline(session)
        let preview = Previewer(session: session, width: 64, height: 64)
        XCTAssertNotNil(preview, "cq_preview_create 应成功（本机有 Metal 后端）")
    }

    // MARK: 空时间线（空隙语义）

    func testEmptyTimelineGapIsIoNotFoundWithBlackHandle() throws {
        let session = try XCTUnwrap(Session())
        let ts = RationalTime.projectTimescale
        guard let preview = Previewer(session: session, width: 64, height: 64) else {
            return XCTFail("预览创建失败")
        }

        let status = preview.renderFrame(pts: RationalTime(value: 60000, timescale: ts))
        XCTAssertEqual(status, .ioNotFound, "空时间线 = 空隙，不是渲染失败")

        XCTAssertNotNil(preview.textureHandle, "空隙帧仍返回可显示句柄（内核已清黑）")
        XCTAssertFalse(preview.lastHitClip)
        XCTAssertFalse(preview.lastCpuFallback, "没导入就没有 CPU 退化可言")
        // 内核在无取帧记录时的初值语义：0/1（「有没有帧」看 lastHitClip）。
        XCTAssertEqual(preview.lastFramePts, RationalTime(value: 0, timescale: 1))
    }

    // MARK: 真实素材取帧（session 模型 → 预览渲染，最终一致）

    func testSessionModelRendersThroughPreview() throws {
        let session = try XCTUnwrap(Session())
        _ = try assembleTimeline(session)
        guard let preview = Previewer(session: session, width: 256, height: 256) else {
            return XCTFail("预览创建失败")
        }

        // 渲染 0.5s —— HANDOFF-003 实测该素材 t=0.5s 的解码帧 pts = 60000。
        let ts = RationalTime.projectTimescale
        XCTAssertEqual(preview.renderFrame(pts: RationalTime(value: 60000, timescale: ts)), .ok)

        XCTAssertTrue(preview.lastHitClip)
        XCTAssertFalse(preview.lastCpuFallback, "零拷贝链路断了会持续为 true，必须在此暴露")
        XCTAssertNotNil(preview.textureHandle, "渲染成功必须产出可显示句柄")

        // ⚠️ 关键语义量：证明「渲染的确实是 t 那一帧」而非复用旧帧。
        let actualPts = try XCTUnwrap(preview.lastFramePts)
        XCTAssertEqual(actualPts.value, 60000)
        XCTAssertEqual(actualPts.timescale, ts)
    }

    // MARK: 模型变更后的最终一致（收口的核心语义）

    func testModelChangeIsVisibleToNextRender() throws {
        let session = try XCTUnwrap(Session())
        // 初始：无任何片段 → 空隙
        guard let preview = Previewer(session: session, width: 64, height: 64) else {
            return XCTFail("预览创建失败")
        }
        let ts = RationalTime.projectTimescale
        XCTAssertEqual(preview.renderFrame(pts: RationalTime(value: 60000, timescale: ts)),
                       .ioNotFound, "装配前：空隙")

        // 提交片段（异步）→ 等生效 → 下一次渲染命中
        _ = try assembleTimeline(session)
        XCTAssertEqual(preview.renderFrame(pts: RationalTime(value: 60000, timescale: ts)), .ok,
                       "模型变更后：同一次 render 命中（快照最终一致）")
        XCTAssertTrue(preview.lastHitClip)
    }

    func testOverlapIsRejectedAsynchronously() throws {
        let session = try XCTUnwrap(Session())
        _ = try assembleTimeline(session)
        let ts = RationalTime.projectTimescale
        let trackId = try XCTUnwrap(session.queryTracks().first?.trackId)

        let versionBefore = session.currentSnapshot.version
        XCTAssertEqual(session.addClip(trackId: trackId, assetId: 1,
                                       start: RationalTime(value: 2 * Int64(ts), timescale: ts),
                                       duration: RationalTime(value: 5 * Int64(ts), timescale: ts),
                                       sourceIn: RationalTime(value: 0, timescale: ts)), .ok,
                      "提交入队成功（校验在 session 线程）")
        Thread.sleep(forTimeInterval: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(session.currentSnapshot.version, versionBefore, "重叠：版本不推进")
        XCTAssertEqual(session.queryClips().count, 1, "重叠：片段不出现")
    }
}
