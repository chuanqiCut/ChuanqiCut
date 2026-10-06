// SharedUI 测试支撑 — Stub 播放引擎与 VM 构造助手（UIA-015 起共用）
//
// StubPlayerEngine 从 PlayerTests 抽出（UIA-022 起多测试类共用）：
// 记录调用、不碰 AVFoundation，断言的是控制语义而非 AVPlayer 行为。
// makePlayerViewModel 统一构造（URL 指向不存在的文件：scope 恒 false 无害，
// 缩略图静默失败降级为纯时间气泡）。

import CoreGraphics
import XCTest
@testable import SharedUI

@MainActor
final class StubPlayerEngine: PlayerEngine {
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
    var isRemoteSource = false
    var chapters: [PlayerChapter] = []
    private(set) var selectedAudioID: Int?
    private(set) var selectedSubtitleID: Int?

    var onTick: ((TimeInterval) -> Void)?
    var onStateChange: ((PlayerEngineState) -> Void)?
    var onEnded: (() -> Void)?
    var onPlayStateChange: ((Bool) -> Void)?
    var onBufferingChange: ((Bool) -> Void)?

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

    func selectAudioTrack(id: Int?) {
        selectedAudioID = id
        currentAudioTrackID = id
    }

    func selectSubtitleTrack(id: Int?) {
        selectedSubtitleID = id
        currentSubtitleTrackID = id
    }

    func invalidate() {}
}

/// 统一 VM 构造（PlayerTests / PlayerQueueTests 共用）。
@MainActor
func makePlayerViewModel(duration: TimeInterval = 0,
                         currentTime: TimeInterval = 0,
                         isPlaying: Bool = false,
                         defaults: UserDefaults? = nil,
                         recent: PlayerRecentStore? = nil) -> (PlayerViewModel, StubPlayerEngine) {
    let engine = StubPlayerEngine()
    engine.duration = duration
    engine.currentTime = currentTime
    engine.isPlaying = isPlaying
    let url = URL(fileURLWithPath: "/tmp/cq-player-tests-nonexistent.mp4")
    let vm = PlayerViewModel(engine: engine, url: url,
                             defaults: defaults ?? .standard, recent: recent)
    vm.activate()
    return (vm, engine)
}
