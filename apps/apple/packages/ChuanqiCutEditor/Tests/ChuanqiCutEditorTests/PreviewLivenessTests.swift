// SharedUI — 预览活性验收测试（UIA-020）
//
// 对应 SPEC-UIA-032 §5 验收 #1/#2：
//   1. 模型推进（导入 / 提交后回查）后，ViewModel 对当前播放头补取帧请求、
//      renderEpoch 递增 —— 「模型变了」与「播放头变了」同样触发重渲染；
//   2. 追帧收敛判定（PreviewSettleRule）在「同 pts 重渲染」下能收敛 ——
//      旧 pts 比较在该场景永不收敛，正是"导入后预览黑屏"的缺口。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import XCTest
@testable import ChuanqiCutEditor
import ChuanqiCut

@MainActor
final class PreviewLivenessTests: XCTestCase {

    // MARK: PreviewSettleRule（纯函数）

    /// 装载时刻看到的 seq 与之后每帧 seq 的关系决定收敛：
    /// seq 前进 = 装载的请求已发布（成功/空隙黑/失败 nil 纹理都发布）→ 收敛。
    func testSettleRuleConvergesOnlyAfterSeqAdvances() {
        // 未装载过（seqAtArm = 0）且还没有任何帧：继续追
        XCTAssertTrue(PreviewSettleRule.shouldKeepDriving(seqAtArm: 0, currentSeq: 0))
        // 看到的还是装载前的旧帧：继续追
        XCTAssertTrue(PreviewSettleRule.shouldKeepDriving(seqAtArm: 7, currentSeq: 7))
        // 新帧发布（seq 前进）：收敛
        XCTAssertFalse(PreviewSettleRule.shouldKeepDriving(seqAtArm: 7, currentSeq: 8))
        XCTAssertFalse(PreviewSettleRule.shouldKeepDriving(seqAtArm: 7, currentSeq: 99))
    }

    // MARK: ViewModel 层活性

    /// 轮询等待条件成立（内核异步 + observer 走 main queue + MainActor Task）。
    private func waitUntil(_ condition: @autoclosure () -> Bool,
                           timeoutMs: Int = 5000) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// 导入素材（模型推进）后：renderEpoch 递增 + 泵收到新请求。
    /// 这是"导入后预览黑屏"缺口的直接回归用例：旧行为下 applySnapshot 不请求。
    func testImportAdvancesRenderEpochAndRequestsFrame() throws {
        let viewModel = try EditorViewModel()
        // 初始装载（refreshTimeline）就应请求一次播放头 0 的帧并推进代数。
        XCTAssertGreaterThanOrEqual(viewModel.renderEpoch, 1,
                                    "初始装载应推进渲染代数")

        let requestedBefore = viewModel.previewPump?.stats.requested ?? 0
        let epochBefore = viewModel.renderEpoch

        let url = URL(fileURLWithPath: RepoPath.goldenVideo)
        guard FileManager.default.fileExists(atPath: RepoPath.goldenVideo) else {
            throw XCTSkip("golden 素材缺失：\(RepoPath.goldenVideo)")
        }
        let status = viewModel.importMedia(url: url)
        XCTAssertEqual(status, .ok, "golden 素材导入应成功")

        // applySnapshot 回流后：时间线有片段 + epoch 前进 + 泵收到新请求。
        XCTAssertTrue(waitUntil(!viewModel.timeline.clips.isEmpty),
                      "片段应在快照回流后可见")
        XCTAssertTrue(waitUntil(viewModel.renderEpoch > epochBefore),
                      "模型推进应递增渲染代数")
        let requestedAfter = viewModel.previewPump?.stats.requested ?? 0
        XCTAssertGreaterThan(requestedAfter, requestedBefore,
                             "模型推进应对当前播放头补一次取帧请求")
    }

    /// 提交被拒后的回查（refreshFromKernel）同样推进渲染代数：
    /// 这是"拖拽被内核拒绝留幽灵位置"路径上的预览活性。
    func testRefreshFromKernelAdvancesRenderEpoch() throws {
        let viewModel = try EditorViewModel()
        let epochBefore = viewModel.renderEpoch
        viewModel.refreshFromKernel()
        XCTAssertGreaterThan(viewModel.renderEpoch, epochBefore)
    }
}
