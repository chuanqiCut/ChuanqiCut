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
    }

    /// 主动刷新一次时间线状态（初始加载用：版本 0 不触发 observer 回流）。
    public func refreshTimeline() {
        timeline = TimelineState(
            tracks: session.queryTracks(),
            clips: session.queryClips(),
            version: session.currentSnapshot.version)
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
