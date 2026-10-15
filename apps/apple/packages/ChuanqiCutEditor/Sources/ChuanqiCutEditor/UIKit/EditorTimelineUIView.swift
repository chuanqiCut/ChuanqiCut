#if os(iOS)
// EditorTimelineUIView — 时间线 UIKit 自绘（UIA-035/037/038，ADR-0024）
//
// 结构：UIScrollView（水平滚动）+ TimelineContentView（分层 CALayer 内容）+
// **播放头固定覆盖层**（视口中央竖线，不随内容滚动）。
//
// UIA-038 交互范式（对标 App 式，用户 2026-10-07 拍板）：
//   * 红条恒在视口中央 —— 播放/程序化 seek 由 updatePlayhead 设 contentOffset
//     把「播放头时刻」送到中央；用户拖动时间线 = scrub（scrollViewDidScroll →
//     onScrub → VM.setPlayhead，帧栅格取整），播放中不抢播放头。
//   * 捏合缩放以播放头为锚（时间不跳变）：下界 = 全时长入视口、上界 =
//     一帧一个缩略图槽宽（TimelineZoomMath）；几何全量重建（TimelineLayout
//     纯函数 500 片段 0.663ms 量级，真机走查 = 池 [6]）。
//   * 片段内缩略图胶片槽（UIA-037）：每片段 ≥3 帧（ClipFrameSampler），
//     图像异步到达后只写对应槽位 contents —— 主线程零解码。
//
// 交互语义与 SwiftUI 版逐字一致（ADR-0012）：片段拖拽中只更新本地预览层，
// 松手提交一条命令（move/trimEnd）+ refreshFromKernel（防幽灵位置）。
//
// 几何唯一真源仍是 TimelineLayout 纯函数：本视图用「内容坐标」形态
// （scrollSeconds=0、anchorX=前导留白 LEAD=视口宽/2、viewport=contentSize），
// 播放头居中 ⟺ contentOffset.x = LEAD + t·pps − 视口宽/2。

import UIKit
import SnapKit
import ChuanqiCutEngine
import SharedUI  // 基座：Theme（ADR-0031）

@MainActor
final class EditorTimelineUIView: UIView {
    private let scrollView = UIScrollView()
    private let contentView = TimelineContentView(frame: .zero)
    /// 播放头覆盖层：固定视口中央（UIA-038），不进滚动内容。
    private let playheadOverlay = UIView()
    /// U1：播放头顶部小把手（S4；与白条同一 x 中心，贴在轨道区顶端）。
    private let playheadKnob = UIView()
    /// U1（S7）：主轨右端「+」。挂在 **contentView**（滚动内容）上，滑到片尾才出现。
    private let addButton = UIButton(type: .custom)

    /// 每秒像素（缩放）。可经捏合在 [全时长入视口, 一帧一槽] 内变化。
    private(set) var pixelsPerSecond: CGFloat = 80
    private let trackHeight: CGFloat = 44
    private let rulerHeight: CGFloat = 24
    private let viewportHeight: CGFloat = Theme.Size.timelineHeightCompact
    /// 内容尾部余量（裁剪手势空间）。
    private static let trailingMargin: CGFloat = 160

    private var layout: TimelineLayout?
    private var hasClips = false

    // 捏合重建所需的状态快照（reload 时更新）。
    private var lastTracks: [TrackInfo] = []
    private var lastClips: [ClipInfo] = []
    private var lastAssets: [UInt64: String] = [:]
    private var lastPlayheadSeconds: Double = 0
    private var lastDurationSeconds: Double = 0
    private var pinchBasePPS: CGFloat?
    /// 程序化 offset 同步中（抑制 scrub 回环）。
    private var isSyncingOffset = false

    /// 用户拖动时间线 → 播放头时刻（帧栅格已取整；宿主转 VM.setPlayhead）。
    var onScrub: ((Double) -> Void)?
    /// U1（S7）：点击主轨右端「+」→ 追加素材（宿主接既有导入路径，不新增分支）。
    var onRequestAppend: (() -> Void)?
    /// reducer 产出的副作用请求（选中 / 编辑提交）。宿主翻译为 VM 命令。
    /// UIA-041/U0：取代原先的 `onCommitDrag((ClipDrag) -> Void)` —— 回调里带的是
    /// **已判定好的编辑意图**，不是半成品 ClipDrag，宿主不再需要做时序判断。
    var onIntents: (([TrackIntent]) -> Void)?

    /// 抽帧缓存（UIA-037）。视图持有；完成回调只重写槽位 contents。
    private let thumbnailStore = TimelineThumbnailStore()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // UIA-043：与时间线上下两区（传输条/底栏）同底，三区连成一体。
        backgroundColor = EditorChromePalette.chromeBackground.uiColor
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.delegate = self
        addSubview(scrollView)
        scrollView.addSubview(contentView)

        // 片段拖拽 pan：空白处 gestureRecognizerShouldBegin 返回 false，
        // 让 UIScrollView 的原生 pan 接管（= scrub，红条恒中央）。
        let pan = UIPanGestureRecognizer(target: contentView, action: #selector(TimelineContentView.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        contentView.addGestureRecognizer(pan)

        // 点按选中（UIA-039）：与 pan 并存 —— 零位移点按落在 tap 上，拖拽归 pan。
        let tap = UITapGestureRecognizer(target: contentView,
                                         action: #selector(TimelineContentView.handleTap(_:)))
        contentView.addGestureRecognizer(tap)

        // 两个手势共用一条 Intent 出口（UIA-041/U0）。
        contentView.onIntents = { [weak self] intents in self?.handleIntents(intents) }

        // U1（S7）：主轨右端「+」。
        setupAddButton()

        // 捏合缩放（UIA-038）：以播放头为锚，时间不跳变。
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        // 播放头覆盖层（U1：白条 + 顶部小把手，对标 App S4；旧值为 Theme.playhead 红）。
        playheadOverlay.backgroundColor = TimelinePalette.playhead.uiColor
        playheadOverlay.layer.cornerRadius = 1
        playheadOverlay.isUserInteractionEnabled = false
        addSubview(playheadOverlay)

        // 顶部小把手：给「拖时间线」一个视觉抓手（恒定贴在视口中央，随 towrope 层）。
        playheadKnob.backgroundColor = TimelinePalette.playhead.uiColor
        playheadKnob.layer.cornerRadius = TimelinePalette.playheadKnobCornerRadius
        playheadKnob.isUserInteractionEnabled = false
        addSubview(playheadKnob)

        // UIA-042 / ADR-0041：SnapKit DSL（自动 translatesAutoresizingMaskIntoConstraints = false）。
        scrollView.snp.makeConstraints { $0.edges.equalToSuperview() }

        thumbnailStore.onUpdate = { [weak contentView] in
            contentView?.applyThumbnails()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    // MARK: - U1（S7）：主轨右端添加钮


    /// 「+」摆在**内容尾部**（已含 trailingMargin），随内容一起滚动 —— 也就是
    /// 用户把时间线滑到尽头时它才出现。这与对标 App 的行为一致（图3/4/5 里它总在片尾右端）。
    private func setupAddButton() {
        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.tintColor = UIColor(cgColor: TimelinePalette.addButtonGlyph.cgColor)
        setAddButtonStyle()
        addButton.accessibilityLabel = "添加素材"
        addButton.addAction(UIAction { [weak self] _ in self?.onRequestAppend?() },
                            for: .touchUpInside)
        contentView.addSubview(addButton)
    }

    private func setAddButtonStyle() {
        let p = TimelinePalette.addButtonBackground
        addButton.backgroundColor = UIColor(red: p.red, green: p.green,
                                            blue: p.blue, alpha: p.alpha)
        addButton.layer.cornerRadius = TimelinePalette.addButtonCornerRadius
    }

    private func layoutAddButton(contentWidth: CGFloat) {
        let size = TimelinePalette.addButtonSize
        let rowY = rulerHeight
        addButton.frame = CGRect(
            x: contentWidth - Self.trailingMargin + (Self.trailingMargin - size) / 2,
            y: rowY + (trackHeight - size) / 2,
            width: size, height: size)
        addButton.isHidden = !hasClips
        contentView.bringSubviewToFront(addButton)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 白条恒中央：跟随自身尺寸摆放。
        let lineWidth = TimelinePalette.playheadWidth
        let knob = TimelinePalette.playheadKnobSize
        let centerX = (bounds.width - lineWidth) / 2
        playheadOverlay.frame = CGRect(x: centerX, y: 0, width: lineWidth, height: bounds.height)
        playheadKnob.frame = CGRect(x: bounds.width / 2 - knob.width / 2, y: 0,
                                    width: knob.width, height: knob.height)
    }

    // MARK: - 状态灌入（VM 订阅驱动）

    func reload(tracks: [TrackInfo], clips: [ClipInfo], assets: [UInt64: String],
                playheadSeconds: Double) {
        hasClips = !clips.isEmpty
        lastTracks = tracks
        lastClips = clips
        lastAssets = assets
        lastPlayheadSeconds = playheadSeconds
        lastDurationSeconds = clips.map {
            Double($0.start.value) / Double($0.start.timescale)
                + Double($0.duration.value) / Double($0.duration.timescale)
        }.max() ?? 0

        // 前导留白 = 视口宽/2（时间 0 居中所需的滚动余量）。
        let lead = max(bounds.width, 320) / 2
        let minWidth = max(bounds.width, 320)
        let contentWidth = max(minWidth,
                               lead + CGFloat(lastDurationSeconds) * pixelsPerSecond
                               + Self.trailingMargin)
        let contentSize = CGSize(width: contentWidth, height: viewportHeight)
        layout = TimelineLayout(pixelsPerSecond: pixelsPerSecond,
                                scrollSeconds: 0,
                                viewport: contentSize,
                                trackHeight: trackHeight,
                                rulerHeight: rulerHeight,
                                tracks: tracks,
                                clips: clips,
                                anchorX: lead)
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = contentSize
        contentView.rebuild(layout: layout, assets: assets, store: thumbnailStore)
        thumbnailStore.setAssets(assets)
        syncOffset(for: playheadSeconds)
        layoutAddButton(contentWidth: contentSize.width)
    }

    /// 播放头 → 视口中央（CADisplayLink 播放中逐帧驱动 / $playhead 兜底）。
    /// 本方法的全部开销 = 一次 setContentOffset（红条是固定覆盖层，不动）。
    func updatePlayhead(seconds: Double) {
        lastPlayheadSeconds = seconds
        syncOffset(for: seconds)
    }

    /// 选中片段描边（UIA-039；VM $selectedClipId / reloadTimeline 驱动）。
    func setSelectedClip(_ id: UInt64?) {
        contentView.setSelectedClip(id)
    }

    /// UIA-043：空时间线不画刻度尺与播放头（现状空态露一根孤零零的刻度尺 + 白播放头）。
    ///
    /// 高度**保留**（对标 App 编辑器恒定有时间线区域），只把自绘内容与覆盖层隐藏 ——
    /// 避免导入首个片段时布局跳动。⚠️ 隐藏的是 `contentView`（UIView 整体），
    /// **不动任何 layer 层级**（backing layer 铁律，P131）。
    func setEmpty(_ empty: Bool) {
        contentView.isHidden = empty
        playheadOverlay.isHidden = empty
        playheadKnob.isHidden = empty
    }

    /// UIA-041/U0：Intent 出口。本类只把 contentView 的 Intent 原样上行给宿主，
    /// **不做任何判断** —— 判断全在 reducer，命令拼装全在宿主。
    private func handleIntents(_ intents: [TrackIntent]) {
        onIntents?(intents)
    }

    private func syncOffset(for seconds: Double) {
        guard let layout, bounds.width > 0 else { return }
        let lead = layout.anchorX
        let target = max(0, min(scrollView.contentSize.width - bounds.width,
                                lead + CGFloat(seconds) * pixelsPerSecond - bounds.width / 2))
        if abs(scrollView.contentOffset.x - target) < 0.5 { return }
        isSyncingOffset = true
        scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: false)
        isSyncingOffset = false
    }

    // MARK: - 捏合缩放（UIA-038，播放头为锚）

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBasePPS = pixelsPerSecond
        case .changed:
            guard let base = pinchBasePPS, bounds.width > 0 else { return }
            let next = TimelineZoomMath.clamp(base * gesture.scale,
                                              viewportWidth: bounds.width,
                                              durationSeconds: lastDurationSeconds,
                                              frameDuration: TimelineZoomMath.defaultFrameDuration,
                                              thumbnailWidth: ClipFrameSampler.preferredSlotWidth)
            guard abs(next - pixelsPerSecond) > 0.01 else { return }
            pixelsPerSecond = next
            // 几何全量重建（内容坐标随 pps 变化），再按当前播放头时刻重新居中。
            reload(tracks: lastTracks, clips: lastClips, assets: lastAssets,
                   playheadSeconds: lastPlayheadSeconds)
        default:
            pinchBasePPS = nil
        }
    }
}

// MARK: - 滚动 → scrub（UIA-038：拖时间线 = 拖播放头，红条恒中央）

extension EditorTimelineUIView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 程序化同步（播放跟滚 / seek 居中）不回灌播放头。
        guard !isSyncingOffset, let layout, bounds.width > 0 else { return }
        let seconds = Double((scrollView.contentOffset.x + bounds.width / 2 - layout.anchorX)
                             / pixelsPerSecond)
        onScrub?(TimelineZoomMath.snapToFrame(seconds: seconds,
                                              frameDuration: TimelineZoomMath.defaultFrameDuration))
    }
}

// MARK: - 内容视图（分层自绘 + 手势 + 缩略图槽）

@MainActor
final class TimelineContentView: UIView {
    /// ✅ UIA-041/U0：**不再有**：
    ///   * `private var drag: ClipDrag?` / `dragClip` —— 归 `TrackInteractionState`；
    ///   * `handlePan` 里的命中/跨轨位移计算 —— 归 reducer 的 `.dragChanged`。
    ///   本类残存的只有「把 UIPan 的位移喂给 reducer」和「按 Intent 回调宿主」。
    private var trackState = TrackInteractionState.idle
    private var layout: TimelineLayout?
    /// 松手提交（宿主转接 EditorViewController 翻译 Intent → VM 命令）。
    var onIntents: (([TrackIntent]) -> Void)?
    /// 是否命中了片段（UIKit 用它在 gestureRecognizerShouldBegin 里决定
    /// 让不让 UIScrollView 接管 = scrub）。
    private(set) var hitClipId: UInt64?
    /// 选中片段（UI 状态，VM 灌入；rebuild 后按此补描边）。
    private var selectedClipId: UInt64?
    /// U1：选中态附件层（把手 ×2 + 时长数字），每次变化全量重建。
    private var selectionChromeLayers: [CALayer] = []
    /// U1（S2）：轨道头层（每行一个）。
    private var trackHeaderLayers: [CALayer] = []
    private var clipLayers: [UInt64: CALayer] = [:]
    /// 缩略图槽位（UIA-037）：clipId → 采样几何 + 槽层。
    private struct ThumbMeta {
        let assetId: UInt64
        let sampleSeconds: [Double]
        let slotLayers: [CALayer]
    }
    private var thumbMeta: [UInt64: ThumbMeta] = [:]
    private weak var store: TimelineThumbnailStore?

    /// 自绘图层专用容器层。
    ///
    /// ⚠️ **绝不要把自绘层直接加到 `layer` 上**（2026-10-14 真机 SIGSEGV 根因，见 P131）：
    /// `layer` 是 UIView 的 backing layer，**子视图（如主轨右端「+」按钮）的 layer
    /// 也挂在它的 sublayers 里**。当初 rebuild 用 `layer.sublayers?.forEach { $0
    /// .removeFromSuperlayer() }` 全清，等于把子视图的 layer 一起从树上拔掉 ——
    /// UIKit 的 `subviews` 仍持有该 view，但它的 layer 已不在层级中，CA 首次提交
    /// 事务走到这个「有 view / 无 layer」的畸形状态时，`_parentTraitEnvironment →
    /// superview → CALayerGetSuperlayer` 读到野指针直接 SIGSEGV。
    /// 故自绘层一律挂本层，清空只清本层的 sublayers，子视图层永不被触碰。
    private let canvasLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.masksToBounds = true
        layer.addSublayer(canvasLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvasLayer.frame = bounds
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    /// 全量重建（只在 VM 时间线变化 / 捏合缩放时发生；播放中不进此路径）。
    func rebuild(layout: TimelineLayout?, assets: [UInt64: String],
                 store: TimelineThumbnailStore) {
        guard let layout else { return }
        self.layout = layout
        self.store = store
        canvasLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        clipLayers.removeAll()
        thumbMeta.removeAll()
        // sublayers 已全清 —— 附件层的引用必须同步失效，否则会残留孤儿层引用。
        selectionChromeLayers.removeAll()
        trackHeaderLayers.removeAll()

        // 轨道行底色（交替）
        for (index, _) in layout.tracks.enumerated() {
            let y = layout.rulerHeight + CGFloat(index) * (layout.trackHeight + TimelineLayout.trackSpacing)
            let row = CAShapeLayer()
            row.path = UIBezierPath(rect: CGRect(x: 0, y: y, width: frame.width, height: layout.trackHeight)).cgPath
            row.fillColor = UIColor(index % 2 == 0 ? Theme.timelineTrackA : Theme.timelineTrackB).cgColor
            canvasLayer.addSublayer(row)
        }

        // 标尺（底 + ticks + 主要刻度文字）
        let ruler = CAShapeLayer()
        ruler.fillColor = UIColor(Theme.timelineRuler).cgColor
        ruler.frame = CGRect(x: 0, y: 0, width: frame.width, height: layout.rulerHeight)
        ruler.backgroundColor = UIColor(Theme.timelineRuler).cgColor
        canvasLayer.addSublayer(ruler)
        for tick in layout.styledRulerTicks() {
            guard tick.second >= 0 else { continue }
            let x = layout.x(forSeconds: tick.second)
            let tickHeight = tick.isMajor ? TimelinePalette.majorTickHeight
                                          : TimelinePalette.minorTickHeight
            let line = CAShapeLayer()
            line.path = UIBezierPath(rect: CGRect(x: x, y: layout.rulerHeight - tickHeight,
                                                  width: 1, height: tickHeight)).cgPath
            line.fillColor = TimelinePalette.tick.cgColor
            canvasLayer.addSublayer(line)
            if tick.isMajor {
                let text = CATextLayer()
                text.string = EditorTimelineView.formatSeconds(tick.second)
                text.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
                text.fontSize = 10
                text.foregroundColor = TimelinePalette.tickLabel.cgColor
                text.alignmentMode = .left
                text.contentsScale = UIScreen.main.scale
                text.frame = CGRect(x: x + 3, y: (layout.rulerHeight - 12) / 2,
                                    width: 48, height: 12)
                canvasLayer.addSublayer(text)
                // U1：主刻度之间的圆点分隔符（`00:00 · 00:02` 的那个点）。
                if tick.hasDot, let dot = makeTickDot(afterSeconds: tick.second,
                                                      step: tick.dotOffsetSeconds,
                                                      layout: layout) {
                    canvasLayer.addSublayer(dot)
                }
            }
        }

        // 片段层（拖拽中换 timelineClipDragging，对照 SwiftUI 版）
        for clip in layout.clips {
            guard let rect = layout.rect(for: clip) else { continue }
            let container = CALayer()
            container.backgroundColor = UIColor(Theme.timelineClip).cgColor
            container.borderColor = UIColor(Theme.timelineClipBorder).cgColor
            container.borderWidth = 1
            container.cornerRadius = 4
            container.masksToBounds = true
            container.frame = rect
            buildThumbnailSlots(for: clip, in: container, rect: rect, layout: layout)
            if rect.width > 24 {
                let label = CATextLayer()
                label.string = "素材 \(clip.assetId)"
                label.font = UIFont.systemFont(ofSize: 11)
                label.fontSize = 11
                label.foregroundColor = UIColor(Theme.timelineClipLabel).cgColor
                label.alignmentMode = .center
                label.contentsScale = UIScreen.main.scale
                label.frame = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
                label.backgroundColor = UIColor(Theme.timelineClip).withAlphaComponent(0.35).cgColor
                container.addSublayer(label)
            }
            clipLayers[clip.clipId] = container
            canvasLayer.addSublayer(container)
        }
        applySelectionBorder()
        applySelectionChrome()
        buildTrackHeaders()

        canvasLayer.addSublayer(makeSeparator())
    }

    /// 选中态灌入（VM $selectedClipId 驱动；rebuild 后按此补描边）。
    func setSelectedClip(_ id: UInt64?) {
        selectedClipId = id
        applySelectionBorder()
        applySelectionChrome()
    }

    /// 选中白描边（对标 App 范式 ⑤；对照 SwiftUI 版 draw 的 isSelected 分支）。
    private func applySelectionBorder() {
        for (clipId, layer) in clipLayers {
            if clipId == selectedClipId {
                layer.borderColor = TimelinePalette.selectionBorder.cgColor
                layer.borderWidth = TimelinePalette.selectionBorderWidth
            } else {
                layer.borderColor = TimelinePalette.clipBorder.cgColor
                layer.borderWidth = 1
            }
        }
    }

    // MARK: - 选中态附件（U1：把手 + 中央时长数字）

    /// 选中片段的**左右把手 + 中央时长数字**（RESEARCH-017 S3）。
    ///
    /// 与「选中与否」的变化同频调用即可（本层每次全量重建，成本 = 2~3 个 CALayer）。
    /// 拖拽期间不重建：拖拽中片段几何在变，而选中态没变，没必要每帧重算文字。
    private func applySelectionChrome() {
        selectionChromeLayers.forEach { $0.removeFromSuperlayer() }
        selectionChromeLayers.removeAll()
        guard let selectedClipId,
              let clip = layout?.clips.first(where: { $0.clipId == selectedClipId }),
              let rect = layout?.rect(for: clip) else { return }

        // 过窄不画：与 hitTest 的「整体归 move」判定同源（把手热区被同一个阈值吃掉）。
        if rect.width >= TimelinePalette.handleMinimumClipWidth {
            selectionChromeLayers.append(contentsOf: [
                makeHandle(rect: rect, atStart: true),
                makeHandle(rect: rect, atStart: false),
            ])
        }
        if rect.width >= TimelinePalette.durationLabelMinimumClipWidth,
           let label = makeDurationBadge(rect: rect, clip: clip) {
            selectionChromeLayers.append(label)
        }
        selectionChromeLayers.forEach(canvasLayer.addSublayer)
    }

    private func makeHandle(rect: CGRect, atStart: Bool) -> CALayer {
        let handle = CALayer()
        let height = rect.height - TimelinePalette.handleInsetY * 2
        let x = atStart ? 0 : rect.width - TimelinePalette.handleWidth
        handle.frame = CGRect(x: x, y: TimelinePalette.handleInsetY,
                              width: TimelinePalette.handleWidth, height: height)
        handle.backgroundColor = TimelinePalette.selectionBorder.cgColor
        handle.cornerRadius = TimelinePalette.handleCornerRadius
        return handle
    }

    /// 片段中央的时长数字（`3.3s`），带半透明底衬保证在缩略图上也能读。
    private func makeDurationBadge(rect: CGRect, clip: ClipInfo) -> CALayer? {
        let text = CATextLayer()
        let seconds = clip.durationSeconds
        text.string = Self.durationText(seconds)
        text.font = UIFont.monospacedDigitSystemFont(ofSize: TimelinePalette.durationLabelFontSize,
                                                     weight: .semibold)
        text.fontSize = TimelinePalette.durationLabelFontSize
        text.foregroundColor = TimelinePalette.durationLabel.cgColor
        text.alignmentMode = .center
        text.contentsScale = UIScreen.main.scale

        // 宽度按字数估：[E] 0.62em/字符的近似真够本机走查用（问卷校准为准）。
        // [E] 0.62em/字符的宽度估算法 —— 真机走查校准。
        let width = ceil(CGFloat((text.string as? String)?.count ?? 0)
                         * TimelinePalette.durationLabelFontSize * 0.62) + 10
        let height: CGFloat = 16
        text.frame = CGRect(x: (rect.width - width) / 2,
                            y: (rect.height - height) / 2,
                            width: width, height: height)
        text.backgroundColor = TimelinePalette.durationLabelBadge.cgColor
        text.cornerRadius = 3
        return text
    }

    /// 时长文案：对标 App 形如 `3.3s`（一位小数，去尾 0）。
    static func durationText(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }

    /// 片段内胶片槽（UIA-037）：先铺槽位层（空 contents = 底色透出），
    /// 采样请求入库；图像到达经 applyThumbnails 回填。
    private func buildThumbnailSlots(for clip: ClipInfo, in container: CALayer,
                                     rect: CGRect, layout: TimelineLayout) {
        guard let store, rect.width >= 12 else { return }
        let slotWidth = ClipFrameSampler.slotWidth(clipWidth: rect.width,
                                                   preferred: ClipFrameSampler.preferredSlotWidth)
        let count = ClipFrameSampler.sampleCount(slotWidth: slotWidth, clipWidth: rect.width)
        guard count > 0 else { return }
        let sourceIn = Double(clip.sourceIn.value) / Double(clip.sourceIn.timescale)
        let span = Double(clip.duration.value) / Double(clip.duration.timescale)
        let sampleSeconds = ClipFrameSampler.sampleSourceSeconds(sourceIn: sourceIn,
                                                                 span: span, count: count)
        var slotLayers: [CALayer] = []
        slotLayers.reserveCapacity(count)
        for index in 0..<count {
            let slot = CALayer()
            slot.frame = CGRect(x: CGFloat(index) * slotWidth, y: 0,
                                width: slotWidth, height: rect.height)
            slot.contentsGravity = .resizeAspectFill
            slot.isOpaque = false
            container.addSublayer(slot)
            slotLayers.append(slot)
        }
        thumbMeta[clip.clipId] = ThumbMeta(assetId: clip.assetId,
                                           sampleSeconds: sampleSeconds,
                                           slotLayers: slotLayers)
        store.requestSamples(assetId: clip.assetId, sourceSeconds: sampleSeconds)
    }

    /// 抽帧完成回调（store.onUpdate）：只写槽位 contents，零布局计算。
    func applyThumbnails() {
        guard let store else { return }
        for meta in thumbMeta.values {
            let slots = meta.slotLayers.count
            for (index, slot) in meta.slotLayers.enumerated() {
                let sampleIndex = ClipFrameSampler.slotSampleIndex(slot: index, slots: slots,
                                                                   samples: meta.sampleSeconds.count)
                slot.contents = store.cachedImage(assetId: meta.assetId,
                                                  sourceSecond: meta.sampleSeconds[sampleIndex])
            }
        }
    }

    /// U1：主刻度文字与下一个主刻度之间的圆点分隔符。
    /// `dotOffsetSeconds` = 步长的一半 → 落在两相邻主刻度正中；
    /// 间距不足 [E] 24pt 时不画（否则密刻度下会糊成一条线）—— 走查校准。
    private func makeTickDot(afterSeconds second: Double, step: Double,
                             layout: TimelineLayout) -> CALayer? {
        guard step > 0, CGFloat(step) * layout.pixelsPerSecond >= 48 else { return nil }
        let dotSeconds = second + step / 2
        guard dotSeconds <= layout.visibleRange.upperBound else { return nil }
        let r = TimelinePalette.tickDotRadius
        let x = layout.x(forSeconds: dotSeconds)
        let dot = CAShapeLayer()
        dot.path = UIBezierPath(ovalIn: CGRect(x: x - r, y: layout.rulerHeight / 2 - r,
                                               width: r * 2, height: r * 2)).cgPath
        dot.fillColor = TimelinePalette.tickLabel.cgColor
        return dot
    }

    // MARK: - U1（S2）：轨道头（主轨行左端）

    /// 轨道头：显示**真实回读值**的原声状态 + 「设置封面」占位。
    ///
    /// ⚠️ **刻意做成不可点的 disabled 态，不做假开关**（任务卡约定）：
    /// `CQTrackInfo.muted` 目前**只能读不能写** —— 内核 `cq_sdk.cpp:488` 单向把它填出，
    /// 全仓搜不到任何 `cq_session_set_track_muted` 之类的写入 ABI（2026-10-13 核）。
    /// 做成能点的开关就会是「点了没反应」的假功能（违背 ADR-0034）。
    /// 欠账已登记：`docs/pool` 池 [19] —— ABI 到位后此处一行改回去即可点亮。
    ///
    /// 它仍然有价值：信息架构到位 + 显示的是**真实状态**（不是写死的默认），
    /// ABI 来了直接去掉 disabled。
    private func buildTrackHeaders() {
        trackHeaderLayers.forEach { $0.removeFromSuperlayer() }
        trackHeaderLayers.removeAll()
        guard let layout = layout else { return }
        for (index, track) in layout.tracks.enumerated() {
            let y = layout.rulerHeight + CGFloat(index) * (layout.trackHeight + TimelineLayout.trackSpacing)
            let header = CAShapeLayer()
            header.frame = CGRect(x: 0, y: y, width: TimelinePalette.trackHeaderWidth,
                                  height: layout.trackHeight)
            header.path = UIBezierPath(rect: header.bounds).cgPath
            header.fillColor = TimelinePalette.trackHeaderBackground.cgColor
            canvasLayer.addSublayer(header)
            trackHeaderLayers.append(header)

            // 原声状态：回读内核真值（只读，不可点）。
            let status = CATextLayer()
            status.string = track.muted ? "原声关" : "原声开"
            status.font = UIFont.systemFont(ofSize: TimelinePalette.trackHeaderFontSize,
                                            weight: .medium)
            status.fontSize = TimelinePalette.trackHeaderFontSize
            status.foregroundColor = TimelinePalette.trackHeaderGlyph.withAlpha(track.muted ? 0.5 : 0.9).cgColor
            status.alignmentMode = .left
            status.contentsScale = UIScreen.main.scale
            status.frame = CGRect(x: 4, y: (layout.trackHeight - 12) / 2,
                                  width: TimelinePalette.trackHeaderWidth - 8, height: 12)
            header.addSublayer(status)
        }
    }

    /// 标尺与轨道区的分隔线（原播放头层的陪衬，保持视觉分层）。
    private func makeSeparator() -> CALayer {
        let separator = CALayer()
        separator.frame = CGRect(x: 0, y: layout?.rulerHeight ?? 0, width: frame.width, height: 1)
        separator.backgroundColor = UIColor(Theme.timelineTick).cgColor
        return separator
    }

    // MARK: - 手势（UIA-041/U0：只做「原始回调 → TrackGestureEvent」的翻译）

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, trackState.drag == nil else {
            return trackState.drag != nil  // 拖拽中不让滚动抢
        }
        // 空白处 → 平移视图（= scrub，UIA-038；返回 false 让 UIScrollView 接管）
        let point = pan.location(in: self)
        guard let layout else { return false }
        // UIA-041/U0：判定本身也在 TrackInteraction 域里（此处会委托给同一份定义）。
        return TrackInteraction.ownsPan(at: point, layout: layout, state: trackState)
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let layout else { return }
        forward(TrackInteraction.reduce(&trackState,
                                       event: .tap(location: gesture.location(in: self)),
                                       layout: layout))
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let layout else { return }
        let point = gesture.translation(in: self)
        let translation = CGSize(width: point.x, height: point.y)
        switch gesture.state {
        case .began:
            let begin = TrackInteraction.reduce(
                &trackState, event: .dragBegan(location: gesture.location(in: self)),
                layout: layout)
            hitClipId = trackState.drag?.clipId
            forward(begin)
        case .changed:
            forward(TrackInteraction.reduce(&trackState,
                                            event: .dragChanged(translation: translation),
                                            layout: layout))
            applyDragPreview()
        case .ended:
            // 语义：.ended 可能产出一条 .commitEdit；零位移则不产出（reducer 统一守卫）——
            //    提交一条同值 move/trim 只会给撤销栈塞垃圾。此前此守卫只在 UIKit 侧存在，
            //    SwiftUI 侧无条件提交，U0 把它收进 reducer 后两侧行为一致。
            forward(TrackInteraction.reduce(&trackState,
                                            event: .dragEnded(translation: translation),
                                            layout: layout))
            // 无论是否提交：手势结束都不再本地预览，回到内核真值（宿主 reload 会刷新）。
            hitClipId = nil
            restoreDraggedLayer()
        case .cancelled:
            forward(TrackInteraction.reduce(&trackState, event: .dragCancelled, layout: layout))
            hitClipId = nil
            restoreDraggedLayer()
        default:
            break
        }
    }

    private func forward(_ intents: [TrackIntent]) {
        guard !intents.isEmpty else { return }
        onIntents?(intents)
    }

    /// 本地预览：按 reducer 派生的渲染态挪片段层（不提交内核，ADR-0012）。
    private func applyDragPreview() {
        let render = TrackInteraction.renderState(trackState)
        guard let draggedId = render.draggingClipId else { return }
        guard let clip = layout?.clips.first(where: { $0.clipId == draggedId }) else { return }
        guard let rect = layout?.rect(for: clip, override: render.override,
                                      rowOverride: render.rowOverride),
              let layer = clipLayers[draggedId] else { return }
        layer.frame = rect
        layer.backgroundColor = UIColor(Theme.timelineClipDragging).cgColor
    }

    /// 手势结束：把本地预览过的层按内核真值复位（预览色回正、frame 回真值）。
    /// `ids` = 拖拽过程中被改过外观的片段；不传则整体复位（保险路径）。
    private func restoreDraggedLayer(_ ids: Set<UInt64>? = nil) {
        guard let layout else { return }
        for (clipId, layer) in clipLayers {
            if let ids, !ids.contains(clipId) { continue }
            guard let clip = layout.clips.first(where: { $0.clipId == clipId }),
                  let rect = layout.rect(for: clip) else { continue }
            layer.frame = rect
            layer.backgroundColor = UIColor(Theme.timelineClip).cgColor
        }
    }
}
#endif
