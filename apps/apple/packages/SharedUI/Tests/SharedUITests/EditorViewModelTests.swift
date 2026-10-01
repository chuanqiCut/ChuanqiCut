// SharedUI — EditorViewModel 验收测试（UIA-002）
//
// 对应 Spec §6 验收 #4：EditorViewModel 创建 Session 成功，observer 收到快照。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox
// （--disable-sandbox：SwiftPM 沙箱会拦 ~/.swiftpm/security 的写入，同 bindings 包）

import XCTest
@testable import SharedUI
import ChuanqiCut

@MainActor
final class EditorViewModelTests: XCTestCase {

    /// 轮询等待快照版本推进（内核异步，submit 不阻塞）。
    /// 用 RunLoop 泵主队列：observer 回流走 main queue + MainActor Task。
    private func waitForVersion(_ viewModel: EditorViewModel,
                                _ target: UInt64,
                                timeoutMs: Int = 5000) {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while viewModel.snapshot.version < target && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testInitCreatesSessionAndStartsAtVersionZero() throws {
        let viewModel = try EditorViewModel()
        XCTAssertEqual(viewModel.snapshot.version, 0)
        XCTAssertEqual(viewModel.snapshot.digest, 0, "MODEL-001 落地前 digest 恒为 0")
        XCTAssertTrue(viewModel.lastChanges.isEmpty)
    }

    func testSubmitAdvancesSnapshotViaObserver() throws {
        let viewModel = try EditorViewModel()

        let status = viewModel.submit("ui-test-ok") { .ok }
        XCTAssertEqual(status, .ok, "submit 应成功入队")

        waitForVersion(viewModel, 1)
        XCTAssertEqual(viewModel.snapshot.version, 1, "observer 应回流递增后的快照")
        XCTAssertEqual(viewModel.lastChanges.count, 1)
        XCTAssertEqual(viewModel.lastChanges.first?.name, "ui-test-ok")
    }

    func testFailedChangeDoesNotAdvanceSnapshot() throws {
        let viewModel = try EditorViewModel()

        viewModel.submit("ui-test-ok") { .ok }
        waitForVersion(viewModel, 1)

        viewModel.submit("ui-test-bad") { .invalidArgument }
        // 失败变更：版本不推进、observer 不回调；给内核一点时间确认没有回调
        Thread.sleep(forTimeInterval: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(viewModel.snapshot.version, 1)
        XCTAssertTrue(viewModel.lastChanges.isEmpty == false
                      && viewModel.lastChanges.allSatisfy { $0.name == "ui-test-ok" })
    }

    func testRefreshCapabilitiesFillsAllEntries() throws {
        let viewModel = try EditorViewModel()
        viewModel.refreshCapabilities()

        // 未装平台后端时内核一律返回 .no（安全默认）—— 但条目必须齐全
        XCTAssertEqual(viewModel.capabilities.count, 16)
        XCTAssertEqual(viewModel.capabilities[.hwDecodeH264], .no)
        XCTAssertEqual(viewModel.capabilities[.gpuMetal], .no)
    }
}
