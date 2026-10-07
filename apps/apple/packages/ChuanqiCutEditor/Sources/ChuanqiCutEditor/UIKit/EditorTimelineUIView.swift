#if os(iOS)
// EditorTimelineUIView — 时间线 UIKit 自绘（UIA-035，ADR-0024 卡顿修复主体）
//
// 结构：UIScrollView（水平滚动）+ TimelineContentView（分层 CALayer）：
//   轨道行底色层 / 标尺层（ticks + CATextLayer）/ 逐片段容器层（拖拽中换色）
//   / **播放头独立 CAShapeLayer** —— CADisplayLink 每帧只改它的 path，
//   SwiftUI 零参与（ADR-0024 决定 4；对照旧 SwiftUI 单 Canvas 全量重绘）。
//
// 几何唯一真源仍是 TimelineLayout 纯函数（scrollSeconds=0、viewport=contentSize
// 的绝对坐标形态）；hitTest/rect/playheadX/rulerTicks 原样复用。
// 交互语义与 SwiftUI 版逐字一致（ADR-0012）：拖拽中只更新本地预览层，
// 松手提交一条命令（move/trimEnd）+ refreshFromKernel（防幽灵位置）。

import UIKit
import ChuanqiCutEngine
import SharedUI  // 基座：Theme（ADR-0031）

@MainActor
final class EditorTimelineUIView: UIView {
    private let scrollView = UIScrollView()
    private let contentView = TimelineContentView(frame: .zero)

    /// 每秒像素（缩放）。与 SwiftUI 版初值一致（1 秒 ≈ 80pt）；捏合缩放归后续任务。
    private let pixelsPerSecond: CGFloat = 80
    private let trackHeight: CGFloat = 44
    private let rulerHeight: CGFloat = 24
    private let viewportHeight: CGFloat = Theme.Size.timelineHeightCompact

    private var layout: TimelineLayout?
    private var hasClips = false

    var onCommitDrag: ((ClipDrag) -> Void)?

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
        // 让 UIScrollView 的原生 pan 接管（平移视图）。
        let pan = UIPanGestureRecognizer(target: contentView, action: #selector(TimelineContentView.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        contentView.addGestureRecognizer(pan)
        contentView.onCommitDrag = { [weak self] drag in self?.onCommitDrag?(drag) }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    // MARK: - 状态灌入（VM 订阅驱动）

    func reload(tracks: [TrackInfo], clips: [ClipInfo]) {
        hasClips = !clips.isEmpty
        // 内容宽度：至少一屏，随最远片段扩展（右留 160pt 余量给裁剪手势）
        let endSeconds = clips.map { Double($0.start.value) / Double($0.start.timescale)
                                   + Double($0.duration.value) / Double($0.duration.timescale) }
                          .max() ?? 0
        let minWidth = max(bounds.width, 320)
        let contentWidth = max(minWidth, CGFloat(endSeconds) * pixelsPerSecond + 160)
        let contentSize = CGSize(width: contentWidth, height: viewportHeight)
        layout = TimelineLayout(pixelsPerSecond: pixelsPerSecond,
                                scrollSeconds: 0,
                                viewport: contentSize,
                                trackHeight: trackHeight,
                                rulerHeight: rulerHeight,
                                tracks: tracks,
                                clips: clips)
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = contentSize
        contentView.rebuild(layout: layout)
    }

    /// CADisplayLink / $playhead 直驱：只更新播放头层 path（本方法的全部开销）。
    func updatePlayhead(seconds: Double) {
        guard let layout else { return }
        let px = layout.playheadX(playheadSeconds: seconds)
        contentView.updatePlayhead(x: px, height: viewportHeight)
        // 播放头出视口右侧时跟滚（剪映行为；不回弹左侧，避免打扰回看）
        let visibleRight = scrollView.contentOffset.x + scrollView.bounds.width
        if px > visibleRight - 40 {
            scrollView.setContentOffset(CGPoint(x: max(0, px - scrollView.bounds.width + 40),
                                                y: 0), animated: false)
        }
    }
}

// MARK: - 内容视图（分层自绘 + 手势）

@MainActor
final class TimelineContentView: UIView {
    private var layout: TimelineLayout?
    private var drag: ClipDrag?
    /// 拖拽中的片段真值（began 时捕获；.changed 用它做本地预览几何）
    private var dragClip: ClipInfo?
    private let playheadLayer = CAShapeLayer()
    /// 松手提交（宿主转接 EditorViewController.commitDrag）
    var onCommitDrag: ((ClipDrag) -> Void)?
    private var clipLayers: [UInt64: CALayer] = [:]
    private var lastPlayheadX: CGFloat = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.masksToBounds = true
        playheadLayer.strokeColor = UIColor(Theme.playhead).cgColor
        playheadLayer.fillColor = UIColor.clear.cgColor
        playheadLayer.lineWidth = 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    /// 全量重建（只在 VM 时间线变化时发生；播放中不进此路径）。
    func rebuild(layout: TimelineLayout?) {
        guard let layout else { return }
        self.layout = layout
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        clipLayers.removeAll()

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
            if rect.width > 24 {
                let label = CATextLayer()
                label.string = "素材 \(clip.assetId)"
                label.font = UIFont.systemFont(ofSize: 11)
                label.fontSize = 11
                label.foregroundColor = UIColor(Theme.timelineClipLabel).cgColor
                label.alignmentMode = .center
                label.contentsScale = UIScreen.main.scale
                label.frame = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
                container.addSublayer(label)
            }
            clipLayers[clip.clipId] = container
            layer.addSublayer(container)
        }

        // 播放头（独立层：每帧只动它）
        playheadLayer.frame = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        layer.addSublayer(playheadLayer)
        lastPlayheadX = -1
    }

    /// CADisplayLink 直驱：只更新播放头 path。
    func updatePlayhead(x: CGFloat, height: CGFloat) {
        guard x != lastPlayheadX else { return }
        lastPlayheadX = x
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: height))
        playheadLayer.path = path.cgPath
    }

    // MARK: - 手势（语义对照 SwiftUI 版 EditorTimelineView）

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, drag == nil else {
            return drag != nil  // 拖拽中不让滚动抢
        }
        // 空白处 → 平移视图（返回 false 让 UIScrollView 原生 pan 接管）
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

extension EditorTimelineUIView: UIScrollViewDelegate {}
#endif
