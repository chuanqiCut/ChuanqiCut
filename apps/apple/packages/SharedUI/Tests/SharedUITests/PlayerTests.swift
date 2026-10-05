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
        var audioTracks: [PlayerTrackOption] = [
            PlayerTrackOption(id: 0, name: "国语"),
            PlayerTrackOption(id: 1, name: "粤语"),
        ]
        var currentAudioTrackID: Int?
        var subtitleTracks: [PlayerTrackOption] = []
        var currentSubtitleTrackID: Int?
        private(set) var selectedAudioID: Int?
        private(set) var selectedSubtitleID: Int?

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

        func selectAudioTrack(id: Int?) {
            selectedAudioID = id
            currentAudioTrackID = id
        }

        func selectSubtitleTrack(id: Int?) {
            selectedSubtitleID = id
            currentSubtitleTrackID = id
        }
    }

    private func makeViewModel(duration: TimeInterval = 0,
                               currentTime: TimeInterval = 0,
                               isPlaying: Bool = false,
                               defaults: UserDefaults? = nil) -> (PlayerViewModel, StubPlayerEngine) {
        let engine = StubPlayerEngine()
        engine.duration = duration
        engine.currentTime = currentTime
        engine.isPlaying = isPlaying
        // URL 无需真实存在：activate() 的 security scope 恒返回 false（无害），
        // 缩略图请求对不存在的文件静默失败（降级为纯时间气泡）。
        let url = URL(fileURLWithPath: "/tmp/cq-player-tests-nonexistent.mp4")
        let vm: PlayerViewModel
        if let defaults = defaults {
            vm = PlayerViewModel(engine: engine, url: url, defaults: defaults)
        } else {
            vm = PlayerViewModel(engine: engine, url: url)
        }
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

    // MARK: 长按倍速

    func testSpeedBoostRestoresPreviousRate() {
        let (vm, engine) = makeViewModel(isPlaying: true)
        vm.rate = 1.25

        vm.beginSpeedBoost()
        XCTAssertTrue(vm.isBoosting, "长按期间处于倍速冲刺状态")
        XCTAssertEqual(engine.rate, 2.0, "长按倍速 = 2x")
        vm.beginSpeedBoost()
        XCTAssertEqual(vm.rate, 2.0, "重复长按无副作用")

        vm.endSpeedBoost()
        XCTAssertFalse(vm.isBoosting)
        XCTAssertEqual(engine.rate, 1.25, "松手恢复原速率")
        XCTAssertEqual(vm.rate, 1.25)
    }

    // MARK: 循环

    func testLoopRestartsFromBeginningOnEnd() {
        let (vm, engine) = makeViewModel(duration: 60, currentTime: 59.8, isPlaying: true)
        vm.toggleLoop()
        XCTAssertTrue(vm.loopEnabled)

        engine.onEnded?()
        XCTAssertEqual(engine.seeks.first?.target ?? -1, 0, accuracy: 0.001, "单片循环：播完回零")
        XCTAssertEqual(engine.playCount, 1, "循环时播完续播而非停止")
        XCTAssertTrue(vm.isPlaying)
    }

    func testABLoopSeeksBackWhenCrossingEnd() {
        let (vm, engine) = makeViewModel(duration: 120, isPlaying: true)

        engine.onTick?(10)
        vm.cycleABLoop()
        XCTAssertEqual(vm.abLoopState, .aSet, "第一次点按 = 设起点 A")

        engine.onTick?(30)
        vm.cycleABLoop()
        XCTAssertEqual(vm.abLoopState, .looping, "第二次点按 = 设终点并开启")
        XCTAssertEqual(vm.abStart, 10, accuracy: 0.001)
        XCTAssertEqual(vm.abEnd, 30, accuracy: 0.001)

        engine.onTick?(30.5)
        XCTAssertEqual(engine.seeks.first?.target ?? -1, 10, accuracy: 0.001, "越过 B 点跳回 A")
        XCTAssertEqual(engine.seeks.first?.precise ?? false, true, "回跳零容差")
    }

    func testABLoopTooShortCancels() {
        let (vm, _) = makeViewModel(duration: 120)
        engineTickThenSetA(vm, at: 10)
        engineOnTick(vm, 10.3)
        vm.cycleABLoop()
        XCTAssertEqual(vm.abLoopState, .off, "区间 < 1s 视为误触取消")
    }

    func testManualSeekOutsideABClearsLoop() {
        let (vm, _) = makeViewModel(duration: 120, isPlaying: true)
        engineTickThenSetA(vm, at: 10)
        engineOnTick(vm, 30)
        vm.cycleABLoop()
        XCTAssertEqual(vm.abLoopState, .looping)

        vm.skip(relative: 100)
        XCTAssertEqual(vm.abLoopState, .off, "手动 seek 跳出区间应清除 A-B 循环")
    }

    // MARK: 倍速记忆

    func testRatePersistsAcrossInstances() {
        let suiteName = "PlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (vm1, _) = makeViewModel(defaults: defaults)
        vm1.rate = 1.5
        XCTAssertEqual(defaults.double(forKey: PlayerViewModel.rateDefaultsKey), 1.5, "倍速变更写入 UserDefaults")

        let (vm2, engine2) = makeViewModel(defaults: defaults)
        XCTAssertEqual(vm2.rate, 1.5, "新实例从 UserDefaults 恢复倍速")
        XCTAssertEqual(engine2.rate, 1.5, "恢复的倍速同步引擎")
    }

    // MARK: 换片

    func testSwapMediaResetsPlaybackStateAndKeepsLoopToggle() {
        let (vm, engine) = makeViewModel(duration: 100, currentTime: 50, isPlaying: true)
        vm.toggleLoop()
        engineTickThenSetA(vm, at: 40)
        engineOnTick(vm, 60)
        vm.cycleABLoop()
        XCTAssertEqual(vm.abLoopState, .looping)

        vm.swapMedia(to: URL(fileURLWithPath: "/tmp/cq-player-tests-other.mp4"))
        XCTAssertEqual(engine.loadCalls.count, 2, "换片重新装载")
        XCTAssertEqual(vm.duration, 0, accuracy: 0.001, "换片清零时长")
        XCTAssertEqual(vm.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(vm.abLoopState, .off, "换片清除 A-B 循环")
        XCTAssertTrue(vm.loopEnabled, "循环开关跨片保留")
        XCTAssertEqual(vm.state, .loading)
    }

    // MARK: 音轨 / 字幕

    func testTrackListingSyncsFromEngineBroadcast() {
        let (vm, engine) = makeViewModel()
        XCTAssertTrue(vm.audioTracks.isEmpty, "装载前轨道列表为空")

        engine.onStateChange?(.ready)
        XCTAssertEqual(vm.audioTracks.count, 2, "轨道列表随引擎广播同步")
        XCTAssertEqual(vm.audioTracks.first?.name, "国语")
        XCTAssertNil(vm.currentAudioTrackID, "默认轨道 = nil")

        engine.subtitleTracks = [PlayerTrackOption(id: 0, name: "中文")]
        engine.onStateChange?(.ready)
        XCTAssertEqual(vm.subtitleTracks.count, 1, "字幕轨列表同步")
    }

    func testTrackSelectionPassesThroughToEngine() {
        let (vm, engine) = makeViewModel()
        vm.selectAudioTrack(id: 1)
        XCTAssertEqual(engine.selectedAudioID, 1, "音轨选择透传引擎")
        XCTAssertEqual(vm.currentAudioTrackID, 1)

        vm.selectSubtitleTrack(id: nil)
        XCTAssertNil(engine.selectedSubtitleID, "字幕 nil = 关闭")
        XCTAssertNil(vm.currentSubtitleTrackID)
    }

    // MARK: 双击步长

    func testDoubleTapSecondsPersistAcrossInstances() {
        let suiteName = "PlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let (vm1, _) = makeViewModel(defaults: defaults)
        XCTAssertEqual(vm1.doubleTapSeconds, 10, "默认步长 10 秒")
        vm1.doubleTapSeconds = 15
        XCTAssertEqual(defaults.double(forKey: PlayerViewModel.doubleTapDefaultsKey), 15, "步长变更写入 UserDefaults")

        let (vm2, _) = makeViewModel(defaults: defaults)
        XCTAssertEqual(vm2.doubleTapSeconds, 15, "新实例恢复步长")
    }

    // MARK: tick/设 A 辅助（engine 的 onTick 是 VM 接线的唯一入口）

    private func engineOnTick(_ vm: PlayerViewModel, _ seconds: TimeInterval) {
        guard let stub = vm.engine as? StubPlayerEngine else {
            return XCTFail("注入的引擎应是 StubPlayerEngine")
        }
        stub.onTick?(seconds)
    }

    private func engineTickThenSetA(_ vm: PlayerViewModel, at seconds: TimeInterval) {
        engineOnTick(vm, seconds)
        vm.cycleABLoop()
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
