// SharedUI — 独立播放器状态机验收（UIA-015；SPEC-UIA-020 §6.1）
//
// 用 StubPlayerEngine 注入 PlayerViewModel，断言**控制语义**而非 AVPlayer
// 行为：拖动时机（松手才 seek）、越界钳制、倍速透传、播完停止、时间码
// 格式化、逐帧步进。AVPlayerEngine 本体（seek 精度/起播延迟）属真机项，
// 见 baselines.md「播放器（UIA-015）——未实测」。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import CoreGraphics
import XCTest
@testable import SharedUI

@MainActor
final class PlayerTests: XCTestCase {

    // MARK: Stub 引擎（记录调用，不碰 AVFoundation）

    private final class StubPlayerEngine: PlayerEngine {
        var state: PlayerEngineState = .idle
        var duration: TimeInterval = 0
        var currentTime: TimeInterval = 0
        var isPlaying = false
        var rate: Double = 1.0
        var volume: Double = 1.0
        var isMuted = false
        var videoSize: CGSize? = CGSize(width: 1920, height: 1080)
        var frameDuration: TimeInterval = 1.0 / 30.0

        var onTick: ((TimeInterval) -> Void)?
        var onStateChange: ((PlayerEngineState) -> Void)?
        var onEnded: (() -> Void)?
        var onPlayStateChange: ((Bool) -> Void)?

        private(set) var loadCalls: [URL] = []
        private(set) var seeks: [(target: TimeInterval, precise: Bool)] = []
        private(set) var playCount = 0
        private(set) var pauseCount = 0

        func load(url: URL) {
            loadCalls.append(url)
            state = .loading
        }

        func play() {
            playCount += 1
            isPlaying = true
        }

        func pause() {
            pauseCount += 1
            isPlaying = false
        }

        func seek(to seconds: TimeInterval, precise: Bool) {
            seeks.append((seconds, precise))
            currentTime = seconds
        }

        func invalidate() {}
    }

    private func makeViewModel(duration: TimeInterval = 0,
                               currentTime: TimeInterval = 0,
                               isPlaying: Bool = false) -> (PlayerViewModel, StubPlayerEngine) {
        let engine = StubPlayerEngine()
        engine.duration = duration
        engine.currentTime = currentTime
        engine.isPlaying = isPlaying
        // URL 无需真实存在：activate() 的 security scope 恒返回 false（无害），
        // 缩略图请求对不存在的文件静默失败（降级为纯时间气泡）。
        let vm = PlayerViewModel(engine: engine, url: URL(fileURLWithPath: "/tmp/cq-player-tests-nonexistent.mp4"))
        vm.activate()
        return (vm, engine)
    }

    // MARK: 进度条拖动

    func testScrubSeeksOnlyOnEndWithZeroToleranceAndRestoresMute() {
        let (vm, engine) = makeViewModel(duration: 100, currentTime: 20, isPlaying: true)

        vm.beginScrub()
        XCTAssertTrue(vm.isScrubbing, "拖动中应处于 scrub 状态")
        XCTAssertTrue(engine.isMuted, "拖动中应静音（防花栗鼠声）")
        XCTAssertEqual(engine.pauseCount, 1, "拖动预览期间应暂停推进")
        XCTAssertEqual(vm.scrubPosition, 20, accuracy: 0.001, "拖动起点 = 当前时刻")

        vm.updateScrub(toFraction: 0.5)
        vm.updateScrub(toFraction: 0.7)
        XCTAssertEqual(engine.seeks.count, 0, "拖动过程中不得触发 seek（SPEC §3）")
        XCTAssertEqual(vm.scrubPosition, 70, accuracy: 0.001)

        vm.endScrub()
        XCTAssertFalse(vm.isScrubbing)
        XCTAssertEqual(engine.seeks.count, 1, "松手恰好一次 seek")
        XCTAssertEqual(engine.seeks.first?.target ?? -1, 70, accuracy: 0.001)
        XCTAssertEqual(engine.seeks.first?.precise ?? false, true, "松手必须零容差（帧精确）seek")
        XCTAssertFalse(engine.isMuted, "松手恢复拖动前的静音状态")
        XCTAssertEqual(engine.playCount, 1, "拖动前在播 → 松手恢复播放")
    }

    func testSkipClampsToDurationBounds() {
        let (vm, engine) = makeViewModel(duration: 30, currentTime: 28)

        vm.skip(relative: 10)
        XCTAssertEqual(engine.seeks.first?.target ?? -1, 30, accuracy: 0.001, "快进越界钳制到片尾")
        XCTAssertEqual(vm.feedback, "快进 10 秒")

        vm.skip(relative: -50)
        let backTarget = engine.seeks.last?.target ?? -1
        XCTAssertEqual(backTarget, 0, accuracy: 0.001, "快退越界钳制到片头")
        XCTAssertEqual(vm.feedback, "快退 10 秒")

        // 已在边界再往同方向跳 = 无动作无反馈
        let seekCount = engine.seeks.count
        vm.skip(relative: -10)
        XCTAssertEqual(engine.seeks.count, seekCount, "边界上不做无效 seek")
        XCTAssertNil(vm.feedback)
    }

    func testJumpFractionClamps() {
        let (vm, engine) = makeViewModel(duration: 200)
        vm.jump(toFraction: 1.5)
        XCTAssertEqual(engine.seeks.first?.target ?? -1, 200, accuracy: 0.001, "百分比跳转钳制到 [0,1]")
        vm.jump(toFraction: 0.25)
        XCTAssertEqual(engine.seeks.last?.target ?? -1, 50, accuracy: 0.001)
    }

    // MARK: 倍速与步进

    func testRatePassesThroughToEngine() {
        let (vm, engine) = makeViewModel()
        vm.rate = 1.5
        XCTAssertEqual(engine.rate, 1.5, "倍速必须透传引擎")
        vm.rate = 0.5
        XCTAssertEqual(engine.rate, 0.5)
    }

    func testFrameStepUsesEngineFrameDuration() {
        let (vm, engine) = makeViewModel(currentTime: 1.0)
        engine.frameDuration = 1.0 / 25.0
        vm.stepFrames(1)
        XCTAssertEqual(engine.seeks.first?.target ?? -1, 1.04, accuracy: 0.0001, "逐帧步进按引擎帧时长")
        XCTAssertEqual(engine.seeks.first?.precise ?? false, true, "逐帧必须零容差")
        vm.stepFrames(-1)
        XCTAssertEqual(engine.seeks.last?.target ?? -1, 1.0, accuracy: 0.0001, "后退一帧")
    }

    // MARK: 播完与失败

    func testNaturalEndStopsPlaybackAndKeepsControlsVisible() {
        let (vm, engine) = makeViewModel(duration: 120, currentTime: 119, isPlaying: true)

        engine.onEnded?()
        XCTAssertFalse(vm.isPlaying, "播完自动停止（不循环）")
        XCTAssertEqual(engine.pauseCount, 1)
        XCTAssertEqual(vm.currentTime, 120, accuracy: 0.001, "时刻停在片尾")
        XCTAssertTrue(vm.showsControls, "播完常显控制层")
    }

    func testEngineFailureSurfacesStateAndKeepsControlsVisible() {
        let (vm, engine) = makeViewModel()
        vm.toggleControls()
        XCTAssertFalse(vm.showsControls)

        // 经 VM 在 init 里接线的真实回调通道触发（同引擎失败路径）
        engine.onStateChange?(.failed("不支持的容器格式"))

        if case .failed(let message) = vm.state {
            XCTAssertEqual(message, "不支持的容器格式", "失败信息原样上抛给 UI")
        } else {
            XCTFail("引擎失败必须反映到 vm.state")
        }
        XCTAssertTrue(vm.showsControls, "失败时保持控制层可见（横幅 + 重试）")
    }

    // MARK: 纯函数

    func testClockFormatting() {
        XCTAssertEqual(PlayerTimeFormat.clock(0), "00:00")
        XCTAssertEqual(PlayerTimeFormat.clock(59.5), "00:59", "秒向下取整")
        XCTAssertEqual(PlayerTimeFormat.clock(61), "01:01")
        XCTAssertEqual(PlayerTimeFormat.clock(3671), "01:01:11", "≥1h 进位到时:分:秒")
        XCTAssertEqual(PlayerTimeFormat.clock(-3), "00:00", "负值防御")
        XCTAssertEqual(PlayerTimeFormat.clock(.infinity), "00:00", "非法值防御")
    }
}
