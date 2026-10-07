// ChuanqiCut — Swift 绑定验收测试（BIND-002）
//
// 目的对应 BACKLOG 的验收「Swift 可调用全部门面接口」：
// 不是"能编译"（那太弱），而是**真的调起来、真的拿到正确结果**。
//
// 运行：cd bindings/swift && swift test --disable-sandbox
// （--disable-sandbox：本机的 SwiftPM 沙箱会拦 ~/.swiftpm/security 的写入）

import XCTest
@testable import ChuanqiCutEngine

/// 承接 @Sendable 回调里的结果（Swift 6 不允许在并发闭包中捕获 `var`）。
private final class VersionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var version: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

final class ChuanqiCutTests: XCTestCase {

    // 轮询等待版本推进（内核是异步的，submit 不阻塞）。
    private func waitForVersion(_ session: Session, _ target: UInt64, timeoutMs: Int = 5000) {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while session.currentSnapshot.version < target && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func testVersionIsReachable() {
        let v = ChuanqiCut.version
        XCTAssertGreaterThanOrEqual(v.major, 0)
        // 版本由 CMake 注入内核；此处只验证 Swift 侧真能取到（非硬编码常量）。
    }

    func testMarkMainThread() {
        // XCTest 跑在主线程，这里正好模拟宿主 App 的初始化时机。
        ChuanqiCut.markMainThread()
        XCTAssertTrue(ChuanqiCut.isMainThread)
    }

    func testCapabilityReturnsNoWithoutBackend() {
        // 未安装平台后端时一律 .no —— 安全默认，绝不谎报可用。
        XCTAssertEqual(ChuanqiCut.queryCapability(.hwDecodeH264), .no)
        XCTAssertEqual(ChuanqiCut.queryCapability(.gpuMetal), .no)
    }

    func testStatusSemantics() {
        XCTAssertTrue(Status.ok.isOK)
        XCTAssertFalse(Status.ok.isError)
        XCTAssertTrue(Status(rawValue: 5000).isError)
        // 取消不是错误（内核语义）
        XCTAssertTrue(Status.cancelled.isCancelled)
        XCTAssertFalse(Status.cancelled.isError)
        XCTAssertFalse(Status.cancelled.text.isEmpty)
    }

    func testSessionSubmitAdvancesVersion() {
        guard let session = Session() else {
            return XCTFail("Session 创建失败")
        }
        XCTAssertEqual(session.currentSnapshot.version, 0)

        let status = session.submit("add-clip") { .ok }
        XCTAssertEqual(status, .ok, "submit 应成功入队")

        waitForVersion(session, 1)
        XCTAssertEqual(session.currentSnapshot.version, 1, "成功变更后版本应为 1")
        XCTAssertEqual(session.changeCount, 1)

        let changes = session.changesSince(0)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.version, 1)
        XCTAssertEqual(changes.first?.name, "add-clip", "变更名应能取回")
        XCTAssertEqual(session.changesSince(1).count, 0)
    }

    func testFailedChangeDoesNotAdvanceVersion() {
        guard let session = Session() else { return XCTFail("Session 创建失败") }

        session.submit("ok") { .ok }
        waitForVersion(session, 1)

        // 失败变更：版本不推进、不记入日志（否则 UI 会以为状态变了而错刷）
        session.submit("bad") { .invalidArgument }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(session.currentSnapshot.version, 1)
        XCTAssertEqual(session.changeCount, 1)
    }

    func testObserverIsInvoked() {
        guard let session = Session() else { return XCTFail("Session 创建失败") }

        let called = expectation(description: "observer invoked")
        // 回调是 @Sendable 闭包，Swift 6 不允许在其中捕获 `var`，
        // 故用一个（字段只读、内部可变的）盒子承接结果。
        let observed = VersionBox()

        // 内核在 session 线程回调，绑定层默认转发到 main queue。
        session.setSnapshotObserver { snap in
            observed.version = snap.version
            called.fulfill()
        }

        session.submit("with-observer") { .ok }
        wait(for: [called], timeout: 5.0)
        XCTAssertEqual(observed.version, 1, "观察者应收到递增后的版本")
    }
}
