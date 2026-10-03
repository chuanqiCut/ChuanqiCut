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

    public init() throws {
        guard let session = Session() else {
            throw EditorError.sessionCreationFailed
        }
        self.session = session
        self.snapshot = session.currentSnapshot
        self.knownVersion = session.currentSnapshot.version
        // UIA-009 子步骤 2 收口后预览挂 session 快照（单一真源），并强持有 session。
        self.preview = Previewer(session: session, width: 1280, height: 720)
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

    /// 推进播放头（预览视图按需重绘该时刻）。时间值由调用方以整数给出。
    public func setPlayhead(_ t: RationalTime) {
        playhead = t
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
        guard duration.value > 0 else { return .invalidArgument }

        // 2) 注册素材（素材 id 本地分配，单调递增）
        let assetId = nextAssetId
        nextAssetId += 1
        guard session.registerAsset(id: assetId, path: path).isOK else {
            nextAssetId -= 1
            return .invalidArgument
        }

        // 3) 目标轨道：第一条视频轨；没有则建一条（异步 → 等 id）
        let versionAtStart = session.currentSnapshot.version
        var videoTrack = timeline.tracks.first(where: { $0.isVideo })
        if videoTrack == nil {
            guard session.addTrack(kind: 0).isOK else { return .invalidArgument }
            let deadline = Date().addingTimeInterval(5)
            while session.currentSnapshot.version <= versionAtStart && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            videoTrack = session.queryTracks().first(where: { $0.isVideo })
            guard videoTrack != nil else { return .invalidArgument }
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
        guard session.addClip(trackId: trackId, assetId: assetId,
                              start: start, duration: duration,
                              sourceIn: RationalTime(value: 0, timescale: duration.timescale)
                                  ).isOK else {
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
