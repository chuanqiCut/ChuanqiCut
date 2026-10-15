#if os(iOS)
// EditorViewController — 编辑页 UIKit 容器（UIA-034，ADR-0024）
//
// 竖排三区（对照 SwiftUI 版 verticalLayout）：预览（弹性，直嵌 PreviewMTKView
// + 空态引导/点按播放）→ 传输条 44 → 时间线 140 → 工具栏 84（UIA-043：58 → 84）。
//
// UIA-043（对标 App 单色系视觉改版，纯视觉 + 出口迁移，**零交互变更**）：
//   * 底栏 84 / 图标 22；撤销·重做**迁到传输条**（与播放、时间码同栏）；
//   * 空态去掉悬浮卡片，元素直接落在预览区，主操作白底黑字；
//   * 空时间线不画刻度尺与播放头（EditorTimelineUIView.setEmpty）。
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
    private let timelineView = EditorTimelineUIView()
    private let toolbarView = EditorToolbarUIView()
    /// U1（S11）：预览区选中红框。贴在预览画布外沿，默认隐藏。
    private let previewSelectionBorder = UIView()

    /// 时间码去抖（60fps 直更只在文本变化时写 label）。
    private var lastTimecode = ""
    /// 上次布局宽度（viewDidLayoutSubviews 重算时间线内容宽度的变化检测）。
    private var lastBoundsWidth: CGFloat = 0

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
        // U1（S7）：主轨右端「+」→ 打开素材选择（复用既有导入路径，不新增分支）。
        timelineView.onRequestAppend = { [weak self] in self?.onOpenMedia() }
        // 拖时间线 = 拖播放头（UIA-038，红条恒中央）；播放中不抢播放头。
        timelineView.onScrub = { [weak self] seconds in
            guard let self, !self.viewModel.isPlaying else { return }
            let ts = RationalTime.projectTimescale
            let ticks = Int64((seconds * Double(ts)).rounded())
            self.viewModel.setPlayhead(RationalTime(value: ticks, timescale: ts))
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

    private func reloadTimeline() {
        let assets = Dictionary(uniqueKeysWithValues: viewModel.mediaLibrary.map { ($0.id, $0.path) })
        timelineView.reload(tracks: viewModel.timeline.tracks,
                            clips: viewModel.timeline.clips,
                            assets: assets,
                            playheadSeconds: playheadSeconds)
        // rebuild 清空全部层 → 选中描边重刷（VM 侧已保证失效 id 不会灌进来）
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
        timelineView.updatePlayhead(seconds: seconds)
        // 播放头移动会改变「能否在播放头处分割」—— 只刷按钮可用性（布尔写，
        // 不触碰层），描边归 refreshSelectionState（选中变化/reload 路径）。
        toolbarView.setSplitEnabled(viewModel.canSplitSelected)
        let text = "\(viewModel.timecodeCurrent) / \(viewModel.timecodeDuration)"
        if text != lastTimecode {
            lastTimecode = text
            transportBar.updateTimecode(current: viewModel.timecodeCurrent,
                                        duration: viewModel.timecodeDuration)
        }
    }

    private func syncPreview() {
        previewMTKView?.sync(preview: viewModel.preview,
                             pump: viewModel.previewPump,
                             pts: viewModel.playhead,
                             continuous: viewModel.isPlaying,
                             renderEpoch: viewModel.renderEpoch)
    }

    // MARK: - Intent → ViewModel 命令（UIA-041/U0）

    /// 取代原先 30 行的 `commitDrag(_:)`。判定全在 reducer、翻译全在
    /// `TrackIntentApplier`，这里只剩一行转发 —— 与 SwiftUI 侧完全对称。
    private func apply(_ intents: [TrackIntent]) {
        guard !intents.isEmpty else { return }
        TrackIntentApplier.apply(intents, to: viewModel)
    }

    // ⚠️ deinit 不碰 displayLink（Swift 6：deinit 非隔离，不能访问 MainActor 存储）。
    // CADisplayLink target 强持有 self → 生命周期由 viewWillDisappear 上的
    // stopDisplayLink() 兜住（编辑页 dismissal 必经路径）；若未来出现「不经
    // dismissal 的移除」，改 weak 代理 target。
}
#endif
