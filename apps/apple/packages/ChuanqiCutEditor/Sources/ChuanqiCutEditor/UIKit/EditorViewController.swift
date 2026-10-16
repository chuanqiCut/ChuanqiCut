#if os(iOS)
// EditorViewController — 编辑页 UIKit 容器（UIA-034，ADR-0024）
//
// 竖排三区（对照 SwiftUI 版 verticalLayout）：预览（弹性，直嵌 PreviewMTKView
// + 空态引导/点按播放）→ 传输条 44 → 时间线 140 → 工具栏 84（UIA-043：58 → 84）。
//
// UIA-043（对标 App 单色系视觉改版，纯视觉 + 出口迁移，**零交互变更**）：
//   * 底栏 84 / 图标 22；撤销·重做**迁到传输条**（与播放、时间码同栏）；
//   * 空态去掉悬浮卡片，元素直接落在预览区，主操作白底黑字；
//   * 空时间线不画刻度尺与播放头（轨道视图 setEmpty）。
//
// 轨道区（2026-10-15）：早期自绘版 `EditorTimelineUIView` 已由本地 CocoaPods
// TimelineKit 的 `TimelineView` 取代（适配层见 TimelineKitAdapter.swift）。
// **换的只有轨道视图**：预览区 / 传输条 / 底栏 / 素材导入流程与它们的联动
// 一字未动 —— 三区的联动出口仍是 `TrackIntent` + VM 命令（红线 #5）。
//
// 每帧驱动（ADR-0024 决定 4）：CADisplayLink 仅播放中运行，直读
// viewModel.playhead → 时间线播放头层 + 传输条时间码，**不经 SwiftUI**；
// 暂停态由 $playhead 订阅兜底（seek/单步）。
//
// 红线 #5：模型变更只走 EditorViewModel 既有命令入口（togglePlayback/moveClip/
// trimClip/undo/redo + refreshFromKernel），本类零新增模型路径。

import UIKit
import SwiftUI
import Combine
import SnapKit
import ChuanqiCutEngine
import SharedUI  // 基座：Theme（ADR-0031）

@MainActor
final class EditorViewController: UIViewController {
    private let viewModel: EditorViewModel
    private var onOpenMedia: () -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var displayLink: CADisplayLink?

    // 区块视图
    private let previewContainer = UIView()
    private var previewMTKView: PreviewMTKView?
    private let previewFallback = UILabel()
    private let emptyStateView = UIView()
    private let transportBar = EditorTransportBarView()
    /// 轨道区 = TimelineKit 版（本地 Pod）。出口与旧自绘版**同名同语义**
    /// （onIntents / onScrub / onRequestAppend），故下面整段装配不动。
    private let timelineView = EditorTimelineKitView()
    private let toolbarView = EditorToolbarUIView()
    /// U1（S11）：预览区选中红框。贴在预览画布外沿，默认隐藏。
    private let previewSelectionBorder = UIView()
    #if DEBUG
    /// DEBUG 实时诊断浮层（2Hz 采样）。⚠️ 必须挂**在 UIKit 容器里** ——
    /// iOS 走 `compact()` 槽位，SwiftUI `EditorView` 的 `preview:` 槽位（浮层原本
    /// 挂在那里）**根本不渲染**，等于 iPhone 上从来没有浮层（2026-10-15 修）。
    private var debugOverlayHost: UIHostingController<DebugOverlayView>?
    #if DEBUG
    /// 浮层位置约束（拖动时增量更新）。
    private var debugOverlayTop: NSLayoutConstraint?
    private var debugOverlayLeading: NSLayoutConstraint?
    /// 跨 2Hz 快照更新的持久状态（隐藏/展开不随每次刷新重置）。
    private var debugOverlayState: DebugOverlayState?
    #endif
    #endif

    /// 时间码去抖（60fps 直更只在文本变化时写 label）。
    private var lastTimecode = ""
    /// 播放中把「播放头推进到轨道区」的最小间隔（秒）。
    ///
    /// **有实测依据**（iPhone 17 Pro / iOS 26.6.1 / Debug，2026-10-15，[tk:perf] 通道）：
    /// 组件一次 `setCurrentTime` 会连带跑 `layoutTrackHeaders + layoutVisibleContent +
    /// positionPlayhead` 三套布局，实测 **avg 2.3ms / max 3.5ms**；播放中
    /// CADisplayLink + `$playhead` 两条路径叠加 ≈ **84 次/秒** → **≈19% 主线程**，
    /// 只为挪一条红线。降到 30Hz ≈ 7%，视觉上仍是连续跟随（人眼对 30Hz 的位置
    /// 跟随基本无感，时间码与预览画面仍是满帧）。
    // 播放中跟随节流上限：40Hz（传哲 2026-10-15 要求跟随不低于 24fps，留余量）。
    // 跟随由 CADisplayLink（60Hz，播放中常开）驱动 updatePlayheadUI，本值只封顶重布局频率；
    // 实测 30Hz 上限下约 26/s（主线程被 SwiftUI body 重算抢占），提到 40Hz 给余量。
    private static let trackPlayheadInterval: CFTimeInterval = 1.0 / 40
    private var lastTrackPlayheadPush: CFTimeInterval = 0
    // P142：scrub 取帧限频。拖动中每次 delta 都发一次 seek 即便用廉价关键帧，也是白烧
    // CPU 与泵吞吐（泵会合并，但已渲染的那帧仍是一次解码）。故滑动中把 **seek 频率**
    // 压到 ~24Hz（视觉上足够跟手）；松手再补一次精确帧。播放头本身仍按上面的 40Hz 推。
    private static let scrubSeekInterval: CFTimeInterval = 1.0 / 24
    private var lastScrubSeekAt: CFTimeInterval = 0
    /// 当前是否处于 scrub 拖动中。决定 `syncPreview` 触发的那次补帧用哪种 seek 策略：
    /// 拖动中必须也是廉价关键帧，否则 renderEpoch 触发的补帧会盖掉限频成果、又做一次
    /// 精确解码。松手（onScrubEnded）后复位 .exact。
    private var isScrubbingTrack = false
    /// 上次布局宽度（viewDidLayoutSubviews 重算时间线内容宽度的变化检测）。
    private var lastBoundsWidth: CGFloat = 0
    // ⚠️ 不要在这里再加 `CQ_AUTO_PLAY` 自动起播钩子：EditorScreen（SwiftUI 壳）已有
    // 同功能钩子（`[hook] auto_play=`），两处都 toggle 会互相抵消 —— 第二次
    // `togglePlayback()` 把第一次刚开起的播放**关掉**（P137，2026-10-15 实踩）。
    // 播放态剖面靠既有那一个钩子就够。

    init(viewModel: EditorViewModel, onOpenMedia: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onOpenMedia = onOpenMedia
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    func setOnOpenMedia(_ action: @escaping () -> Void) { onOpenMedia = action }

    // MARK: - 装配

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Theme.editorBackground)

        setupPreview()
        setupStack()
        bindViewModel()

        // 首帧状态（订阅是 dropFirst 语义时也能拿到当前值）
        refreshStaticState()
        syncPreview()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // viewDidLoad 首刷时 bounds 尚为 0（宽度走 320 兜底）；布局完成后按真实
        // 宽度重建一次时间线内容（播放头/滚动范围依赖 contentSize）。
        if abs(view.bounds.width - lastBoundsWidth) > 0.5 {
            lastBoundsWidth = view.bounds.width
            reloadTimeline()
            updatePlayheadUI()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDisplayLink()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func setupStack() {
        let stack = UIStackView(arrangedSubviews: [previewContainer, transportBar,
                                                   timelineView, toolbarView])
        stack.axis = .vertical
        stack.distribution = .fill
        stack.spacing = 0
        view.addSubview(stack)
        // UIA-042 / ADR-0041：布局一律 SnapKit —— snp.makeConstraints 会自动把
        // translatesAutoresizingMaskIntoConstraints 置 false，根除「忘关掩码 →
        // NSAutoresizingMaskLayoutConstraint 与手写约束冲突」整类 bug（见 P130）。
        stack.snp.makeConstraints { $0.edges.equalToSuperview() }
        // UIA-043：尺寸阶梯改读编辑器域 `EditorChrome`（不再用 SharedUI 的 58pt 底栏）。
        transportBar.snp.makeConstraints { $0.height.equalTo(EditorChrome.transportHeight) }
        timelineView.snp.makeConstraints { $0.height.equalTo(EditorChrome.timelineHeight) }
        toolbarView.snp.makeConstraints { $0.height.equalTo(EditorChrome.toolbarHeight) }

        // UIA-041/U0：Intent 出口统一。宿主是**唯一**把 Intent 翻译成 VM 命令的地方
        // （命中判定与命令选择都已不在 UIKit 侧 —— 见 TrackInteraction）。
        timelineView.onIntents = { [weak self] intents in
            self?.apply(intents)
        }
        // 组件发生了内核不支持的自我变更（轨道排序 / 静音 / 锁定等）→ 立即按内核
        // 快照重灌。内核是唯一真源，不留「UI 变了内核没变」的中间态。
        timelineView.onNeedsResync = { [weak self] in
            self?.reloadTimeline(force: true)
        }
        // U1（S7）：主轨右端「+」→ 打开素材选择（复用既有导入路径，不新增分支）。
        timelineView.onRequestAppend = { [weak self] in self?.onOpenMedia() }
        // 拖时间线 = 拖播放头（UIA-038，红条恒中央）→ 同步 seek。
        //
        // ⚠️ 播放中**先暂停再定位**（2026-10-15 修）：此前这里是
        // `guard !isPlaying else { return }`（「播放中不抢播放头」），结果是播放中拖
        // 轨道完全没反应 —— 用户要的恰恰是「轨道区的位置能控制播放位置」。
        // 不停就定位不了的真正原因：播放循环会持续把 playhead 推走，这一次 seek
        // 刚落下就被覆盖。故先 `pausePlayback()`（幂等），再 setPlayhead。
        //
        // P142（2026-10-16，scrub 卡顿修复，用户口径「滑动时快速 seek + 控制频率 +
        // 结束走一次精准 seek」）：拖动中用 **kKeyframeBefore 廉价关键帧定位** 且
        // **限频 ~24Hz** —— 此前每个 delta 都精确 seek 重解整个 GOP，长 GOP 解码占满
        // 泵线程单核、与滚动主线程抢核 → 拖动卡顿（逆向 seek 更贵）。松手由 onScrubEnded
        // 补一次 kExact 精确帧，保证终值画面精确。
        timelineView.onScrub = { [weak self] seconds in
            guard let self else { return }
            self.isScrubbingTrack = true
            self.viewModel.pausePlayback()
            // 限频：高频 delta 只推进播放头（红条跟手），不每次都触发一次解码。
            let now = CACurrentMediaTime()
            guard now - self.lastScrubSeekAt >= Self.scrubSeekInterval else { return }
            self.lastScrubSeekAt = now
            let ts = RationalTime.projectTimescale
            let ticks = Int64((seconds * Double(ts)).rounded())
            self.viewModel.setPlayhead(RationalTime(value: ticks, timescale: ts),
                                       policy: .keyframeBefore)
        }
        // scrub 结束（手指离屏 / 减速结束 / 兜底超时）：补一次**精确**帧。拖动全程是
        // 关键帧近似，松手这一刻必须回到精确帧，否则用户停在近似画面上。
        timelineView.onScrubEnded = { [weak self] seconds in
            guard let self else { return }
            // 先复位策略，再补精确帧：这次 setPlayhead 触发的 renderEpoch 补帧
            // 也会走 .exact，与终值帧一致。
            self.isScrubbingTrack = false
            let ts = RationalTime.projectTimescale
            let ticks = Int64((seconds * Double(ts)).rounded())
            self.viewModel.setPlayhead(RationalTime(value: ticks, timescale: ts),
                                       policy: .exact)
        }
        transportBar.onTogglePlayback = { [weak self] in
            self?.viewModel.togglePlayback()
        }
        // UIA-043：撤销/重做出口迁到传输条（命令链路一字未改，仍是 VM.undo/redo
        // + refreshFromKernel；换的只有触发它的那个按钮挂在哪个视图上）。
        transportBar.onUndo = { [weak self] in
            self?.viewModel.undo()
            self?.viewModel.refreshFromKernel()
        }
        transportBar.onRedo = { [weak self] in
            self?.viewModel.redo()
            self?.viewModel.refreshFromKernel()
        }
        // 分割 / 删除（UIA-039）：动作内已含 refreshFromKernel（被拒不回流时回真值）。
        toolbarView.onSplitSelected = { [weak self] in
            self?.viewModel.splitSelectedAtPlayhead()
        }
        toolbarView.onDeleteSelected = { [weak self] in
            self?.viewModel.deleteSelectedClip()
        }
        // 面板分级（UIA-040）：抽屉开合 / 画布比例 / 画中画轨。
        toolbarView.onOpenDrawer = { [weak self] kind in self?.viewModel.openDrawer(kind) }
        toolbarView.onClosePanel = { [weak self] in self?.viewModel.closePanel() }
        toolbarView.onSetCanvas = { [weak self] w, h in
            self?.viewModel.setCanvas(width: w, height: h)
        }
        toolbarView.onAddOverlayTrack = { [weak self] in
            self?.viewModel.addOverlayTrack()
        }
        toolbarView.onOpenMedia = { [weak self] in self?.onOpenMedia() }
    }

    /// 预览直嵌 PreviewMTKView（契约同 MetalPreviewView representable：
    /// init(preview:pump:pts:) + sync(preview:pump:pts:continuous:renderEpoch:)）。
    private func setupPreview() {
        if let preview = viewModel.preview {
            let mtk = PreviewMTKView(preview: preview,
                                     pump: viewModel.previewPump,
                                     pts: viewModel.playhead)
            // 宽由画布比例约束给出（applyCanvasAspect），多余宽度自然留黑边 —— 预览即画布。
            previewContainer.addSubview(mtk)
            previewMTKView = mtk
        } else {
            // 预览后端缺失：如实降级（对照 PreviewZone 降级文案），不伪装可用。
            previewFallback.text = "预览不可用\n当前平台缺少预览后端"
            previewFallback.numberOfLines = 0
            previewFallback.textAlignment = .center
            previewFallback.font = .preferredFont(forTextStyle: .subheadline)
            previewFallback.textColor = UIColor(Theme.tertiaryText)
            previewContainer.addSubview(previewFallback)
            previewFallback.snp.makeConstraints { $0.center.equalToSuperview() }
        }

        // U1（S11）：预览选中红框 —— 与 MTK 画布同宽（aspect 起的黑边不在框内）。
        // 尺寸约束在 applyCanvasAspect（center + 高满容器 + 宽=aspect×高）；
        // 2026-10-14 修复：此前只有 center + 比例约束（既缺 translates 又缺定尺），
        // 红框实为 0×0 不可见（P130），U1 S11 等于假功能。
        previewSelectionBorder.isHidden = true
        previewSelectionBorder.isUserInteractionEnabled = false
        previewSelectionBorder.layer.borderColor = TimelinePalette.previewSelectionBorder.cgColor
        previewSelectionBorder.layer.borderWidth = TimelinePalette.previewSelectionBorderWidth
        previewContainer.addSubview(previewSelectionBorder)

        // 空态引导（对照 PreviewZone.emptyStateOverlay）
        //
        // UIA-043：**不再套半透明卡片** —— 对标 App 的空态元素直接落在预览区上。
        // 卡片套层在纯黑底上会多出一块更亮的矩形（视觉噪音），主色也从蓝改单色系
        // 的白底黑字胶囊。
        let icon = UIImageView(image: UIImage(systemName: "film.stack")?
            .applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 34, weight: .light)))
        icon.tintColor = EditorChromePalette.chromeEmptyGlyph.uiColor
        icon.contentMode = .center
        let title = UILabel()
        title.text = "导入素材开始创作"
        title.font = .systemFont(ofSize: 14, weight: .regular)
        title.textColor = EditorChromePalette.chromeEmptyText.uiColor
        title.textAlignment = .center
        let openMedia = UIButton(type: .system)
        openMedia.setTitle("打开素材库", for: .normal)
        openMedia.setImage(UIImage(systemName: "plus",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 12,
                                                                                  weight: .semibold)),
                           for: .normal)
        openMedia.tintColor = EditorChromePalette.chromePrimaryText.uiColor
        openMedia.setTitleColor(EditorChromePalette.chromePrimaryText.uiColor, for: .normal)
        openMedia.backgroundColor = EditorChromePalette.chromePrimaryFill.uiColor
        openMedia.layer.cornerRadius = EditorChrome.primaryCornerRadius
        openMedia.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        openMedia.contentEdgeInsets = UIEdgeInsets(top: 9, left: 18, bottom: 9, right: 18)
        openMedia.addAction(UIAction { [weak self] _ in self?.onOpenMedia() }, for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [icon, title, openMedia])
        column.axis = .vertical
        column.spacing = 14
        column.alignment = .center
        column.setCustomSpacing(16, after: title)
        // 卡片退场：容器完全透明，只做居中容器（宽度钳制保留，防长文案溢出）。
        emptyStateView.backgroundColor = .clear
        emptyStateView.addSubview(column)
        column.snp.makeConstraints { $0.center.equalToSuperview() }
        previewContainer.addSubview(emptyStateView)
        emptyStateView.snp.makeConstraints {
            $0.center.equalToSuperview()
            $0.width.lessThanOrEqualToSuperview().offset(-48)
        }

        // MTK + 选中红框的画布比例约束（一起安装；两者已都在 previewContainer 层级内）。
        applyCanvasAspect()

        // 点按预览 = 播放/暂停（空态时点击落在引导层，不触发）
        let tap = UITapGestureRecognizer(target: self, action: #selector(previewTapped))
        previewContainer.addGestureRecognizer(tap)
    }

    // MARK: - DEBUG 诊断浮层（真机可开：CQ_DEBUG_OVERLAY=1）

    #if DEBUG
    private func updateDebugOverlay(visible: Bool, snapshot: EditorDebugSnapshot?) {
        guard visible else {
            debugOverlayHost?.view.isHidden = true
            return
        }
        // 跨快照更新保持同一状态对象：隐藏/展开不随 2Hz 刷新重置（P138 同款）。
        if debugOverlayState == nil { debugOverlayState = DebugOverlayState() }
        debugOverlayState?.snapshot = snapshot
        guard let state = debugOverlayState else { return }
        if let host = debugOverlayHost {
            host.view.isHidden = false
        } else {
            let root = DebugOverlayView(state: state,
                                        onDrag: { [weak self] dx, dy in
                                            self?.nudgeDebugOverlay(dx: dx, dy: dy)
                                        })
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = true   // 浮层可点按 / 拖动
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            previewContainer.addSubview(host.view)
            // 只钉 top/leading 与宽度上限：高度由 SwiftUI 的 intrinsic 尺寸决定
            // （钉死四边会把内容压成 0 —— P130·b 的同款「布局欠定/过定」坑）。
            // 宽度上限提到 400：面板已放宽到 min(屏宽-16, 380)，原 320 会裁掉内容。
            let top = host.view.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8)
            let leading = host.view.leadingAnchor.constraint(
                equalTo: previewContainer.leadingAnchor, constant: 8)
            NSLayoutConstraint.activate([top, leading])
            host.view.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
            debugOverlayTop = top
            debugOverlayLeading = leading
            host.didMove(toParent: self)
            debugOverlayHost = host
            fputs("[dbg] overlay mounted draggable\n", stderr)
            fflush(stderr)
        }
    }

    /// 拖动浮层：按增量更新位置约束，钳制在 previewContainer 边界内。
    private func nudgeDebugOverlay(dx: CGFloat, dy: CGFloat) {
        guard let top = debugOverlayTop, let leading = debugOverlayLeading else { return }
        let maxX = max(8, previewContainer.bounds.width - 40)
        let maxY = max(8, previewContainer.bounds.height - 40)
        leading.constant = min(max(8, leading.constant + dx), maxX)
        top.constant = min(max(8, top.constant + dy), maxY)
    }
    #endif

    @objc private func previewTapped() {
        guard viewModel.timeline.clips.isEmpty == false else { return }
        viewModel.togglePlayback()
    }

    // MARK: - VM 订阅（Swift 6：全部经 Task @MainActor 回主域读值）

    private func bindViewModel() {
        // 时间线结构变化 → 全量重建层（播放中不发生）
        viewModel.$timeline
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.reloadTimeline() }
            }
            .store(in: &cancellables)

        viewModel.$canUndo
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in
                self?.transportBar.setUndoEnabled(self?.viewModel.canUndo ?? false)
            } }.store(in: &cancellables)
        viewModel.$canRedo
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in
                self?.transportBar.setRedoEnabled(self?.viewModel.canRedo ?? false)
            } }.store(in: &cancellables)

        // 选中态（UIA-039）：分割/删除按钮可用性 + 时间线描边。
        viewModel.$selectedClipId
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshSelectionState() } }
            .store(in: &cancellables)

        // 面板分级（UIA-040）：模式迁移即整条重建；重建后按钮可用性全部回默认值，
        // 必须重推 undo/redo/分割/删除的真实状态。
        viewModel.$toolbarMode
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] mode in Task { @MainActor in
                guard let self else { return }
                // UIA-043：底栏整条重建后撤销/重做不在其中，真实状态推给传输条。
                self.toolbarView.setMode(mode)
                self.transportBar.setUndoEnabled(self.viewModel.canUndo)
                self.transportBar.setRedoEnabled(self.viewModel.canRedo)
                self.toolbarView.setSplitEnabled(self.viewModel.canSplitSelected)
                self.toolbarView.setDeleteEnabled(self.viewModel.selectedClipId != nil)
            } }.store(in: &cancellables)

        // 播放态：传输条图标 + 显示链接启停 + MTK 连续绘制标志
        viewModel.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.syncPlayback() } }
            .store(in: &cancellables)

        // 播放头（播放中 15Hz @Published 兜底；暂停态 seek 也走这里）
        viewModel.$playhead
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.updatePlayheadUI() } }
            .store(in: &cancellables)

        // 预览管线：renderEpoch 变化 → 对当前播放头重取帧（对照
        // MetalPreviewView.updateUIView；preview/previewPump 非 @Published，
        // init 后不变，无需订阅）。isPlaying 的连续绘制标志经 syncPlayback 顺带 sync。
        viewModel.$renderEpoch
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.syncPreview() } }
            .store(in: &cancellables)

        #if DEBUG
        // 诊断浮层（可见性 + 2Hz 快照）。闭包不套 `Task { @MainActor }`：
        // `EditorDebugSnapshot` 未声明 Sendable，塞进 Task 会撞 Swift 6 捕获检查
        // （同 EditorTimelineKitView 的 store/view 事件绑定）。
        Publishers.CombineLatest(viewModel.$debugOverlayVisible, viewModel.$debugSnapshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible, snapshot in
                self?.updateDebugOverlay(visible: visible, snapshot: snapshot)
            }
            .store(in: &cancellables)
        #endif
    }

    /// 非订阅路径的静态首刷（canUndo/redo、空态、时间码、预览 sync）。
    private func refreshStaticState() {
        transportBar.setUndoEnabled(viewModel.canUndo)
        transportBar.setRedoEnabled(viewModel.canRedo)
        refreshSelectionState()
        transportBar.setPlaying(viewModel.isPlaying)
        reloadTimeline()
        updatePlayheadUI()
    }

    /// 选中态灌入（UIA-039）：分割/删除按钮可用性 + 时间线描边 + 预览区红框（U1 S11）。
    /// 选中变化与 reload 都会走这里；播放头变化只影响分割可用性（见 updatePlayheadUI）。
    private func refreshSelectionState() {
        let selected = viewModel.selectedClipId != nil
        toolbarView.setSplitEnabled(viewModel.canSplitSelected)
        toolbarView.setDeleteEnabled(selected)
        timelineView.setSelectedClip(viewModel.selectedClipId)
        previewSelectionBorder.isHidden = !selected
    }

    private func reloadTimeline(force: Bool = false) {
        let assets = Dictionary(uniqueKeysWithValues: viewModel.mediaLibrary.map { ($0.id, $0.path) })
        timelineView.reload(tracks: viewModel.timeline.tracks,
                            clips: viewModel.timeline.clips,
                            assets: assets,
                            playheadSeconds: playheadSeconds,
                            force: force)
        // 重建后选中态重推（VM 侧已保证失效 id 不会灌进来）
        timelineView.setSelectedClip(viewModel.selectedClipId)
        applyCanvasAspect()
        let empty = viewModel.timeline.clips.isEmpty
        emptyStateView.isHidden = !empty
        transportBar.setEnabled(!empty)
        // UIA-043：空态不画刻度尺与播放头（区域保留，避免导入瞬间布局跳动）。
        timelineView.setEmpty(empty)
        syncPreview()
    }

    /// 预览按画布比例取景（UIA-040）：渲染目标已随画布 resize（VM 侧），
    /// 这里把 MTK 宽度钳到「高 × 画布比」—— 预览即画布，两侧留黑边。
    /// 选中红框与 MTK 画布同几何（center + 高满容器 + 宽=aspect×高）。
    /// multiplier 不可变 → 画布变化时整体 remake（SnapKit，ADR-0041）。
    private func applyCanvasAspect() {
        let aspect = max(0.2, min(5.0, viewModel.canvasAspect))
        if let mtk = previewMTKView {
            mtk.snp.remakeConstraints {
                $0.top.bottom.equalTo(previewContainer)
                $0.centerX.equalTo(previewContainer)
                $0.width.equalTo(mtk.snp.height).multipliedBy(aspect)
            }
        }
        previewSelectionBorder.snp.remakeConstraints {
            $0.center.equalTo(previewContainer)
            $0.height.equalTo(previewContainer)
            $0.width.equalTo(previewSelectionBorder.snp.height).multipliedBy(aspect)
        }
    }

    /// 播放头秒值（唯一换算点；红线 #4：其余位置只读 RationalTime 本值）。
    private var playheadSeconds: Double {
        Double(viewModel.playhead.value) / Double(viewModel.playhead.timescale)
    }

    private func syncPlayback() {
        transportBar.setPlaying(viewModel.isPlaying)
        syncDisplayLink()
        syncPreview()
    }

    // MARK: - 每帧驱动（ADR-0024 决定 4）

    private func syncDisplayLink() {
        if viewModel.isPlaying, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(stepDisplayLink))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !viewModel.isPlaying, let link = displayLink {
            link.invalidate()
            displayLink = nil
            updatePlayheadUI()  // 停在终值
        }
    }

    @objc private func stepDisplayLink() {
        updatePlayheadUI()
    }

    private func updatePlayheadUI() {
        let seconds = Double(viewModel.playhead.value) / Double(viewModel.playhead.timescale)
        // 轨道播放头播放中跟随节流上限 40Hz（见 trackPlayheadInterval）；暂停 / seek / 播放结束一律立即推终值。
        let now = CACurrentMediaTime()
        if !viewModel.isPlaying || now - lastTrackPlayheadPush >= Self.trackPlayheadInterval {
            lastTrackPlayheadPush = now
            timelineView.updatePlayhead(seconds: seconds)
        }
        // 播放头移动会改变「能否在播放头处分割」—— 只刷按钮可用性（布尔写，
        // 不触碰层），描边归 refreshSelectionState（选中变化/reload 路径）。
        // 没选中片段时 canSplitSelected 恒 false（它要先按 id 找片段），不必每帧算。
        if viewModel.selectedClipId != nil {
            toolbarView.setSplitEnabled(viewModel.canSplitSelected)
        }
        let text = "\(viewModel.timecodeCurrent) / \(viewModel.timecodeDuration)"
        if text != lastTimecode {
            lastTimecode = text
            transportBar.updateTimecode(current: viewModel.timecodeCurrent,
                                        duration: viewModel.timecodeDuration)
        }
    }

    private func syncPreview() {
        // P142：拖动中 renderEpoch 触发的这次补帧也必须走廉价关键帧，否则它会盖掉
        // onScrub 限频省下来的那一帧、白做一次精确解码（等于限频白设）。
        let policy: PreviewPump.SeekPolicy = isScrubbingTrack ? .keyframeBefore : .exact
        previewMTKView?.sync(preview: viewModel.preview,
                             pump: viewModel.previewPump,
                             pts: viewModel.playhead,
                             continuous: viewModel.isPlaying,
                             renderEpoch: viewModel.renderEpoch,
                             policy: policy)
    }

    // MARK: - Intent → ViewModel 命令（UIA-041/U0）

    /// 取代原先 30 行的 `commitDrag(_:)`。判定全在 reducer、翻译全在
    /// `TrackIntentApplier`，这里只剩一行转发 —— 与 SwiftUI 侧完全对称。
    private func apply(_ intents: [TrackIntent]) {
        guard !intents.isEmpty else { return }
        // 播放中编辑轨道（移动 / 裁剪 / 跨轨）先暂停：播放头继续跑会让刚提交的
        // 位置立刻失效，且「提交后重灌」与「播放推进」会互相打断。
        // 选中不算（UI 本地态，不改模型）—— 播放中点片段不打断播放。
        if intents.contains(where: \.isEditing) {
            viewModel.pausePlayback()
        }
        TrackIntentApplier.apply(intents, to: viewModel)
        // 内核是唯一真源：提交（可能被内核拒绝，拒绝不触发 observer）之后
        // 一律按内核快照重灌轨道区，杜绝「幽灵位置」。
        reloadTimeline(force: true)
    }

    // ⚠️ deinit 不碰 displayLink（Swift 6：deinit 非隔离，不能访问 MainActor 存储）。
    // CADisplayLink target 强持有 self → 生命周期由 viewWillDisappear 上的
    // stopDisplayLink() 兜住（编辑页 dismissal 必经路径）；若未来出现「不经
    // dismissal 的移除」，改 weak 代理 target。
}
#endif
