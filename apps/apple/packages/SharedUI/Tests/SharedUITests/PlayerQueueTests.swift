// SharedUI — 播放队列与最近播放验收（UIA-021/022；PLAN-播放器进阶 P1）
//
// 队列：播完推进、优先级语义（A-B 循环 > 单片循环 > 队列）、失败跳片、
// 跳转/清空/单文件退出队列。最近播放：去重置顶上限、持久化恢复、
// 本地缺失不可播。共享桩见 PlayerTestSupport.swift。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import XCTest
@testable import SharedUI

@MainActor
final class PlayerQueueTests: XCTestCase {

    private let urlA = URL(fileURLWithPath: "/tmp/cq-q-a.mp4")
    private let urlB = URL(fileURLWithPath: "/tmp/cq-q-b.mp4")
    private let urlC = URL(fileURLWithPath: "/tmp/cq-q-c.mp4")

    // MARK: 队列推进

    func testQueueAdvancesOnEndAndContinuesPlayback() {
        let (vm, engine) = makePlayerViewModel(isPlaying: true)
        vm.setQueue([urlA, urlB, urlC], startIndex: 0)
        XCTAssertEqual(vm.queueIndex, 0)

        engine.onEnded?()
        XCTAssertEqual(vm.queueIndex, 1, "播完推进到第二片")
        XCTAssertEqual(engine.loadCalls.count, 2, "activate 一次 + advanceQueue 换片一次")
        XCTAssertEqual(engine.playCount, 1, "下一片自动续播")
        XCTAssertTrue(vm.isPlaying)
    }

    func testSingleLoopBeatsQueue() {
        let (vm, engine) = makePlayerViewModel(duration: 60, currentTime: 59, isPlaying: true)
        vm.setQueue([urlA, urlB])
        vm.toggleLoop()

        engine.onEnded?()
        XCTAssertEqual(vm.queueIndex, 0, "单片循环优先于队列推进")
        XCTAssertEqual(engine.loadCalls.count, 1, "不换片")
        XCTAssertEqual(engine.seeks.first?.target ?? -1, 0, accuracy: 0.001, "回零续播")
    }

    func testABLoopBeatsQueue() {
        let (vm, engine) = makePlayerViewModel(duration: 120, isPlaying: true)
        vm.setQueue([urlA, urlB])
        engine.onTick?(10)
        vm.cycleABLoop()
        engine.onTick?(30)
        vm.cycleABLoop()
        XCTAssertEqual(vm.abLoopState, .looping)

        engine.onEnded?()
        XCTAssertEqual(vm.queueIndex, 0, "A-B 循环优先于队列推进")
        XCTAssertEqual(engine.seeks.first?.target ?? -1, 10, accuracy: 0.001, "回 A 续播")
    }

    func testFailureSkipsToNextQueueItem() {
        let (vm, engine) = makePlayerViewModel()
        vm.setQueue([urlA, urlB, urlC])

        engine.onStateChange?(.failed("坏文件"))
        XCTAssertEqual(vm.queueIndex, 1, "失败自动跳下一片")
        XCTAssertEqual(engine.loadCalls.count, 2, "activate + 跳片重载")
        XCTAssertEqual(vm.feedback, "已跳过无法播放的文件")
    }

    func testFailureOnLastQueueItemKeepsErrorBanner() {
        let (vm, engine) = makePlayerViewModel()
        vm.setQueue([urlA])

        engine.onStateChange?(.failed("坏文件"))
        if case .failed = vm.state {
            // 预期：无下一片可跳时落错误横幅
        } else {
            XCTFail("队列末尾失败应保持 failed 态（错误横幅）")
        }
        XCTAssertTrue(vm.showsControls)
    }

    func testJumpQueueForcesReloadAndPlays() {
        let (vm, engine) = makePlayerViewModel()
        vm.setQueue([urlA, urlB, urlC])

        vm.jumpQueue(to: 2)
        XCTAssertEqual(vm.queueIndex, 2)
        XCTAssertEqual(engine.loadCalls.count, 2, "跳转强制重载")
        XCTAssertEqual(engine.playCount, 1, "跳转后起播")

        vm.jumpQueue(to: 2)
        XCTAssertEqual(engine.loadCalls.count, 3, "跳到当前项 = 从头重播（force 语义）")
    }

    func testPlayStandaloneClearsQueue() {
        let (vm, engine) = makePlayerViewModel()
        vm.setQueue([urlA, urlB])

        vm.playStandalone(urlC)
        XCTAssertTrue(vm.queue.isEmpty, "手动换片 = 退出队列模式")
        XCTAssertNil(vm.queueIndex)
        XCTAssertEqual(engine.loadCalls.count, 2)
    }

    func testClearQueue() {
        let (vm, _) = makePlayerViewModel()
        vm.setQueue([urlA, urlB])
        vm.clearQueue()
        XCTAssertTrue(vm.queue.isEmpty)
        XCTAssertNil(vm.queueIndex)
        XCTAssertEqual(vm.feedback, "已清空播放队列")
    }

    // MARK: 最近播放

    func testRecentStoreRecordDedupsCapsAndPersists() {
        let suiteName = "PlayerQueueTests.recent." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 真实临时文件：装载时的可达性清理只剔除不存在的路径
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        var created: [URL] = []
        defer {
            // 清理失败无害（临时目录系统会回收）
            for url in created {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for index in 0..<25 {
            let fileUrl = dir.appendingPathComponent("cq-recent-\(UUID().uuidString)-\(index).mp4")
            FileManager.default.createFile(atPath: fileUrl.path, contents: Data([0x00]))
            created.append(fileUrl)
        }

        let store = PlayerRecentStore(defaults: defaults)
        for (index, fileUrl) in created.enumerated() {
            store.record(url: fileUrl, name: "片 \(index)")
        }
        XCTAssertEqual(store.items.count, PlayerRecentStore.maxItems, "上限 20 条")
        XCTAssertEqual(store.items.first?.name, "片 24", "最新置顶")

        store.record(url: created[10], name: "片 10 重看")
        XCTAssertEqual(store.items.count, PlayerRecentStore.maxItems, "去重不新增")
        XCTAssertEqual(store.items.first?.name, "片 10 重看", "重看置顶")
        XCTAssertEqual(store.items.filter { $0.urlString == created[10].absoluteString }.count, 1, "同一文件唯一")

        let reloaded = PlayerRecentStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.count, PlayerRecentStore.maxItems, "跨会话持久化恢复")
        XCTAssertEqual(reloaded.items.first?.name, "片 10 重看")
    }

    func testRecentStoreMissingLocalFileIsNotPlayable() {
        let suiteName = "PlayerQueueTests.recent.missing." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlayerRecentStore(defaults: defaults)

        let missing = URL(fileURLWithPath: "/tmp/cq-recent-missing-\(UUID().uuidString).mp4")
        store.record(url: missing, name: "缺失")
        guard let item = store.items.first else {
            return XCTFail("record 后应有条目")
        }
        XCTAssertNil(store.playbackURL(for: item), "本地文件不存在 = 不可播（调用方剔除）")

        store.remove(item)
        XCTAssertTrue(store.items.isEmpty, "remove 生效")
    }

    func testRemoteURLRecordedAndPlayableWithoutBookmark() {
        let suiteName = "PlayerQueueTests.recent.remote." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlayerRecentStore(defaults: defaults)

        let remote = URL(string: "https://example.com/video/stream.m3u8") ?? URL(fileURLWithPath: "/fallback")
        store.record(url: remote, name: "远程片")
        XCTAssertEqual(store.items.first?.isRemote, true)
        XCTAssertNotNil(store.playbackURL(for: store.items[0]), "远程 URL 无需 bookmark 直接可播")
    }

    func testVMRecordsRecentOnReadyOncePerMedia() {
        let suiteName = "PlayerQueueTests.recent.vm." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlayerRecentStore(defaults: defaults)

        let (vm, engine) = makePlayerViewModel(defaults: defaults, recent: store)
        engine.onStateChange?(.ready)
        engine.onStateChange?(.ready)
        XCTAssertEqual(store.items.count, 1, "ready 记录一次，重复广播不重复记")
        XCTAssertEqual(store.items.first?.name, vm.mediaTitle)
    }
}
