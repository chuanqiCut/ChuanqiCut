// SharedUI — 独立播放器状态机（UIA-015；SPEC-UIA-020 §4）
//
// 职责：交互编排 + 引擎回调 → @Published。本文件**不 import AVFoundation**
// （ADR-0022 域边界）：AVPlayer/AVPlayerLayer 等平台媒体类型只以"不点名的
// 不透明值"穿过（Swift 允许传递未在本文件导入的类型值，只要不写出类型名）；
// 引擎实现 AVPlayerEngine 是本模块自有类型，可直接点名。
//
// 线程模型：全部 @MainActor。异步只有 Task.sleep（自动隐藏/反馈气泡）与
// 引擎内部回调（引擎负责跳回主隔离域）。
//
// 交互语义（RESEARCH-006 §3）：
//   * 拖动进度条 = 暂停 + 静音预览，松手零容差 seek 后恢复（防花栗鼠声）；
//   * 播放中 4s 无交互自动隐藏控制层，暂停时常显；
//   * 播完自然停止（不自动循环），再按播放从头开始。

import CoreGraphics
import Foundation
import SwiftUI
import os
#if os(iOS)
import UIKit
#endif

@MainActor
final class PlayerViewModel: ObservableObject {

    // MARK: UI 状态（只读）

    @Published private(set) var state: PlayerEngineState = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var videoSize: CGSize?
    @Published private(set) var volume: Double = 1.0
    @Published private(set) var isMuted = false
    /// 进度条拖动中（UI 显示 scrubPosition 而非 currentTime）。
    @Published private(set) var isScrubbing = false
    @Published private(set) var scrubPosition: TimeInterval = 0
    /// 当前拖动时刻的缩略图（nil = 未命中且未生成完，降级为纯时间气泡）。
    @Published private(set) var scrubThumbnail: CGImage?
    @Published private(set) var showsControls = true
    /// iOS 全屏展开（忽略安全区 + 横屏视频请求转横屏）。
    @Published private(set) var isExpanded = false
    /// 画面填充模式：false = 适合（aspect fit），true = 填充（aspect fill）。
    @Published private(set) var isAspectFill = false
    /// 短暂操作反馈（"快进 10 秒"等），约 0.9s 自动清除。
    @Published private(set) var feedback: String?
    /// 画中画可用性（iOS；KVO isPictureInPicturePossible 驱动）。
    @Published private(set) var isPipPossible = false

    /// 播放速率（1.0 = 原速）。didSet 直接透传引擎。
    @Published var rate: Double = 1.0 {
        didSet { engine.rate = rate }
    }

    /// 顶栏标题（文件名）。
    var mediaTitle: String { url.lastPathComponent }

    /// 控制层显示的时刻：拖动中显示拖动预览位置，否则显示实际播放时刻。
    var displaySeconds: TimeInterval { isScrubbing ? scrubPosition : currentTime }

    // MARK: 依赖

    let engine: PlayerEngine
    /// PiP 协调器（iOS；macOS 上不会被 attach）。由 PlayerScreen 在画面
    /// layer 就绪时接入——layer 类型在本文件不点名（域边界，见文件头）。
    let pip = PlayerPipCoordinator()
    private let thumbnails: VideoThumbnailLoader?
    private let url: URL

    // MARK: 内部状态

    private var activated = false
    private var securityScopeActive = false
    private var wasMutedBeforeScrub = false
    private var wasPlayingBeforeScrub = false
    private var hideTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    private let log = Logger(subsystem: "com.chuanqi.cut", category: "PlayerViewModel")

    /// 播放中无交互自动隐藏控制层的时延。
    static let controlsAutoHideNanos: UInt64 = 4_000_000_000

    // MARK: 初始化

    init(engine: PlayerEngine, url: URL) {
        self.engine = engine
        self.url = url
        // 文件不存在/打不开时缩略图请求静默失败（回调 image=nil），
        // 控制层降级为纯时间气泡，无需前置存在性检查。
        self.thumbnails = VideoThumbnailLoader(url: url)

        engine.onTick = { [weak self] seconds in self?.engineDidTick(seconds) }
        engine.onStateChange = { [weak self] newState in self?.engineDidChangeState(newState) }
        engine.onEnded = { [weak self] in self?.engineDidEnd() }
        engine.onPlayStateChange = { [weak self] playing in self?.enginePlayStateDidChange(playing) }
        thumbnails?.onUpdate = { [weak self] bucket, image in
            guard let self = self else { return }
            // 只接受"仍停留在当前桶"的结果，防慢请求覆盖新位置的气泡。
            if bucket == Int(self.scrubPosition.rounded(.down)) {
                self.scrubThumbnail = image
            }
        }
        pip.onPossibleChange = { [weak self] possible in self?.isPipPossible = possible }
    }

    convenience init(url: URL) {
        self.init(engine: AVPlayerEngine(), url: url)
    }

    // MARK: 生命周期

    /// 装载并准备播放（onAppear 调用一次；重复调用无副作用）。
    func activate() {
        guard !activated else { return }
        activated = true
        // fileImporter 产出的 URL 需要 security scope 才能读（macOS 恒返回 false，无害）。
        securityScopeActive = url.startAccessingSecurityScopedResource()
        engine.load(url: url)
        activateAudioSessionIfNeeded()
    }

    /// 拆除观察者/任务/scope（onDisappear 调用）。
    func deactivate() {
        engine.invalidate()
        pip.invalidate()
        thumbnails?.invalidate()
        cancelHide()
        feedbackTask?.cancel()
        feedbackTask = nil
        if securityScopeActive {
            url.stopAccessingSecurityScopedResource()
            securityScopeActive = false
        }
        setIdleTimerDisabled(false)
    }

    /// 失败横幅的重试入口（重新装载同一 URL）。
    func retry() {
        state = .loading
        engine.load(url: url)
    }

    // MARK: 播放控制

    func togglePlay() {
        if engine.isPlaying {
            engine.pause()
        } else {
            // 播完后再按播放 = 从头开始。
            if engine.duration > 0, engine.currentTime >= engine.duration - engine.frameDuration / 2 {
                engine.seek(to: 0, precise: false)
            }
            engine.play()
        }
        isPlaying = engine.isPlaying
        if isPlaying {
            keepControlsVisible()
        } else {
            showsControls = true
            cancelHide()
        }
        setIdleTimerDisabled(isPlaying)
    }

    /// 相对跳转（双击 ±10s / VoiceOver 扫动）。目标钳制到 [0, duration]。
    func skip(relative seconds: TimeInterval) {
        let target = min(max(engine.currentTime + seconds, 0), engine.duration)
        guard target != currentTime else { return } // 已在边界，无动作无反馈
        engine.seek(to: target, precise: false)
        currentTime = target
        let magnitude = Int(abs(seconds).rounded())
        showFeedback(seconds < 0 ? "快退 \(magnitude) 秒" : "快进 \(magnitude) 秒")
        keepControlsVisible()
    }

    /// 键盘 0-9：按总时长百分比跳转。
    func jump(toFraction fraction: Double) {
        guard engine.duration > 0 else { return }
        let target = min(max(fraction, 0), 1) * engine.duration
        engine.seek(to: target, precise: false)
        currentTime = target
        keepControlsVisible()
    }

    /// 键盘 ，/. 逐帧步进（负数 = 后退）。
    func stepFrames(_ count: Int) {
        let target = engine.currentTime + Double(count) * engine.frameDuration
        engine.seek(to: target, precise: true)
        currentTime = min(max(target, 0), engine.duration)
        keepControlsVisible()
    }

    func setVolume(_ newValue: Double) {
        let clamped = min(max(newValue, 0), 1)
        guard clamped != volume else { return }
        volume = clamped
        engine.volume = clamped
    }

    func toggleMute() {
        isMuted.toggle()
        engine.isMuted = isMuted
    }

    func setAspectFill(_ fill: Bool) {
        isAspectFill = fill
    }

    // MARK: 进度条拖动（SPEC-UIA-020 §3：拖动只改 UI，松手才 seek）

    func beginScrub() {
        guard !isScrubbing else { return }
        isScrubbing = true
        wasMutedBeforeScrub = engine.isMuted
        wasPlayingBeforeScrub = engine.isPlaying
        engine.pause()            // 拖动预览期间停止推进
        engine.isMuted = true     // 防 seek 中的音调异常声（RESEARCH-006 §3.2）
        scrubPosition = engine.currentTime
        scrubThumbnail = thumbnails?.cachedThumbnail(atSecond: scrubPosition)
        hideTask?.cancel()
    }

    func updateScrub(toFraction fraction: Double) {
        guard isScrubbing else { return }
        scrubPosition = min(max(fraction, 0), 1) * engine.duration
        requestScrubThumbnail()
    }

    func endScrub() {
        guard isScrubbing else { return }
        engine.seek(to: scrubPosition, precise: true)
        engine.isMuted = wasMutedBeforeScrub
        if wasPlayingBeforeScrub {
            engine.play()
        }
        isScrubbing = false
        keepControlsVisible()
    }

    // MARK: 控制层显隐

    func toggleControls() {
        if showsControls {
            showsControls = false
            cancelHide()
        } else {
            keepControlsVisible()
        }
    }

    func keepControlsVisible() {
        showsControls = true
        scheduleHide()
    }

    // MARK: 全屏（iOS）

    #if os(iOS)
    /// 展开/收起全屏。横屏视频展开时请求系统转横屏（iOS 16 几何请求）。
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        guard let size = videoSize else { return }
        // MVP 简化：进入横屏只发生在"横屏视频 + 展开"；收起一律回竖屏，
        // 不记忆进入前的设备方向（若用户本就横持，回竖屏是可见的 MVP 取舍）。
        let orientation: UIInterfaceOrientationMask =
            (expanded && size.width > size.height) ? .landscapeRight : .portrait
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { error in
                // 转屏被拒（iPad 分屏等）不致命：画面仍以忽略安全区布局铺满。
                Self.geometryLog.error("转屏请求被拒: \(String(describing: error), privacy: .public)")
            }
        }
    }
    private static let geometryLog = Logger(subsystem: "com.chuanqi.cut", category: "PlayerViewModel")
    #endif

    // MARK: 引擎回调

    private func engineDidTick(_ seconds: TimeInterval) {
        guard !isScrubbing else { return }
        currentTime = seconds
        // 元数据可能晚于 ready 到达，随 tick 兜底刷新（幂等）。
        duration = engine.duration
        videoSize = engine.videoSize
    }

    private func engineDidChangeState(_ newState: PlayerEngineState) {
        state = newState
        duration = engine.duration
        videoSize = engine.videoSize
        if case .failed(let message) = newState {
            log.error("播放引擎失败: \(message, privacy: .public)")
            showsControls = true
            cancelHide()
        }
    }

    private func engineDidEnd() {
        // 自然播完：停住（不自动循环），常显控制层，息屏定时器还原。
        engine.pause()
        isPlaying = false
        duration = engine.duration  // 兜底同步（元数据可能晚到）
        currentTime = duration
        showsControls = true
        cancelHide()
        setIdleTimerDisabled(false)
    }

    private func enginePlayStateDidChange(_ playing: Bool) {
        // 覆盖外部引发的暂停/恢复（耳机拔出、来电中断等 AVPlayer 自动行为）。
        isPlaying = playing
        if playing {
            keepControlsVisible()
        } else {
            showsControls = true
            cancelHide()
        }
        setIdleTimerDisabled(playing)
    }

    // MARK: 内部

    private func requestScrubThumbnail() {
        guard let thumbnails = thumbnails else { return }
        if let cached = thumbnails.cachedThumbnail(atSecond: scrubPosition) {
            scrubThumbnail = cached
            return
        }
        thumbnails.requestThumbnail(atSecond: scrubPosition)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying, !isScrubbing else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.controlsAutoHideNanos)
            guard !Task.isCancelled else { return }
            guard let self = self, self.isPlaying, !self.isScrubbing else { return }
            self.showsControls = false
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func showFeedback(_ text: String) {
        feedback = text
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.feedback = nil
        }
    }

    #if os(iOS)
    /// 后台播放 / 画中画前置：激活音频会话。实现挂在引擎侧（域边界：
    /// AVAudioSession 不得出现在本文件）。
    private func activateAudioSessionIfNeeded() {
        (engine as? AVPlayerEngine)?.activateAudioSession()
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        // 仅播放中防息屏；暂停/收起还原（RESEARCH-006 §3.4）。
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
    #else
    private func activateAudioSessionIfNeeded() {}
    private func setIdleTimerDisabled(_ disabled: Bool) {}
    #endif
}

// MARK: - 时间码格式化

/// mm:ss（<1h）/ h:mm:ss（≥1h）；秒向下取整：59.5s → "00:59"（SPEC §6.1）。
enum PlayerTimeFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
