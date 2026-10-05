// SharedUI — 独立播放器 MVP 内核实现：AVPlayer（UIA-015；ADR-0022）
//
// 过渡实现（非终态）：解码/音频线程全部属于 AVPlayer，本类只做装配与
// 状态转发。零容差 seek（precise）给进度条落点与逐帧步进；关键帧容差
// seek 给双击快进快退（快 > 准）。
//
// Swift 6 并发注意（P49：本文件在 macOS swift test 下不触碰 iOS 分支，
// 平台分支见 PlayerSurfaceView / PlayerViewModel）：
//   * KVO 与 NotificationCenter 回调发生在任意线程 —— 一律 Task { @MainActor }
//     跳回主隔离域（手法同 AppEntry.applySnapshot）。
//   * 定时观察者用 .main queue，但 block 本身不被 Swift 6 认作 MainActor ——
//     同样跳一次。
//
// ⚠️ 起播延迟优化（RESEARCH-006 §3.4）：本地文件关掉
//    automaticallyWaitsToMinimizeStalling；asset/item 在 load 时一次性建好。

import AVFoundation
import Foundation
import os

@MainActor
final class AVPlayerEngine: PlayerEngine {

    // MARK: 状态

    private(set) var state: PlayerEngineState = .idle
    private(set) var duration: TimeInterval = 0
    private(set) var videoSize: CGSize?
    private(set) var frameDuration: TimeInterval = 1.0 / 30.0
    private(set) var isRemoteSource = false
    private(set) var audioTracks: [PlayerTrackOption] = []
    private(set) var currentAudioTrackID: Int?
    private(set) var subtitleTracks: [PlayerTrackOption] = []
    private(set) var currentSubtitleTrackID: Int?
    /// 选择组的引擎侧持有（select 时按 id 取回 option）。
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?

    /// 画面 sink 绑定用（ADR-0022 已登记的 MVP 类型耦合点：仅
    /// PlayerScreen 的 `as? AVPlayerEngine` 分支使用，不得扩散）。
    private(set) var avPlayer: AVPlayer

    var rate: Double = 1.0 {
        didSet {
            guard oldValue != rate else { return }
            // defaultRate（iOS 16 / macOS 13+）：play() 自动以该速率起播。
            avPlayer.defaultRate = rate
            if isPlaying { avPlayer.rate = Float(rate) }
        }
    }

    var volume: Double = 1.0 {
        didSet { avPlayer.volume = Float(volume) }
    }

    var isMuted: Bool = false {
        didSet { avPlayer.isMuted = isMuted }
    }

    var isPlaying: Bool { avPlayer.timeControlStatus == .playing || avPlayer.rate != 0 }

    // MARK: 回调

    var onTick: ((TimeInterval) -> Void)?
    var onStateChange: ((PlayerEngineState) -> Void)?
    var onEnded: (() -> Void)?
    var onPlayStateChange: ((Bool) -> Void)?
    var onBufferingChange: ((Bool) -> Void)?

    // MARK: 观察者（load 时重建，invalidate 时拆除）

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var item: AVPlayerItem?
    /// timeControlStatus 观察挂在 avPlayer（跨 load 存活），只在 init 建、deinit 拆。
    private var playbackObservation: NSKeyValueObservation?

    private let log = Logger(subsystem: "com.chuanqi.cut", category: "AVPlayerEngine")

    init() {
        let player = AVPlayer()
        // 本地文件：不等缓冲策略只会带来首帧更快（流媒体场景才需要等待）。
        player.automaticallyWaitsToMinimizeStalling = false
        self.avPlayer = player
        // 播放状态观察（挂 avPlayer，跨 load 存活，init 建 / deinit 拆）：
        // 覆盖引擎自动暂停（耳机拔出、来电中断）等外部状态变化，VM 据此同步 UI。
        self.playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let status = observed.timeControlStatus
            let playing = status != .paused
            let buffering = status == .waitingToMinimizeStalling
            Task { @MainActor [weak self] in
                self?.onPlayStateChange?(playing)
                self?.onBufferingChange?(buffering)
            }
        }
    }

    // MARK: PlayerEngine

    func load(url: URL) {
        teardownObservers()

        // 轨道元数据随新源重建（旧列表先清，防换片后闪现上一片的轨道）。
        audioTracks = []
        subtitleTracks = []
        currentAudioTrackID = nil
        currentSubtitleTrackID = nil
        audioGroup = nil
        subtitleGroup = nil

        // 源类型策略（UIA-024）：本地零等待起播；远程走系统缓冲策略。
        isRemoteSource = Self.isRemoteMediaURL(url)
        avPlayer.automaticallyWaitsToMinimizeStalling = !isRemoteSource

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // 变速保音调（语音/成片通用档；spectral 音质更高但 CPU 更贵，RESEARCH-006 §3.2）。
        item.audioTimePitchAlgorithm = .timeDomain
        self.item = item
        setState(.loading)

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            let error = observed.error
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch status {
                case .readyToPlay:
                    self.setState(.ready)
                case .failed:
                    self.setState(.failed(error.map { $0.localizedDescription } ?? "无法播放该视频"))
                case .unknown:
                    break // 初始态，等 readyToPlay/failed
                @unknown default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onEnded?() }
        }

        avPlayer.replaceCurrentItem(with: item)

        // 时长与视频元数据异步读（主线程零阻塞；失败不 fatal，靠 item.status 兜底报错）。
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let duration = try await asset.load(.duration)
                guard duration.seconds.isFinite else {
                    // 无限时长 = 直播流（范围外，PLAN-播放器进阶 §3：仅点播）
                    self.setState(.failed("暂不支持直播流，请使用点播视频地址"))
                    return
                }
                self.duration = duration.seconds
                // 元数据可能晚于 item.status=ready 到达；同值重发 = "元数据有刷新"信号。
                self.onStateChange?(self.state)
            } catch {
                self.log.error("load duration 失败: \(String(describing: error), privacy: .public)")
            }
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return }
                async let size = track.load(.naturalSize)
                async let fps = track.load(.nominalFrameRate)
                let naturalSize = try await size
                let frameRate = try await fps
                if naturalSize.width > 0 && naturalSize.height > 0 {
                    self.videoSize = CGSize(width: naturalSize.width, height: naturalSize.height)
                }
                if frameRate > 0 {
                    self.frameDuration = 1.0 / Double(frameRate)
                }
            } catch {
                self.log.error("load video metadata 失败: \(String(describing: error), privacy: .public)")
            }
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                async let audible = asset.loadMediaSelectionGroup(for: .audible)
                async let legible = asset.loadMediaSelectionGroup(for: .legible)
                let audibleGroup = try await audible
                let legibleGroup = try await legible
                self.audioGroup = audibleGroup
                self.subtitleGroup = legibleGroup
                self.audioTracks = Self.trackOptions(from: audibleGroup)
                self.subtitleTracks = Self.trackOptions(from: legibleGroup)
                let current = self.item?.currentMediaSelection
                self.currentAudioTrackID = Self.optionID(current?.audioMediaSelectionOption, in: audibleGroup)
                self.currentSubtitleTrackID = Self.optionID(current?.legibleMediaSelectionOption, in: legibleGroup)
                // 同值重发 = "轨道元数据有刷新"信号（与时长广播同机制）。
                self.onStateChange?(self.state)
            } catch {
                self.log.error("load media selection 失败: \(String(describing: error), privacy: .public)")
            }
        }

        // 周期时刻回调（0.25s 粒度：进度条平滑下限，UI 发布再由 VM 去抖）。
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self = self, seconds.isFinite else { return }
                self.onTick?(seconds)
            }
        }
    }

    func play() {
        avPlayer.play()
    }

    func pause() {
        avPlayer.pause()
    }

    func seek(to seconds: TimeInterval, precise: Bool) {
        let clamped = max(0, seconds)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        if precise {
            avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            avPlayer.seek(to: time, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
        }
    }

    func selectAudioTrack(id: Int?) {
        guard let group = audioGroup else { return }
        let option = id.flatMap { id in group.options.indices.contains(id) ? group.options[id] : nil }
        item?.selectMediaOption(option, in: group)
        currentAudioTrackID = id
    }

    func selectSubtitleTrack(id: Int?) {
        guard let group = subtitleGroup else { return }
        let option = id.flatMap { id in group.options.indices.contains(id) ? group.options[id] : nil }
        item?.selectMediaOption(option, in: group)
        currentSubtitleTrackID = id
    }

    func invalidate() {
        teardownObservers()
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        item = nil
        setState(.idle)
    }

    #if os(iOS)
    /// 后台播放 / 画中画前置：激活音频会话（category .playback）。
    /// 失败只降级（后台无声 / PiP 不可用），不阻塞播放。
    func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("音频会话激活失败: \(String(describing: error), privacy: .public)")
        }
    }
    #endif

    // MARK: 内部

    /// 源类型判定（UIA-024 纯函数）：仅 http/https 视为远程。
    static func isRemoteMediaURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// 组 → UI 条目（displayName 空串回退"轨道 N"；id = 组内下标）。
    private static func trackOptions(from group: AVMediaSelectionGroup?) -> [PlayerTrackOption] {
        guard let group = group else { return [] }
        return group.options.enumerated().map { index, option in
            let name = option.displayName.isEmpty ? "轨道 \(index + 1)" : option.displayName
            return PlayerTrackOption(id: index, name: name)
        }
    }

    private static func optionID(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup?) -> Int? {
        guard let option = option, let group = group else { return nil }
        return group.options.firstIndex { $0 === option }
    }

    private func setState(_ newState: PlayerEngineState) {
        if newState == state && newState != .loading { return }
        state = newState
        onStateChange?(newState)
    }

    private func teardownObservers() {
        if let timeObserver = timeObserver {
            avPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    /// 进程退出前的最后清理（onDisappear 之外兜底；不调 MainActor 方法）。
    deinit {
        if let timeObserver = timeObserver {
            avPlayer.removeTimeObserver(timeObserver)
        }
        statusObservation?.invalidate()
        playbackObservation?.invalidate()
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }
}
