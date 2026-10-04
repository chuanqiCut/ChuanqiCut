// SharedUI — App 入口支撑：EditorViewModel（UIA-002）
//
// 架构铁律（ARCH-005 §3）：UI 不得直接改模型 —— 一切变更走 `submit()`（Command），
// 状态通过快照 observer 回流。本类是 UI 与内核会话之间的唯一通道。
//
// 线程模型：
//   - 本类 @MainActor：所有 @Published 状态只在主线程读写。
//   - 内核在 session 线程执行 mutate、回调 observer；绑定层已把 observer
//     转发到 main queue，但 Swift 6 并发模型不认识 "main queue == MainActor"，
//     故这里再用 `Task { @MainActor }` 跳一次（见 Session.swift 注释）。
//   - `submit()` 非阻塞（内核投递到 session 线程后立刻返回），主线程零阻塞。

import SwiftUI
import Foundation
import ChuanqiCut

// MARK: - 错误

public enum EditorError: Error, Sendable {
    /// 内核会话创建失败（静态库未链接 / session 线程启动失败）。
    case sessionCreationFailed
}

// MARK: - 视图模型

@MainActor
public final class EditorViewModel: ObservableObject {

    // MARK: 状态（UI 只读）

    /// 当前内核快照。版本号单调递增；digest 在 MODEL-001 落地前恒为 0。
    @Published public private(set) var snapshot: Snapshot

    /// 最近一次快照推进所包含的变更记录（UI 可据此增量刷新）。
    @Published public private(set) var lastChanges: [ChangeRecord] = []

    /// 内核能力（预览区 / 导出 UI 可据此决定降级展示）。
    @Published public private(set) var capabilities: [Capability: CapabilityValue] = [:]

    /// 预览门面（BIND-003 子步骤 6）。nil = 内核预览后端缺失（链接不到 PAL
    /// 图形 / 解码后端），预览区据此**运行时**降级展示（红线 #3，不用编译期判断）。
    public private(set) var preview: Previewer?

    /// 取帧泵（UIA-010 子步骤 5）：取帧/渲染在泵线程，主线程只 blit + present。
    /// nil = 预览后端缺失（与 preview 同进退）。
    ///
    /// ⚠️ 生命周期：泵持有指向渲染器的非拥有指针，故属性顺序上它在 preview 之后
    ///    声明 —— 但 Swift 的 deinit 顺序不受声明顺序保证，故两者都由本对象强持有，
    ///    且 Pump 内部强持有 Previewer（见 PreviewPump.swift），销毁顺序由此确定。
    public private(set) var previewPump: PreviewPump?

    /// 播放头。预览视图按需渲染该时刻的画面（有理数时间，红线 #4）。
    @Published public private(set) var playhead: RationalTime = RationalTime(
        value: 0, timescale: RationalTime.projectTimescale)

    /// 时间线显示状态（UIA-004）。快照每次推进后从内核重新查询
    /// （读已发布快照，不阻塞；查询在主线程执行，量级微秒）。
    @Published public private(set) var timeline: TimelineState = TimelineState()

    /// 撤销 / 重做是否可用（UIA-005）。读的是内核原子标志（同步、不阻塞），
    /// 每次快照推进后刷新 —— UI 据此置灰按钮。
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false

    /// 是否正在播放（UIA-010）。
    @Published public private(set) var isPlaying = false

    /// 素材库显示状态（UIA-009 子步骤 3）：内核素材表 + 本地存活标记。
    /// `exists == false` = 文件已不在原路径（D3：MVP 引用原路径，不拷贝入库）。
    public struct LibraryAsset: Identifiable, Equatable {
        public let id: UInt64           // = asset_id
        public let path: String
        public let pathTruncated: Bool
        public let exists: Bool
    }
    @Published public private(set) var mediaLibrary: [LibraryAsset] = []

    /// 下一个分配的素材 id（素材 id 由调用方分配，内核不生成）。
    private var nextAssetId: UInt64 = 1
    /// 导入期间的去重锁位（导入是用户动作，同屏不会并发；防连点）。
    private var importInFlight = false

    // MARK: 内核会话

    private let session: Session
    private var knownVersion: UInt64

    /// 播放时钟（UIA-010）。只算时间，不取帧不渲染（渲染走 `preview`）。
    private let player: Player?
    /// 播放驱动定时器（主线程）。**MVP 实现**：定时器推 playhead → MTKView 按需
    /// 渲染，解码与渲染都在主线程。帧率受解码速度限制（未实测），
    /// 把取帧/渲染挪到播放线程是下一步（见任务卡「剩余风险」）。
    private var playbackTimer: Timer?
    /// 定时器节拍计数（用于把「取帧请求」与「UI 发布」分成两个频率）。
    private var tickCount = 0

    public init() throws {
        guard let session = Session() else {
            throw EditorError.sessionCreationFailed
        }
        self.session = session
        self.snapshot = session.currentSnapshot
        self.knownVersion = session.currentSnapshot.version
        // UIA-009 子步骤 2 收口后预览挂 session 快照（单一真源），并强持有 session。
        self.preview = Previewer(session: session, width: 1280, height: 720)
        // UIA-012：非画布比例的素材按 contain 适配（letterbox），不再拉伸变形。
        // 内核默认仍是 stretch（既有行为/断言兼容），产品装配在此显式选择。
        _ = self.preview?.setFitMode(.contain)
        // UIA-010 子步骤 5：取帧泵（把 seek+解码+导入+离屏绘制搬离主线程）。
        // 预览后端缺失时 preview 为 nil，泵也随之不可建 —— 预览区据此走降级展示。
        self.previewPump = self.preview.flatMap { PreviewPump(preview: $0) }
        // UIA-010：播放时钟（纯计算对象，内核侧无后端依赖）。
        self.player = Player()
        // 版本 0 不触发 observer 回流，初始时间线状态主动查一次。
        refreshTimeline()
        refreshHistoryFlags()

        // 订阅快照变更：内核 session 线程 → 绑定层 main queue → 本处 MainActor。
        session.setSnapshotObserver { [weak self] snap in
            Task { @MainActor [weak self] in
                self?.applySnapshot(snap)
            }
        }
    }

    // MARK: 命令提交（UI → 内核的唯一写入口）

    /// 提交一次变更。不阻塞调用线程。
    ///
    /// - Parameter changeName: **字符串字面量**（内核只存指针不拷贝）。
    @discardableResult
    public func submit(_ changeName: StaticString, mutate: @escaping () -> Status) -> Status {
        session.submit(changeName, mutate: mutate)
    }

    /// 查询内核能力并缓存到 `capabilities`（App 启动时调用一次）。
    public func refreshCapabilities() {
        var result: [Capability: CapabilityValue] = [:]
        for capability in allCapabilities {
            result[capability] = ChuanqiCut.queryCapability(capability)
        }
        capabilities = result
    }

    // MARK: 播放（UIA-010）

    /// 播放 / 暂停切换。播放前同步一次边界（时间线可能刚变）。
    ///
    /// 驱动方式（UIA-010 子步骤 5）：`Timer` 推进时刻 → 时刻喂给**取帧泵**
    /// （后台线程完成 seek + 解码 + 导入 + 离屏绘制）→ 主线程只把已完成的帧
    /// 拷进 drawable 并 present。
    ///
    /// ⚠️ 帧率上限仍是 1/单帧取帧耗时（实测见 .ai/memory/baselines.md）：
    ///    挪线程换来的是**主线程不再被每帧堵住**，不是"播放变快"。
    ///    泵跟不上请求速率就丢帧 —— 时刻由墙钟算，丢帧不会让播放变快或变慢。
    public func togglePlayback() {
        guard let player else { return }
        // 无片段 = 没有可播内容（UI 按钮同样置灰）。播空时间线没有意义，
        // 且边界为 0 会让时钟立刻判定"播完"。
        guard !timeline.clips.isEmpty else { return }
        if isPlaying {
            player.pause()
            stopPlaybackLoop()
            isPlaying = false
            return
        }
        // 边界由内核时间线算（UI 不自己累加片段）。
        if let duration = session.timelineDuration(), duration.value > 0 {
            player.setDuration(duration)
        }
        guard player.play().isOK else { return }
        isPlaying = true
        startPlaybackLoop()
    }

    /// 停止播放并回到 0。
    public func stopPlayback() {
        guard let player else { return }
        player.stop()
        stopPlaybackLoop()
        isPlaying = false
        setPlayhead(RationalTime(value: 0, timescale: RationalTime.projectTimescale))
    }

    private func startPlaybackLoop() {
        playbackTimer?.invalidate()
        tickCount = 0
        // 60Hz 驱动取帧请求；UI 发布（playhead）降频到 30Hz —— 见 tickPlayback 注释。
        // 泵跟不上就丢帧，时刻由墙钟算，丢帧不影响播放节奏的正确性。
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            // Timer 在主 run loop 回调，但 Swift 6 并发模型不认识
            // "main run loop == MainActor" —— 跳一次（同 applySnapshot 的手法）。
            Task { @MainActor [weak self] in self?.tickPlayback() }
        }
        playbackTimer = timer
    }

    private func stopPlaybackLoop() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// 推进一帧：tick 判定边界 → 取当前时刻 → 喂给取帧泵 → 发布播放头。
    ///
    /// ⚠️ **两个频率是故意分开的**：
    ///   * 取帧请求（60Hz）—— 泵自己会合并，跟不上就丢帧，多请求没有副作用；
    ///   * `playhead` 发布（30Hz）—— 它是 @Published，变一次 SwiftUI 就要重算
    ///     整个编辑器 body（时间线画布会跟着重绘）。60Hz 全文重算是纯浪费，
    ///     而画面呈现由 MTKView 的连续绘制负责，不依赖 playhead 的发布频率。
    private func tickPlayback() {
        guard let player, isPlaying else { return }
        _ = player.tick()
        if player.isPlaying {
            let now = player.currentTime
            previewPump?.request(pts: now)
            tickCount += 1
            if tickCount % 2 == 0 { playhead = now }
        } else {
            // 播完自然结束：内核把状态置为停止、时刻归 0（语义见 player_clock.h）
            stopPlaybackLoop()
            isPlaying = false
            setPlayhead(RationalTime(value: 0, timescale: RationalTime.projectTimescale))
        }
    }

    // MARK: 片段编辑与撤销（UIA-005）

    /// 移动片段起点（同轨）。**异步**：Ok 只代表入队，与同轨片段重叠时
    /// 内核在 session 线程拒绝（版本不推进）。
    @discardableResult
    public func moveClip(clipId: UInt64, to start: RationalTime) -> Status {
        session.moveClip(clipId: clipId, start: start)
    }

    /// 裁剪片段占时（只改 duration，不动 source_in —— 内核既定语义）。
    @discardableResult
    public func trimClip(clipId: UInt64, duration: RationalTime) -> Status {
        session.trimClip(clipId: clipId, duration: duration)
    }

    @discardableResult
    public func undo() -> Status { session.undo() }

    @discardableResult
    public func redo() -> Status { session.redo() }

    /// 主动回到内核真值（UIA-005 的关键收口）。
    ///
    /// 拖拽/裁剪提交可能被内核拒绝（重叠 / duration ≤ 0），而拒绝**不会**
    /// 触发 observer 回流 —— 若 UI 此时还留着本地预览位置，就会显示一个
    /// 内核里并不存在的"幽灵片段"。故提交后一律主动重查一次：成功时 observer
    /// 随后会再刷一次（同值，无害），失败时这一次就是回到真值的唯一途径。
    public func refreshFromKernel() {
        timeline = TimelineState(
            tracks: session.queryTracks(),
            clips: session.queryClips(),
            version: session.currentSnapshot.version)
        refreshHistoryFlags()
    }

    private func refreshHistoryFlags() {
        canUndo = session.canUndo
        canRedo = session.canRedo
    }

    // MARK: 预览（BIND-003 子步骤 6）

    /// 推进播放头（暂停 / 拖拽场景）。时间值由调用方以整数给出。
    ///
    /// 同时向取帧泵请求该时刻的帧 —— 泵是异步的，视图会自驱重绘直到追上
    /// （见 MetalPreviewView 的 selfDrive 说明）。
    public func setPlayhead(_ t: RationalTime) {
        playhead = t
        previewPump?.request(pts: t)
    }

#if DEBUG
    /// UIA-003/004 启动冒烟辅助：从环境变量 `CQ_DEMO_VIDEO` 载入演示素材，
    /// 在轨道 1 铺一条 5 秒片段并把播放头放到 0.5s（120000 timescale 的 60000）。
    ///
    /// 变量未设置或文件不存在时不做任何事（返回 false）—— 预览保持黑屏，
    /// 等真实素材导入（UIA-009 子步骤 3）。App 正式路径**不依赖**本方法。
    ///
    /// 装配走 Session（唯一真源）：预览渲染读其快照，时间线视图经 observer 回流刷新。
    /// ⚠️ 提交是异步的：addTrack 的真实轨道 id 要等内核分配 —— 先注册素材 +
    ///    建轨道，轮询版本推进后查询 id，再提交 addClip（DEBUG 冒烟用
    ///    RunLoop 泵主队列等待，正式 UI 走 observer 回流，不这样等）。
    @discardableResult
    public func installDemoClipFromEnvironment() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["CQ_DEMO_VIDEO"],
              FileManager.default.fileExists(atPath: path) else {
            return false
        }
        let ts = RationalTime.projectTimescale
        let start = RationalTime(value: 0, timescale: ts)
        let duration = RationalTime(value: 5 * Int64(ts), timescale: ts)
        let sourceIn = RationalTime(value: 0, timescale: ts)

        let versionAtStart = session.currentSnapshot.version
        guard session.registerAsset(id: 1, path: path).isOK,
              session.addTrack(kind: 0).isOK else { return false }
        let deadline = Date().addingTimeInterval(5)
        while session.currentSnapshot.version < versionAtStart + 2 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let track = session.queryTracks().first else { return false }
        guard session.addClip(trackId: track.trackId, assetId: 1,
                              start: start, duration: duration,
                              sourceIn: sourceIn).isOK else { return false }
        setPlayhead(RationalTime(value: 60000, timescale: ts))
        return true
    }
#endif

    // MARK: 快照回流

    private func applySnapshot(_ snap: Snapshot) {
        guard snap.version != knownVersion else { return }
        lastChanges = session.changesSince(knownVersion)
        knownVersion = snap.version
        snapshot = snap
        // 时间线显示状态随之刷新（UIA-004）：读内核已发布快照。
        timeline = TimelineState(
            tracks: session.queryTracks(),
            clips: session.queryClips(),
            version: snap.version)
        refreshMediaLibrary()
        refreshHistoryFlags()
    }

    /// 主动刷新一次时间线与素材库状态（初始加载用：版本 0 不触发 observer 回流）。
    public func refreshTimeline() {
        timeline = TimelineState(
            tracks: session.queryTracks(),
            clips: session.queryClips(),
            version: session.currentSnapshot.version)
        refreshMediaLibrary()
        refreshHistoryFlags()
    }

    private func refreshMediaLibrary() {
        mediaLibrary = session.queryAssets().map { asset in
            LibraryAsset(id: asset.assetId,
                         path: asset.path,
                         pathTruncated: asset.pathTruncated,
                         exists: FileManager.default.fileExists(atPath: asset.path))
        }
    }

    // MARK: 素材导入（UIA-009 子步骤 3；D3：MVP 引用原路径，不拷贝入库）

    /// 导入一个媒体文件：探测时长 → 注册素材 → 追加到第一条视频轨末尾。
    ///
    /// 流程全在主线程（用户动作、低频）：probe 是同步调用（打开容器读时长，
    /// 毫秒级）；提交是异步的（track 不存在时需先建轨等 id，用 RunLoop 泵等待）。
    ///
    /// - Parameter url: 文件 URL（fileImporter 产出；内部处理 iOS security scope）。
    /// - Returns: 失败状态（探测失败 / 提交失败 / 已有导入在进行中 resourceExhausted）。
    @discardableResult
    public func importMedia(url: URL) -> Status {
        if importInFlight { return .resourceExhausted }
        importInFlight = true
        defer { importInFlight = false }

        // iOS：fileImporter 产出的 URL 需要 security scope 才能读（macOS 无害）。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let path = url.path

        // 1) 探测时长（同步；失败 = 无法解析的文件）
        guard let duration = session.probeMediaDuration(path: path) else {
            return Status(rawValue: 2000)  // kDecodeError：打不开/解析不了
        }
        // 文件能打开却读不到时长 = 解析问题（不是参数非法）—— 用 decodeError 而非
        // invalidArgument，调用方与日志能区分这两类失败。
        // ⚠️ 实测偶发（SharedUI 全量跑约 50% 命中，pitfalls P33）：probe 成功但
        //    时长为 0，根因未定位在内核侧。这里是症状的最早可观测点。
        guard duration.value > 0 else { return Status(rawValue: 2000) }

        // 2) 注册素材（素材 id 本地分配，单调递增）
        let assetId = nextAssetId
        nextAssetId += 1
        let regSt = session.registerAsset(id: assetId, path: path)
        guard regSt.isOK else {
            nextAssetId -= 1
            print("[EditorViewModel] importMedia: registerAsset 失败 raw=\(regSt.rawValue)")
            return .invalidArgument
        }

        // 3) 目标轨道：第一条视频轨；没有则建一条（异步 → 等落地）。
        // ⚠️ 判据必须是「视频轨出现」本身，**不能**是「版本号推进了」（P33）：
        //    registerAsset 也发布快照推版本，版本差值无法区分是哪条命令落地 ——
        //    在途的 registerAsset 先应用就会让等待提前通过，随后查询看不到视频轨，
        //    importMedia 假失败 7000（负载越重窗口越大，故只在全量跑时偶发）。
        //    查询是纳秒级快照读，10ms 轮询安全且便宜。
        var videoTrack = timeline.tracks.first(where: { $0.isVideo })
        if videoTrack == nil {
            let addTrackSt = session.addTrack(kind: 0)
            guard addTrackSt.isOK else {
                print("[EditorViewModel] importMedia: addTrack 失败 raw=\(addTrackSt.rawValue)")
                return .invalidArgument
            }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                videoTrack = session.queryTracks().first(where: { $0.isVideo })
                if videoTrack != nil { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            guard videoTrack != nil else {
                print("[EditorViewModel] importMedia: 5s 内未等到视频轨（addTrack 未落地或被拒）")
                return .invalidArgument
            }
        }
        let trackId = videoTrack!.trackId

        // 4) 追加片段：起点 = 该轨最后一片段的结束时刻（追加式，不重叠）
        let end = timeline.clips
            .filter { $0.trackId == trackId }
            .compactMap { clip -> Double? in
                let s = Double(clip.start.value) / Double(clip.start.timescale)
                let d = Double(clip.duration.value) / Double(clip.duration.timescale)
                return s + d
            }
            .max() ?? 0
        let appendTicks = Int64((end * Double(RationalTime.projectTimescale)).rounded())
        let start = RationalTime(value: appendTicks, timescale: RationalTime.projectTimescale)
        let addClipSt = session.addClip(trackId: trackId, assetId: assetId,
                                        start: start, duration: duration,
                                        sourceIn: RationalTime(value: 0, timescale: duration.timescale))
        guard addClipSt.isOK else {
            print("[EditorViewModel] importMedia: addClip 失败 raw=\(addClipSt.rawValue) "
                + "trackId=\(trackId) start=\(start.value)/\(start.timescale) "
                + "dur=\(duration.value)/\(duration.timescale)")
            return .invalidArgument
        }
        return .ok
    }
}

/// 能力全集（Capability 是从 0 起连续编号的 enum）。
private var allCapabilities: [Capability] {
    [
        .hwDecodeH264, .hwDecodeHevc, .hwDecodeAv1, .hwDecodeProRes,
        .hwEncodeH264, .hwEncodeHevc, .hwEncodeProRes,
        .tenBitPipeline, .hdrDisplay, .computeShader, .floatTexture,
        .externalMemoryImport, .npuInference,
        .gpuMetal, .gpuGLES, .gpuVulkan,
    ]
}
