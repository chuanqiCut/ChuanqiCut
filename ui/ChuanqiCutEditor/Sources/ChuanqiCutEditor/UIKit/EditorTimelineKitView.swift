#if os(iOS)
// EditorTimelineKitView — 真实编辑页的轨道区（TimelineKit 版）
//
// 取代早期自绘的 `EditorTimelineUIView`。**只替换轨道视图**：预览区、传输条、
// 底栏、素材导入流程一字未动（`EditorViewController` 的装配与订阅保持原样）。
//
// ## 真源方向（内核 ⇄ TimelineKit）
//
//   灌入（内核 → Kit）：`$timeline` 变化 → `reload(...)` → 按 `TimelineKitSnapshot`
//     重建 `TimelineStore` + `TimelineView`（见下方「为什么是重建而不是增量」）。
//   回写（Kit → 内核）：`TimelineStore` 的 `.projectChanged` 是**唯一**回写入口
//     —— 它带的是组件真正落到自己模型上的命令，比视图层的 `...Committed` 事件
//     更全（例如「拖到副轨无空位 → 组件自建轨道」这类分支不产 Committed 事件）。
//     可翻译的（move/trim）→ `TrackIntent` → 既有 `TrackIntentApplier`（VM 命令
//     + refreshFromKernel）；**不可翻译的（轨道排序/静音/锁定/轨内重排）一律
//     不写内核，直接 `onNeedsResync` 强制按内核快照重灌** —— 内核是唯一真源，
//     不做「UI 变了内核没变」的假编辑（ADR-0034）。
//
// ## 为什么是「重建 store + view」而不是增量 apply
//
// `TimelineStore` 没有「整体替换 project」的入口，也没有新增媒体资产的命令，
// 而内核快照变化最常见的恰恰是**新增素材**（导入）与**新增片段**。用命令去
// 逼近快照既写不出（媒体资产无命令）又容易漏（轨道顺序/片段增删组合），
// 故这里按快照整体重建：代价是缩放/滚动位置要自己带走（已做），
// 收益是「显示 = 内核快照」恒成立，不需要维护第二份状态。
// 重建只在**内核快照真的变了**时发生（值相等直接跳过），播放中不触发。
//
// ## 与预览 / 操作面板的联动（都在宿主侧，本类只出事件）
//
//   * 播放头：`onScrub` → VM.setPlayhead → 取帧泵 → 预览（与旧轨道区同一条链路）；
//     播放中由 VM 反向调用 `updatePlayhead(seconds:)` 推本视图（红条恒中央）。
//   * 选中：`store` 的 `.selectionChanged` → `.selectClip` Intent → VM 选中态
//     → 底栏分割/删除可用性 + 预览区红框（宿主既有链路）。
//   * 尾部「+」：`.tailInsertionRequested` → `onRequestAppend` → 既有素材导入。

import UIKit
import Combine
import CoreFoundation  // CFAbsoluteTimeGetCurrent（DEBUG 性能采样）
import SnapKit
import os
import ChuanqiCutEngine
import TimelineKit

@MainActor
final class EditorTimelineKitView: UIView {

    // MARK: - 出口（宿主接线，本类不认识 ViewModel）

    /// 组件请求宿主执行的动作（选中 / 提交编辑）。宿主走既有 `TrackIntentApplier`。
    var onIntents: (([TrackIntent]) -> Void)?
    /// 用户拖时间线 → 播放头时刻（秒，已按项目帧率吸附）。宿主转 VM.setPlayhead。
    var onScrub: ((Double) -> Void)?
    /// 一次用户 scrub **结束**（手指离屏 / 减速结束 / 兜底超时）→ 终值时刻（秒）。
    /// 宿主据此做一次**精确**（kExact）取帧：拖动中用廉价关键帧保证跟手，
    /// 松手后必须回到精确帧（用户看到的最终画面不能是近似帧，P142）。
    var onScrubEnded: ((Double) -> Void)?
    /// 轨道尾部「+」→ 宿主打开既有素材导入。
    var onRequestAppend: (() -> Void)?
    /// 组件发生了一次**内核不支持**的自我变更 → 宿主立即按内核快照重灌。
    var onNeedsResync: (() -> Void)?

    // MARK: - 内部状态

    private var store: TimelineStore?
    private var kitView: TimelineView?
    private var subscriptions = Set<AnyCancellable>()

    /// 上一次灌入的内核快照（重建判定 + 回写时反查「片段原本在哪条轨」）。
    private var pushed: TimelineKitSnapshot = .empty
    /// 缩放（每秒像素）。重建时带走，避免每次模型变化都把用户缩好的比例弹回默认。
    private var zoomPixelsPerSecond: CGFloat = 80
    private var playheadSeconds: Double = 0
    private var selectedClipId: UInt64?
    /// 由宿主灌入选中态时置位（抑制 `selectionChanged` 回流成一次「再点取消」）。
    private var isPushingSelection = false
    /// 用户正在用手指拖时间线（scrub）。**此期间一律不把播放头回推给组件** ——
    /// 见 `updatePlayhead` 的守卫注释：回推会强制 `setContentOffset`，把
    /// UIScrollView 的惯性动画一次次打断（表现为「滑完没有惯性」）。
    private var isUserScrubbing = false
    /// 最近一次 userScrub 的时刻（兜底：结束事件没来也要自动解除抑制）。
    private var lastUserScrubAt: CFTimeInterval = 0
    /// 抑制的自动解除上限（秒）：`.timeChanged(final:)/.timeScrollEnded` 正常一定会来，
    /// 这是**独立超时上界** —— 异步等待必须同时有超时和上界（ADR-0034 契约）。
    private static let scrubSuppressTimeout: CFTimeInterval = 0.5
    /// 空态（无片段）：沿用旧轨道区的处理 —— 区域高度保留，**内容隐藏**。
    private var isEmptyState = false

    private let log = Logger(subsystem: "com.chuanqi.cut", category: "EditorTimelineKitView")

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 与传输条 / 底栏同底（EditorChromePalette.chromeBackground），三区连成一体。
        backgroundColor = EditorChromePalette.chromeBackground.uiColor
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    // MARK: - 灌入（VM 订阅驱动）

    /// 按内核最新快照刷新。`force = true` 跳过「值相等则跳过」的判定
    /// （提交回写后必须用它：内核可能**拒绝**了这次提交，此时快照没变、
    /// 但组件自己已经改过了 —— 不强制重灌就会留下一个内核里不存在的幽灵位置）。
    func reload(tracks: [TrackInfo], clips: [ClipInfo], assets: [UInt64: String],
                playheadSeconds: Double, force: Bool = false) {
        let snapshot = TimelineKitSnapshot(tracks: tracks, clips: clips, assets: assets)
        self.playheadSeconds = playheadSeconds
        guard force || snapshot != pushed else { return }
        pushed = snapshot
        rebuild(snapshot)
    }

    /// 播放头 → 视口中央（CADisplayLink 播放中逐帧驱动 / $playhead 兜底）。
    ///
    /// 组件内部是「播放头固定在视口中央、内容滚过去」的同一种范式（对标 App S4），
    /// 故这里与旧实现语义完全一致，只是驱动对象换成了 TimelineKit。
    ///
    /// ⚠️ 代价（2026-10-15 实测前已知）：`setCurrentTime` → 组件 `scrollToTime` →
    /// `scrollViewDidScroll` → `layoutTrackHeaders + layoutVisibleContent + positionPlayhead`
    /// **三套布局全跑一遍**。旧自绘版每帧只画一条线，成本差一个量级。播放中由
    /// CADisplayLink 每帧调本方法 = 每帧三套布局 —— 这是"集成后变卡"的第一嫌疑点，
    /// 采样数据见下方 `[tk:perf]` 通道。
    func updatePlayhead(seconds: Double) {
        playheadSeconds = seconds
        // ⚠️ 用户正在拖（含惯性滑行）时不回推。推一次 = 组件 `scrollToTime` →
        // `timelineScrollView.setContentOffset(...)`，**直接把 UIScrollView 的
        // 减速动画打断** —— 手指一离屏滚动就立刻停死（2026-10-15 传哲反馈
        // 「滑动之后的惯性就没有」，调试页没这现象正是因为它从不回推）。
        // 组件的播放头本来就恒在视口中央，scrub 期间不需要宿主告诉它位置。
        if isUserScrubbing {
            if CACurrentMediaTime() - lastUserScrubAt > Self.scrubSuppressTimeout {
                endUserScrub()
            } else {
                return
            }
        }
        guard let kitView, let time = TimelineKitTime.time(seconds: seconds) else { return }
        #if DEBUG
        let began = CFAbsoluteTimeGetCurrent()
        defer { sample(elapsed: CFAbsoluteTimeGetCurrent() - began) }
        #endif
        kitView.setCurrentTime(time, animated: false)
    }

    // MARK: - DEBUG 性能采样（真机 stderr 通道，与 [tk:track] 同款）

    #if DEBUG
    /// 采样窗口内的调用次数 / 总耗时 / 最长单次（毫秒）。
    private var sampleCount = 0
    private var sampleTotalMs = 0.0
    private var sampleMaxMs = 0.0
    private var sampleWindowStart = CFAbsoluteTimeGetCurrent()
    private var rebuildMs = 0.0
    private var rebuildCount = 0

    private func sample(elapsed: TimeInterval) {
        let ms = elapsed * 1000
        sampleCount += 1
        sampleTotalMs += ms
        if ms > sampleMaxMs { sampleMaxMs = ms }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - sampleWindowStart >= 2 else { return }
        let count = sampleCount
        fputs("[tk:perf] playhead n=\(count) avg=\(String(format: "%.2f", sampleTotalMs / Double(max(1, count))))ms "
                + "max=\(String(format: "%.2f", sampleMaxMs))ms "
                + "rebuild=\(rebuildCount)/\(String(format: "%.1f", rebuildMs))ms\n", stderr)
        fflush(stderr)
        sampleCount = 0
        sampleTotalMs = 0
        sampleMaxMs = 0
        rebuildCount = 0
        rebuildMs = 0
        sampleWindowStart = now
    }
    #endif

    /// 选中态灌入（VM `$selectedClipId` / reload 后重推）。
    func setSelectedClip(_ id: UInt64?) {
        selectedClipId = id
        guard let store else { return }
        let mapped = id.map(TimelineKitIDs.clip)
        guard store.snapshot.selectedClipID != mapped else { return }
        isPushingSelection = true
        do { try store.selectClip(id: mapped) } catch {
            log.error("选中同步失败：\(String(describing: error), privacy: .public)")
        }
        isPushingSelection = false
    }

    /// 空态：高度保留（避免导入首个片段时布局跳动），只隐藏内容。
    func setEmpty(_ empty: Bool) {
        isEmptyState = empty
        kitView?.isHidden = empty
    }

    // MARK: - 重建

    private func rebuild(_ snapshot: TimelineKitSnapshot) {
        #if DEBUG
        let rebuildBegan = CFAbsoluteTimeGetCurrent()
        defer {
            rebuildCount += 1
            rebuildMs += (CFAbsoluteTimeGetCurrent() - rebuildBegan) * 1000
        }
        #endif
        teardown()

        let project: TimelineProject
        do {
            project = try TimelineKitProjectBuilder.makeProject(snapshot)
            #if DEBUG
            // 真机排障通道（与仓库既有 [hook]/[import]/[wf:perf] 同款：stderr 无缓冲，
            // `devicectl device process launch --console` 必现；os.Logger 不落 stdout）。
            fputs("[tk:track] rebuild tracks=\(project.tracks.count) "
                    + "clips=\(project.tracks.reduce(0) { $0 + $1.clips.count }) "
                    + "assets=\(project.mediaAssets.count) pps=\(Int(zoomPixelsPerSecond))\n",
                  stderr)
            fflush(stderr)
            #endif
        } catch {
            // 模型校验失败 = 内核快照里有组件不接受的组合。**如实降级**：
            // 记日志并保持空白，绝不用 try! 把 App 炸在启动路径上。
            log.error("TimelineProject 构建失败：\(String(describing: error), privacy: .public)")
            return
        }
        guard let newStore = try? TimelineStore(project: project) else {
            log.error("TimelineStore 创建失败（项目校验未通过）")
            return
        }
        let view = TimelineView(store: newStore, style: makeStyle())
        view.backgroundColor = EditorChromePalette.chromeBackground.uiColor
        addSubview(view)
        view.snp.makeConstraints { $0.edges.equalToSuperview() }

        store = newStore
        kitView = view
        bind(store: newStore)
        bind(view: view)

        // 重建后把三件 UI 状态灌回：选中、播放头、空态。
        setSelectedClip(selectedClipId)
        updatePlayhead(seconds: playheadSeconds)
        view.isHidden = isEmptyState
        view.reloadData()
    }

    private func teardown() {
        subscriptions.removeAll()
        kitView?.removeFromSuperview()
        kitView = nil
        store = nil
    }

    /// 配色一律走本包分域色表（TimelinePalette / EditorChromePalette），
    /// 不去改 SharedUI 的 Theme（ADR-0034：写集不相交）。
    private func makeStyle() -> TimelineStyle {
        TimelineStyle(
            backgroundColor: EditorChromePalette.chromeBackground.uiColor,
            rulerBackgroundColor: EditorChromePalette.chromeBackground.uiColor,
            rulerTextColor: TimelinePalette.tickLabel.uiColor,
            primaryTrackBackgroundColor: TimelinePalette.trackHeaderBackground.uiColor,
            headerBackgroundColor: EditorChromePalette.chromeBackground.uiColor,
            selectedBorderColor: TimelinePalette.selectionBorder.uiColor,
            // 对标 App 的播放头是白色（旧自绘版同值）；TimelineKit 默认是紫红。
            playheadColor: TimelinePalette.playhead.uiColor,
            // 左侧轨道头（类型图标 + 轨道名 + L/M + 长按排序）**关闭**：
            // 锁定 / 静音 / 轨道排序内核全无写 ABI（池 [19]），那排按钮点了只会让
            // 组件自我变更 → 走 default 分支 → 整条时间线按内核重灌（既没用又卡）。
            // 剪映的轨道区左侧也没有常驻轨道头 —— 关掉两头都对齐。
            showsTrackHeader: false,
            rulerHeight: 24,
            minimumPixelsPerSecond: 8,
            maximumPixelsPerSecond: 1_200,
            initialPixelsPerSecond: zoomPixelsPerSecond,
            trackSpacing: TimelineLayout.trackSpacing,
            clipSpacing: 2,
            contentTailInset: 64,
            clipCornerRadius: 4,
            minimumClipWidth: 12)
    }

    // MARK: - 事件绑定

    // ⚠️ 这里刻意**不套** `Task { @MainActor }`：Combine 的 sink 闭包不是
    //    @Sendable，天然继承本类的 MainActor 隔离；而 `TimelineViewEvent` 未声明
    //    Sendable，一旦塞进 `Task {}` 就会撞 Swift 6 的「捕获非 Sendable」。
    //    （同 Pod 内 TimelineKitIntegrationPreview 已是这个写法。）
    private func bind(store: TimelineStore) {
        store.events
            .sink { [weak self] event in self?.handle(storeEvent: event) }
            .store(in: &subscriptions)
    }

    private func bind(view: TimelineView) {
        view.events
            .sink { [weak self] event in self?.handle(viewEvent: event) }
            .store(in: &subscriptions)
    }

    /// 组件自身模型的变更。**回写内核的唯一入口**。
    private func handle(storeEvent event: TimelineStoreEvent) {
        switch event {
        case .selectionChanged(let clipID):
            // 宿主灌入选中态引起的回流不合并进 Intent（否则「选中」会变成「取消选中」）。
            guard !isPushingSelection else { return }
            let kernelID = clipID.flatMap(TimelineKitIDs.clipID)
            onIntents?([.selectClip(kernelID)])

        case .playheadChanged(let time, let origin):
            // 只认用户拖动：程序化（播放跟随 / seek 居中）不回灌，否则播放器与
            // 播放头会形成反馈环（INTEGRATION_GUIDE §3 的同款提示）。
            guard origin == .userScrub, let store else { return }
            isUserScrubbing = true
            lastUserScrubAt = CACurrentMediaTime()
            let quantized = store.snapshot.project.frameRate.quantize(time)
            onScrub?(quantized.seconds)

        case .projectChanged(_, let command):
            handle(command: command)
        }
    }

    /// TimelineCommand → 内核命令。**翻译不了的一律回滚到内核真值**。
    private func handle(command: TimelineCommand) {
        switch command {
        case .moveClip(let clipID, let targetTrackID, let start):
            guard let kernelClip = TimelineKitIDs.clipID(from: clipID),
                  let kernelTrack = TimelineKitIDs.trackID(from: targetTrackID) else {
                // 目标轨是组件自己新建的（拖到副轨无空位时组件会自建一条）：
                // 内核没有这条轨 → 不写内核，回滚。
                resync(reason: "moveClip 目标轨非内核轨道")
                return
            }
            let startTime = TimelineKitTime.rational(start)
            // 同轨 / 跨轨按**内核真值**判定：组件给的 targetTrackID 可能是源轨。
            let sourceTrack = pushed.clips.first(where: { $0.clipId == kernelClip })?.trackId
            let edit: TrackClipEdit = sourceTrack == kernelTrack
                ? .move(clipId: kernelClip, start: startTime)
                : .moveToTrack(clipId: kernelClip, trackId: kernelTrack, start: startTime)
            commit(edit)

        case .trimClip(let clipID, let edge, let boundary):
            guard let kernelClip = TimelineKitIDs.clipID(from: clipID),
                  let store,
                  let clip = store.snapshot.project.tracks.lazy.flatMap(\.clips)
                    .first(where: { $0.id == clipID }) else {
                resync(reason: "trimClip 片段不在内核")
                return
            }
            switch edge {
            case .leading:
                // 左缘：只给新起点，sourceIn / duration 由内核按「右缘不动」联动（EDIT-008）。
                commit(.trimStart(clipId: kernelClip,
                                  start: TimelineKitTime.rational(boundary)))
            case .trailing:
                // 右缘：只给新占时，起点与 sourceIn 不动（内核既定语义）。
                guard let duration = try? boundary.subtracting(clip.start) else {
                    resync(reason: "trimClip 右缘时长非法")
                    return
                }
                commit(.trimEnd(clipId: kernelClip,
                                duration: TimelineKitTime.rational(duration)))
            }

        case .setTrackMuted(let trackID, let muted):
            guard let kernelTrack = TimelineKitIDs.trackID(from: trackID) else {
                // 组件自建轨（内核没有）→ 不写内核，回滚到内核真值。
                resync(reason: "setTrackMuted 目标轨非内核轨道")
                return
            }
            commit(.setTrackMuted(trackId: kernelTrack, muted: muted))

        default:
            // 轨道排序 / 锁定 / 轨内重排 / 增删轨 / 增删片段 / 分割 / 转场 /
            // 关键帧 / 画布 item / 蒙版 —— 内核暂无对应命令。
            // 组件的自我变更必须回滚，否则 UI 显示的状态内核不认。
            // （静音在 CORE-011 已有写 ABI，走上面那条 case，不再回滚。）
            resync(reason: "组件命令无内核对应：\(command)")
        }
    }

    /// 一次用户 scrub 结束：解除回推抑制，用终值对齐一次，并通知宿主做**精确**取帧。
    ///
    /// P142：这里除了 UI 对齐，还要出 `onScrubEnded` —— 拖动全程宿主用 kKeyframeBefore
    /// 廉价关键帧（跟手），松手这一刻必须由宿主补一次 kExact 精确帧，用户看到的终值
    /// 才不是近似帧。此处组件 currentTime 早已等于终值，`store.setCurrentTime` 的同值
    /// 守卫会直接 return，不会触发额外滚动。
    private func endUserScrub() {
        guard isUserScrubbing else { return }
        isUserScrubbing = false
        onScrubEnded?(playheadSeconds)
        updatePlayhead(seconds: playheadSeconds)
    }

    private func handle(viewEvent event: TimelineViewEvent) {
        switch event {
        case .tailInsertionRequested:
            onRequestAppend?()
        case .timeChanged(_, let final):
            // `final: true` = 手指离屏 / 减速结束（组件 `finishTimeScroll()` 发出）。
            if final { endUserScrub() }
        case .timeScrollEnded:
            endUserScrub()
        case .zoomChanged(let scale):
            zoomPixelsPerSecond = CGFloat(scale)
        case .editRejected(let error):
            // 组件内部校验拒绝（如拖到被锁轨道）：如实记账，不弹 UI（无声失败会被
            // 下一次按内核重灌抹平）。
            log.info("编辑被组件拒绝：\(String(describing: error), privacy: .public)")
            onNeedsResync?()
        case .resourceFailed(let clipID, let error):
            // 缩略图/波形取不到（素材被删 / 路径被截断 / 编码不支持）：只记日志，
            // 片段照常显示（无图）—— 不因此把整条时间线置空。
            log.error("素材资源失败 clip=\(clipID, privacy: .public)：\(String(describing: error), privacy: .public)")
        default:
            break
        }
    }

    // MARK: - 出口工具

    private func commit(_ edit: TrackClipEdit) {
        // 重灌由**宿主**在 apply(intents) 里做（`reloadTimeline(force: true)`）：
        // 提交后必须回到内核真值 —— 内核可能拒绝（重叠 / duration ≤ 0），而拒绝
        // **不会**触发 observer 回流（与旧轨道区 refreshFromKernel 的动机相同）。
        // 此处不再另发 onNeedsResync，否则同一次提交会重建两遍。
        onIntents?([.commitEdit(edit)])
    }

    private func resync(reason: String) {
        log.info("回滚组件自我变更：\(reason, privacy: .public)")
        #if DEBUG
        fputs("[tk:track] resync reason=\(reason)\n", stderr)
        fflush(stderr)
        #endif
        onNeedsResync?()
    }
}
#endif
