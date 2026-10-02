// ChuanqiCut — Swift 绑定预览验收（BIND-003 子步骤 6）
//
// 与 C 侧 test_c_abi_preview.c 的分工一致：这里证明 **Swift 投影的契约语义**
// （创建 / 状态码 / 诊断量 / 句柄有效性）。像素正确性由 SharedUI 测试覆盖
// （离屏 RT 是 private 存储，读回必须经 blit —— PreviewFrameRenderer 的用例做）。
//
// 运行：cd bindings/swift && swift test --disable-sandbox

import XCTest
import Metal
@testable import ChuanqiCut

final class PreviewTests: XCTestCase {

    /// 仓库根（golden 夹具位于 tests/golden/frames/）。从本文件位置上溯五级：
    /// 文件 → ChuanqiCutTests → Tests → swift → bindings → 仓库根。
    private var repoRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/ChuanqiCutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // bindings/swift
            .deletingLastPathComponent()   // bindings
            .deletingLastPathComponent()   // 仓库根
            .path
    }

    private var goldenVideo: String {
        repoRoot + "/tests/golden/frames/gf_1080p_h264.mp4"
    }

    // MARK: 创建与降级

    func testInvalidSizeReturnsNil() {
        XCTAssertNil(Previewer(width: 0, height: 64))
        XCTAssertNil(Previewer(width: 64, height: 0))
    }

    /// 内核预览后端（图形设备 / blit pass / 帧提供器）齐备时创建成功。
    /// 若本断言失败且在非 Apple 环境，属预期（预览后端缺失 → nil 降级）。
    func testCreateSucceedsWithBackends() {
        let preview = Previewer(width: 64, height: 64)
        XCTAssertNotNil(preview, "cq_preview_create 应成功（本机有 Metal 后端）")
    }

    // MARK: 空时间线（空隙语义）

    func testEmptyTimelineGapIsIoNotFoundWithBlackHandle() {
        guard let preview = Previewer(width: 64, height: 64) else {
            return XCTFail("预览创建失败")
        }
        // 0.5s @ 项目 timescale（ADR-0009）。
        let pts = RationalTime(value: 60000, timescale: RationalTime.projectTimescale)

        let status = preview.renderFrame(pts: pts)
        XCTAssertEqual(status, .ioNotFound, "空时间线 = 空隙，不是渲染失败")

        XCTAssertNotNil(preview.textureHandle, "空隙帧仍返回可显示句柄（内核已清黑）")
        XCTAssertFalse(preview.lastHitClip)
        XCTAssertFalse(preview.lastCpuFallback, "没导入就没有 CPU 退化可言")
        // 内核在无取帧记录时的初值语义：0/1（「有没有帧」看 lastHitClip）。
        XCTAssertEqual(preview.lastFramePts, RationalTime(value: 0, timescale: 1))
    }

    // MARK: 真实素材取帧

    func testRegisterAndRenderGoldenFrame() throws {
        guard let preview = Previewer(width: 256, height: 256) else {
            return XCTFail("预览创建失败")
        }
        guard FileManager.default.fileExists(atPath: goldenVideo) else {
            return XCTFail("golden 夹具缺失：\(goldenVideo)")
        }

        XCTAssertEqual(preview.registerAsset(id: 1, path: goldenVideo), .ok)
        // 重复注册同 id：整体替换，不报错。
        XCTAssertEqual(preview.registerAsset(id: 1, path: goldenVideo), .ok)

        let ts = RationalTime.projectTimescale
        // 5 秒片段从 0 开始，素材内 1:1 映射（MODEL-001 无 retime）。
        XCTAssertEqual(preview.addClip(
            trackId: 1, assetId: 1,
            start: RationalTime(value: 0, timescale: ts),
            duration: RationalTime(value: 5 * Int64(ts), timescale: ts),
            sourceIn: RationalTime(value: 0, timescale: ts)), .ok)

        // 渲染 0.5s —— HANDOFF-003 实测该素材 t=0.5s 的解码帧 pts = 60000。
        let pts = RationalTime(value: 60000, timescale: ts)
        XCTAssertEqual(preview.renderFrame(pts: pts), .ok, "命中片段并完成渲染")

        XCTAssertTrue(preview.lastHitClip)
        XCTAssertFalse(preview.lastCpuFallback, "零拷贝链路断了会持续为 true，必须在此暴露")
        XCTAssertNotNil(preview.textureHandle, "渲染成功必须产出可显示句柄")

        // ⚠️ 关键语义量：证明「渲染的确实是 t 那一帧」而非复用旧帧
        //    （静态彩条像素相同，只有实际 pts 能区分）。
        let actualPts = try XCTUnwrap(preview.lastFramePts)
        XCTAssertEqual(actualPts.value, 60000)
        XCTAssertEqual(actualPts.timescale, ts)
    }

    func testGapInsideTimelineIsIoNotFound() throws {
        guard let preview = Previewer(width: 64, height: 64) else {
            return XCTFail("预览创建失败")
        }
        guard FileManager.default.fileExists(atPath: goldenVideo) else {
            return XCTFail("golden 夹具缺失：\(goldenVideo)")
        }
        let ts = RationalTime.projectTimescale
        XCTAssertEqual(preview.registerAsset(id: 1, path: goldenVideo), .ok)
        XCTAssertEqual(preview.addClip(
            trackId: 1, assetId: 1,
            start: RationalTime(value: 0, timescale: ts),
            duration: RationalTime(value: 5 * Int64(ts), timescale: ts),
            sourceIn: RationalTime(value: 0, timescale: ts)), .ok)

        // 片段之外（10s）= 空隙。
        XCTAssertEqual(preview.renderFrame(
            pts: RationalTime(value: 10 * Int64(ts), timescale: ts)), .ioNotFound)
        XCTAssertFalse(preview.lastHitClip)
    }

    func testOverlapIsRejected() throws {
        guard let preview = Previewer(width: 64, height: 64) else {
            return XCTFail("预览创建失败")
        }
        guard FileManager.default.fileExists(atPath: goldenVideo) else {
            return XCTFail("golden 夹具缺失：\(goldenVideo)")
        }
        let ts = RationalTime.projectTimescale
        XCTAssertEqual(preview.registerAsset(id: 1, path: goldenVideo), .ok)
        XCTAssertEqual(preview.addClip(
            trackId: 1, assetId: 1,
            start: RationalTime(value: 0, timescale: ts),
            duration: RationalTime(value: 5 * Int64(ts), timescale: ts),
            sourceIn: RationalTime(value: 0, timescale: ts)), .ok)

        // 同轨重叠（2s 处再放一条 5s）→ kInvalidArgument（MODEL-001 语义）。
        XCTAssertEqual(preview.addClip(
            trackId: 1, assetId: 1,
            start: RationalTime(value: 2 * Int64(ts), timescale: ts),
            duration: RationalTime(value: 5 * Int64(ts), timescale: ts),
            sourceIn: RationalTime(value: 0, timescale: ts)), .invalidArgument)
    }
}
