#if os(iOS)
// EditorViewController — 编辑页 UIKit 容器（UIA-034，ADR-0024）
//
// 竖排三区（对照 SwiftUI 版 verticalLayout）：预览（弹性，直嵌 PreviewMTKView
// + 空态引导/点按播放）→ 传输条 44 → 时间线 140 → 工具栏 58。
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
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transportBar.heightAnchor.constraint(equalToConstant: Theme.Size.transportBarHeight),
            timelineView.heightAnchor.constraint(equalToConstant: Theme.Size.timelineHeightCompact),
            toolbarView.heightAnchor.constraint(equalToConstant: Theme.Size.bottomToolbarHeight),
        ])

        timelineView.onCommitDrag = { [weak self] drag in
            self?.commitDrag(drag)
        }
        transportBar.onTogglePlayback = { [weak self] in
            self?.viewModel.togglePlayback()
        }
        toolbarView.onUndo = { [weak self] in
            self?.viewModel.undo()
            self?.viewModel.refreshFromKernel()
        }
        toolbarView.onRedo = { [weak self] in
            self?.viewModel.redo()
            self?.viewModel.refreshFromKernel()
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
            mtk.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(mtk)
            NSLayoutConstraint.activate([
                mtk.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                mtk.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
                mtk.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                mtk.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            ])
            previewMTKView = mtk
        } else {
            // 预览后端缺失：如实降级（对照 PreviewZone 降级文案），不伪装可用。
            previewFallback.text = "预览不可用\n当前平台缺少预览后端"
            previewFallback.numberOfLines = 0
            previewFallback.textAlignment = .center
            previewFallback.font = .preferredFont(forTextStyle: .subheadline)
            previewFallback.textColor = UIColor(Theme.tertiaryText)
            previewFallback.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(previewFallback)
            NSLayoutConstraint.activate([
                previewFallback.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
                previewFallback.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            ])
        }

        // 空态引导（对照 PreviewZone.emptyStateOverlay）
        let icon = UIImageView(image: UIImage(systemName: "film.stack")?
            .applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 36)))
        icon.tintColor = UIColor(Theme.tertiaryText)
        icon.contentMode = .center
        let title = UILabel()
        title.text = "导入素材开始创作"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = UIColor(Theme.secondaryText)
        title.textAlignment = .center
        let openMedia = UIButton(type: .system)
        openMedia.setTitle("打开素材库", for: .normal)
        openMedia.setImage(UIImage(systemName: "plus"), for: .normal)
        openMedia.tintColor = .white
        openMedia.backgroundColor = UIColor(Theme.accent)
        openMedia.layer.cornerRadius = 8
        openMedia.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        openMedia.addAction(UIAction { [weak self] _ in self?.onOpenMedia() }, for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [icon, title, openMedia])
        column.axis = .vertical
        column.spacing = 12
        column.alignment = .center
        column.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.backgroundColor = UIColor(Theme.previewBackground).withAlphaComponent(0.72)
        emptyStateView.layer.cornerRadius = 16
        emptyStateView.addSubview(column)
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
            emptyStateView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualTo: previewContainer.widthAnchor, constant: -48),
        ])

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
                self?.toolbarView.setUndoEnabled(self?.viewModel.canUndo ?? false)
            } }.store(in: &cancellables)
        viewModel.$canRedo
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in
                self?.toolbarView.setRedoEnabled(self?.viewModel.canRedo ?? false)
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
        toolbarView.setUndoEnabled(viewModel.canUndo)
        toolbarView.setRedoEnabled(viewModel.canRedo)
        transportBar.setPlaying(viewModel.isPlaying)
        reloadTimeline()
        updatePlayheadUI()
    }

    private func reloadTimeline() {
        timelineView.reload(tracks: viewModel.timeline.tracks,
                            clips: viewModel.timeline.clips)
        let empty = viewModel.timeline.clips.isEmpty
        emptyStateView.isHidden = !empty
        transportBar.setEnabled(!empty)
        syncPreview()
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

    // MARK: - 命令提交（语义逐字对照 SwiftUI 版 EditorTimelineView.commit）

    private func commitDrag(_ d: ClipDrag) {
        let ts = RationalTime.projectTimescale
        if d.region == .trimEnd {
            let ticks = Int64((d.previewDuration * Double(ts)).rounded())
            viewModel.trimClip(clipId: d.clipId,
                               duration: RationalTime(value: ticks, timescale: ts))
        } else {
            let ticks = Int64((d.previewStart * Double(ts)).rounded())
            viewModel.moveClip(clipId: d.clipId,
                               to: RationalTime(value: ticks, timescale: ts))
        }
        viewModel.refreshFromKernel()
    }

    // ⚠️ deinit 不碰 displayLink（Swift 6：deinit 非隔离，不能访问 MainActor 存储）。
    // CADisplayLink target 强持有 self → 生命周期由 viewWillDisappear 上的
    // stopDisplayLink() 兜住（编辑页 dismissal 必经路径）；若未来出现「不经
    // dismissal 的移除」，改 weak 代理 target。
}
#endif
