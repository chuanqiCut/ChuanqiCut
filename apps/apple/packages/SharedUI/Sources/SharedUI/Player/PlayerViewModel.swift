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
    /// 单片循环（播完自动从头续播）。
    @Published private(set) var loopEnabled = false
    /// A-B 循环状态机与区间（控制层在进度条上画标记）。
    @Published private(set) var abLoopState: ABLoopState = .off
    @Published private(set) var abStart: TimeInterval = 0
    @Published private(set) var abEnd: TimeInterval = 0
    /// 长按倍速进行中（松手恢复原速率）。
    @Published private(set) var isBoosting = false

    /// 播放速率（1.0 = 原速）。didSet 透传引擎并记忆（跨会话恢复）。
    @Published var rate: Double = 1.0 {
        didSet {
            engine.rate = rate
            defaults.set(rate, forKey: Self.rateDefaultsKey)
        }
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
    private(set) var thumbnails: VideoThumbnailLoader?
    private(set) var url: URL
    /// 倍速记忆存储（测试注入独立 suite）。
    private let defaults: UserDefaults

    // MARK: 内部状态

    private var activated = false
    private var securityScopeActive = false
    private var wasMutedBeforeScrub = false
    private var wasPlayingBeforeScrub = false
    private var rateBeforeBoost: Double?
    /// 缩略图已批量预热（换片后复位）。
    private var warmedUp = false
    private var hideTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    private let log = Logger(subsystem: "com.chuanqi.cut", category: "PlayerViewModel")

    /// 播放中无交互自动隐藏控制层的时延。
    static let controlsAutoHideNanos: UInt64 = 4_000_000_000
    /// 长按倍速档位。
    static let boostRate: Double = 2.0
    /// A-B 循环最短区间（低于视为误触）。
    static let minABLoopSeconds: TimeInterval = 1.0
    /// 倍速记忆的 UserDefaults 键。
    static let rateDefaultsKey = "cq.player.rate"

    // MARK: 初始化

    init(engine: PlayerEngine, url: URL, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.url = url
        self.defaults = defaults
        // 文件不存在/打不开时缩略图请求静默失败（回调 image=nil），
        // 控制层降级为纯时间气泡，无需前置存在性检查。
        self.thumbnails = VideoThumbnailLoader(url: url)

        engine.onTick = { [weak self] seconds in self?.engineDidTick(seconds) }
        engine.onStateChange = { [weak self] newState in self?.engineDidChangeState(newState) }
        engine.onEnded = { [weak self] in self?.engineDidEnd() }
        engine.onPlayStateChange = { [weak self] playing in self?.enginePlayStateDidChange(playing) }
        rewireThumbnailHandler()
        pip.onPossibleChange = { [weak self] possible in self?.isPipPossible = possible }

        // 跨会话倍速记忆（didSet 同步引擎并原样回写，无害）
        rate = defaults.object(forKey: Self.rateDefaultsKey) as? Double ?? 1.0
    }

    /// 缩略图回调统一接线（init 与换片共用）。
    private func rewireThumbnailHandler() {
        thumbnails?.onUpdate = { [weak self] bucket, image in
            guard let self = self else { return }
            // 只接受"仍停留在当前桶"的结果，防慢请求覆盖新位置的气泡。
            if bucket == Int(self.scrubPosition.rounded(.down)) {
                self.scrubThumbnail = image
            }
        }
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
        endSpeedBoost()
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

    /// 换片：同一播放器内装载新文件（控制层"打开新视频"入口）。
    /// 循环开关与倍速记忆跨片保留；A-B 循环/播放进度/缩略图全部复位。
    func swapMedia(to newURL: URL) {
        guard newURL != url else { return }
        if securityScopeActive {
            url.stopAccessingSecurityScopedResource()
            securityScopeActive = false
        }
        url = newURL
        securityScopeActive = newURL.startAccessingSecurityScopedResource()

        thumbnails?.invalidate()
        thumbnails = VideoThumbnailLoader(url: newURL)
        rewireThumbnailHandler()

        duration = 0
        currentTime = 0
        videoSize = nil
        isPlaying = false
        isScrubbing = false
        scrubPosition = 0
        scrubThumbnail = nil
        resetABLoop()
        warmedUp = false
        state = .loading
        engine.load(url: newURL)
    }

    // MARK: 播放控制

    func togglePlay() {
        if engine.isPlaying {
            engine.pause()
        } else {
            // 播完后再按播放 = 从头开始（A-B 循环中则回到起点 A）。
            if engine.duration > 0, engine.currentTime >= engine.duration - engine.frameDuration / 2 {
                engine.seek(to: abLoopState == .looping ? abStart : 0, precise: false)
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
        clearABLoopIfOutside(target: target)
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
        clearABLoopIfOutside(target: target)
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

    // MARK: 循环与长按倍速

    func toggleLoop() {
        loopEnabled.toggle()
        showFeedback(loopEnabled ? "循环播放已开启" : "循环播放已关闭")
        keepControlsVisible()
    }

    /// A-B 循环三态轮转：设起点 → 设终点（开启）→ 关闭。区间 < 1s 视为误触取消。
    func cycleABLoop() {
        switch abLoopState {
        case .off:
            abStart = currentTime
            abLoopState = .aSet
            showFeedback("已设起点 A，再点一次设终点 B")
        case .aSet:
            abEnd = currentTime
            guard abEnd - abStart >= Self.minABLoopSeconds else {
                resetABLoop()
                showFeedback("区间不足 1 秒，已取消")
                return
            }
            abLoopState = .looping
            showFeedback("A-B 循环已开启")
        case .looping:
            resetABLoop()
            showFeedback("A-B 循环已关闭")
        }
        keepControlsVisible()
    }

    /// 长按倍速（B站/抖音范式）：按住 2x，松手恢复。仅在播放中生效。
    func beginSpeedBoost() {
        guard !isBoosting, engine.isPlaying else { return }
        isBoosting = true
        rateBeforeBoost = rate
        rate = Self.boostRate
        PickerFeedback.selectionChanged()
        keepControlsVisible()
    }

    func endSpeedBoost() {
        guard isBoosting, let restore = rateBeforeBoost else { return }
        rateBeforeBoost = nil
        isBoosting = false
        rate = restore
    }

    private func resetABLoop() {
        abLoopState = .off
        abStart = 0
        abEnd = 0
    }

    /// 手动 seek 落到 A-B 区间外 = 用户意图跳出循环，自动清除。
    private func clearABLoopIfOutside(target: TimeInterval) {
        guard abLoopState == .looping else { return }
        if target < abStart - 0.25 || target > abEnd + 0.25 {
            resetABLoop()
        }
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
        clearABLoopIfOutside(target: scrubPosition)
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
        scheduleWarmupIfNeeded()
        // A-B 循环：越过终点 B 跳回起点 A（0.25s tick 粒度）。
        if abLoopState == .looping, seconds >= abEnd {
            engine.seek(to: abStart, precise: true)
            currentTime = abStart
        }
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
        // A-B 循环中播完（终点 B ≈ 片尾）→ 回 A 续播。
        if abLoopState == .looping {
            engine.seek(to: abStart, precise: true)
            engine.play()
            return
        }
        // 单片循环：回零续播。
        if loopEnabled {
            engine.seek(to: 0, precise: true)
            engine.play()
            return
        }
        // 自然播完：停住，常显控制层，息屏定时器还原。
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

    /// 就绪后批量预热均匀分布的缩略图（拖动气泡就近命中缓存）。
    /// 短片按 5s/桶收紧，长片封顶 24 桶；错峰发起在 loader 内部。
    private func scheduleWarmupIfNeeded() {
        guard !warmedUp, engine.duration > 0 else { return }
        warmedUp = true
        let count = min(24, max(6, Int(engine.duration / 5)))
        thumbnails?.warmup(duration: engine.duration, count: count)
    }

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

// MARK: - A-B 循环状态

/// off → aSet（已设起点 A）→ looping（区间循环中）。
enum ABLoopState: Equatable {
    case off
    case aSet
    case looping
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
