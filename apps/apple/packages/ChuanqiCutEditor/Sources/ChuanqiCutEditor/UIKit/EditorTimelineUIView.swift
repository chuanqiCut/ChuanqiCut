#if os(iOS)
// EditorTimelineUIView — 时间线 UIKit 自绘（UIA-035/037/038，ADR-0024）
//
// 结构：UIScrollView（水平滚动）+ TimelineContentView（分层 CALayer 内容）+
// **播放头固定覆盖层**（视口中央竖线，不随内容滚动）。
//
// UIA-038 交互范式（剪映式，用户 2026-10-07 拍板）：
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
import ChuanqiCutEngine
import SharedUI  // 基座：Theme（ADR-0031）

@MainActor
final class EditorTimelineUIView: UIView {
    private let scrollView = UIScrollView()
    private let contentView = TimelineContentView(frame: .zero)
    /// 播放头覆盖层：固定视口中央（UIA-038），不进滚动内容。
    private let playheadOverlay = UIView()

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
    var onCommitDrag: ((ClipDrag) -> Void)?

    /// 抽帧缓存（UIA-037）。视图持有；完成回调只重写槽位 contents。
    private let thumbnailStore = TimelineThumbnailStore()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.timelineBackground)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
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
        contentView.onCommitDrag = { [weak self] drag in self?.onCommitDrag?(drag) }

        // 捏合缩放（UIA-038）：以播放头为锚，时间不跳变。
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        // 播放头覆盖层（红条）：2pt，恒在视口水平中央，全高。
        playheadOverlay.backgroundColor = UIColor(Theme.playhead)
        playheadOverlay.layer.cornerRadius = 1
        playheadOverlay.isUserInteractionEnabled = false
        addSubview(playheadOverlay)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        thumbnailStore.onUpdate = { [weak contentView] in
            contentView?.applyThumbnails()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 红条恒中央：跟随自身尺寸摆放。
        playheadOverlay.frame = CGRect(x: (bounds.width - 2) / 2, y: 0, width: 2, height: bounds.height)
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
    }

    /// 播放头 → 视口中央（CADisplayLink 播放中逐帧驱动 / $playhead 兜底）。
    /// 本方法的全部开销 = 一次 setContentOffset（红条是固定覆盖层，不动）。
    func updatePlayhead(seconds: Double) {
        lastPlayheadSeconds = seconds
        syncOffset(for: seconds)
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
    private var layout: TimelineLayout?
    private var drag: ClipDrag?
    /// 拖拽中的片段真值（began 时捕获；.changed 用它做本地预览几何）
    private var dragClip: ClipInfo?
    /// 松手提交（宿主转接 EditorViewController.commitDrag）
    var onCommitDrag: ((ClipDrag) -> Void)?
    private var clipLayers: [UInt64: CALayer] = [:]
    /// 缩略图槽位（UIA-037）：clipId → 采样几何 + 槽层。
    private struct ThumbMeta {
        let assetId: UInt64
        let sampleSeconds: [Double]
        let slotLayers: [CALayer]
    }
    private var thumbMeta: [UInt64: ThumbMeta] = [:]
    private weak var store: TimelineThumbnailStore?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    /// 全量重建（只在 VM 时间线变化 / 捏合缩放时发生；播放中不进此路径）。
    func rebuild(layout: TimelineLayout?, assets: [UInt64: String],
                 store: TimelineThumbnailStore) {
        guard let layout else { return }
        self.layout = layout
        self.store = store
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        clipLayers.removeAll()
        thumbMeta.removeAll()

        // 轨道行底色（交替）
        for (index, _) in layout.tracks.enumerated() {
            let y = layout.rulerHeight + CGFloat(index) * (layout.trackHeight + TimelineLayout.trackSpacing)
            let row = CAShapeLayer()
            row.path = UIBezierPath(rect: CGRect(x: 0, y: y, width: frame.width, height: layout.trackHeight)).cgPath
            row.fillColor = UIColor(index % 2 == 0 ? Theme.timelineTrackA : Theme.timelineTrackB).cgColor
            layer.addSublayer(row)
        }

        // 标尺（底 + ticks + 主要刻度文字）
        let ruler = CAShapeLayer()
        ruler.fillColor = UIColor(Theme.timelineRuler).cgColor
        ruler.frame = CGRect(x: 0, y: 0, width: frame.width, height: layout.rulerHeight)
        ruler.backgroundColor = UIColor(Theme.timelineRuler).cgColor
        layer.addSublayer(ruler)
        for (second, major) in layout.rulerTicks() {
            guard second >= 0 else { continue }
            let x = layout.x(forSeconds: second)
            let tick = CAShapeLayer()
            tick.path = UIBezierPath(rect: CGRect(x: x, y: layout.rulerHeight - (major ? 10 : 5),
                                                  width: 1, height: major ? 10 : 5)).cgPath
            tick.fillColor = UIColor(Theme.timelineTick).cgColor
            layer.addSublayer(tick)
            if major {
                let text = CATextLayer()
                text.string = EditorTimelineView.formatSeconds(second)
                text.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
                text.fontSize = 10
                text.foregroundColor = UIColor(Theme.secondaryText).cgColor
                text.alignmentMode = .left
                text.contentsScale = UIScreen.main.scale
                text.frame = CGRect(x: x + 3, y: (layout.rulerHeight - 12) / 2, width: 48, height: 12)
                layer.addSublayer(text)
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
            layer.addSublayer(container)
        }

        layer.addSublayer(makeSeparator())
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

    /// 标尺与轨道区的分隔线（原播放头层的陪衬，保持视觉分层）。
    private func makeSeparator() -> CALayer {
        let separator = CALayer()
        separator.frame = CGRect(x: 0, y: layout?.rulerHeight ?? 0, width: frame.width, height: 1)
        separator.backgroundColor = UIColor(Theme.timelineTick).cgColor
        return separator
    }

    // MARK: - 手势（语义对照 SwiftUI 版 EditorTimelineView）

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, drag == nil else {
            return drag != nil  // 拖拽中不让滚动抢
        }
        // 空白处 → 平移视图（= scrub，UIA-038；返回 false 让 UIScrollView 接管）
        let point = pan.location(in: self)
        guard let layout else { return false }
        return layout.hitTest(point) != nil
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let layout else { return }
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let hit = layout.hitTest(location) else { return }
            let startSeconds = Double(hit.clip.start.value) / Double(hit.clip.start.timescale)
            let durationSeconds = Double(hit.clip.duration.value) / Double(hit.clip.duration.timescale)
            drag = ClipDrag(clipId: hit.clip.clipId, region: hit.region,
                            originStart: startSeconds, originDuration: durationSeconds)
            dragClip = hit.clip
        case .changed:
            guard var d = drag else { return }
            d.deltaSeconds = Double(gesture.translation(in: self).x / layout.pixelsPerSecond)
            drag = d
            // 本地预览：直接挪片段层（不提交内核，ADR-0012）
            guard let clip = dragClip else { return }
            let preview = ClipPreviewOverride(clipId: d.clipId,
                                              startSeconds: d.previewStart,
                                              durationSeconds: d.previewDuration)
            if let rect = layout.rect(for: clip, override: preview), let layer = clipLayers[d.clipId] {
                layer.frame = rect
                layer.backgroundColor = UIColor(Theme.timelineClipDragging).cgColor
            }
        case .ended, .cancelled:
            // 语义对照 SwiftUI 版：.ended 无条件提交一条命令（零位移 = 内核拒绝/
            // 无变化，无撤销污染）；.cancelled 不提交、直接复位（VM reload 恢复真值）。
            if let d = drag, gesture.state == .ended { onCommitDrag?(d) }
            drag = nil
            dragClip = nil
        default:
            break
        }
    }
}
#endif
