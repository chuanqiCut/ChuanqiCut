// SharedUI — 时间线自绘视图（UIA-004）+ 拖拽/裁剪交互（UIA-005）
//
// **单 Canvas 绘制全部实体**（BACKLOG：自绘、非组件堆叠 —— 数百片段时
// 组件树会拖垮 SwiftUI，Canvas 一次绘制不受影响）。几何换算全部在
// TimelineLayout（纯函数，可测）。
//
// 数据流：EditorViewModel 订阅内核快照 observer → 版本推进时重查询
// （Session.queryTracks/queryClips，读内核已发布快照，无锁）→ @Published 状态
// → Canvas 重绘。**视图不持有模型、不造假数据**。
//
// 交互（UIA-005）：
//   * 按下时先做命中测试（TimelineLayout.hitTest，纯函数）：
//     命中片段主体 → 拖拽移动；命中右边缘 → 裁剪 duration；未命中 → 平移时间线。
//   * 拖拽期间**不提交命令**（任务卡 D1）：本地 ClipDrag 记录位移，绘制用
//     预览覆盖值；松手时提交**一条** Move/Trim Command。
//     一次拖拽 = 一条命令 —— 否则 Undo 栈会被几十条中间态污染。
//   * 提交后立即 refreshFromKernel()：内核可能拒绝（重叠 / duration ≤ 0），
//     而拒绝不触发 observer 回流 —— 不主动回查就会留下"幽灵位置"。
//     代价：成功时会有一次旧值回弹（observer 随后刷新到新值），
//     这是刻意的选择 —— 正确性优先于动画平滑。
//
// ⚠️ 类型名是 **EditorTimelineView** 而非 TimelineView —— SwiftUI 系统里已有
//    同名的 TimelineView（与 UIA-003 撞名 Preview 完全同类，pitfalls P22）。

import SwiftUI
import ChuanqiCut

// MARK: - 视图模型侧的时间线状态

/// 时间线显示状态（从内核快照查询得来，view 只读）。
public struct TimelineState: Equatable {
    public var tracks: [TrackInfo] = []
    public var clips: [ClipInfo] = []
    /// 快照版本（观察者回流的 version，UI 据此判断要不要重查询）。
    public var version: UInt64 = 0

    /// 手写全默认参构造（声明任意 init 会抑制成员逐项构造器）。
    public init(tracks: [TrackInfo] = [], clips: [ClipInfo] = [], version: UInt64 = 0) {
        self.tracks = tracks
        self.clips = clips
        self.version = version
    }
}

// MARK: - 拖拽状态（UIA-005）

/// 一次拖拽的本地状态。**未提交内核** —— 只是 UI 预览。
///
/// internal（非 private）：夹取规则（负起点 / 过短时长）是容易错的边界，
/// 要能单测（见 TimelineInteractionTests）。
struct ClipDrag {
    let clipId: UInt64
    let region: ClipHitRegion
    /// 拖拽起点：片段原本的 start / duration（秒）。
    let originStart: Double
    let originDuration: Double
    /// 当前时间位移（秒）。
    var deltaSeconds: Double = 0

    /// 最短片段时长（秒）：防止裁剪到 0（内核会拒绝，但 UI 先夹住更直观）。
    static let minDurationSeconds: Double = 0.05

    var previewStart: Double {
        // 裁剪不改起点 —— 位移只作用于时长（否则右边缘拖过左边界会出现负起点）。
        guard region == .move else { return originStart }
        // 起点不允许为负（内核不校验负值，UI 必须先夹住 —— 否则会提交一个
        // 起点为负的片段进去，语义上不属于时间线）。
        return max(0, originStart + deltaSeconds)
    }

    var previewDuration: Double {
        guard region == .trimEnd else { return originDuration }
        return max(Self.minDurationSeconds, originDuration + deltaSeconds)
    }

    var override: ClipPreviewOverride {
        ClipPreviewOverride(clipId: clipId,
                            startSeconds: previewStart,
                            durationSeconds: previewDuration)
    }
}

// MARK: - 时间线视图

public struct EditorTimelineView: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    /// 每秒像素（缩放）。初值让 1 秒 ≈ 80pt。
    @State private var pixelsPerSecond: CGFloat = 80
    /// 水平滚动（秒）。
    @State private var scrollSeconds: Double = 0
    /// 平移拖拽起点的时间偏移（nil = 不在平移中）。
    @State private var scrollAtDragStart: Double?
    /// 片段拖拽（nil = 不在拖拽中）。
    @State private var drag: ClipDrag?

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let layout = TimelineLayout(
                pixelsPerSecond: pixelsPerSecond,
                scrollSeconds: scrollSeconds,
                viewport: geo.size,
                trackHeight: 44,
                rulerHeight: 24,
                tracks: viewModel.timeline.tracks,
                clips: viewModel.timeline.clips)
            let override = drag?.override

            Canvas { context, size in
                draw(layout: layout, override: override, size: size, context: &context)
            }
            .clipped()
            .background(Theme.timelineBackground)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if drag != nil {
                            drag?.deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                        } else if scrollAtDragStart != nil {
                            // 平移时间线：以按下时刻的位置为锚，避免累积漂移
                            let delta = Double(-value.translation.width / pixelsPerSecond)
                            scrollSeconds = max(0, (scrollAtDragStart ?? 0) + delta)
                        } else {
                            // 首次移动：判定这次拖拽是「编辑片段」还是「平移视图」
                            beginDragIfNeeded(at: value.startLocation, layout: layout)
                        }
                    }
                    .onEnded { value in
                        if var d = drag {
                            d.deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                            commit(d)
                            drag = nil
                        }
                        scrollAtDragStart = nil
                    }
            )
        }
    }

    // MARK: 手势

    private func beginDragIfNeeded(at point: CGPoint, layout: TimelineLayout) {
        guard let hit = layout.hitTest(point) else {
            scrollAtDragStart = scrollSeconds  // 空白处 → 平移
            return
        }
        let startSeconds = Double(hit.clip.start.value) / Double(hit.clip.start.timescale)
        let durationSeconds = Double(hit.clip.duration.value) / Double(hit.clip.duration.timescale)
        drag = ClipDrag(clipId: hit.clip.clipId, region: hit.region,
                        originStart: startSeconds, originDuration: durationSeconds)
    }

    /// 松手：提交**一条**命令，并主动回到内核真值（防幽灵位置，见文件头）。
    private func commit(_ d: ClipDrag) {
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

    // MARK: 绘制（全部几何来自 TimelineLayout）

    private func draw(layout: TimelineLayout, override: ClipPreviewOverride?, size: CGSize,
                      context: inout GraphicsContext) {
        // 轨道背景行（交替底色区分轨道）
        for (index, _) in layout.tracks.enumerated() {
            let y = layout.rulerHeight
                + CGFloat(index) * (layout.trackHeight + TimelineLayout.trackSpacing)
            let row = CGRect(x: 0, y: y, width: size.width, height: layout.trackHeight)
            context.fill(Path(row), with: .color(
                index % 2 == 0 ? Theme.timelineTrackA : Theme.timelineTrackB))
        }

        // 标尺
        let ruler = CGRect(x: 0, y: 0, width: size.width, height: layout.rulerHeight)
        context.fill(Path(ruler), with: .color(Theme.timelineRuler))
        for (second, major) in layout.rulerTicks() {
            let x = layout.x(forSeconds: second)
            let line = Path { p in
                p.move(to: CGPoint(x: x, y: layout.rulerHeight - (major ? 10 : 5)))
                p.addLine(to: CGPoint(x: x, y: layout.rulerHeight))
            }
            context.stroke(line, with: .color(Theme.timelineTick), lineWidth: 1)
            if major {
                let text = context.resolve(
                    Text(EditorTimelineView.formatSeconds(second))
                        .font(.caption2.monospaced())
                        .foregroundColor(Theme.secondaryText))
                context.draw(text, at: CGPoint(x: x + 3, y: layout.rulerHeight / 2))
            }
        }

        // 片段（视口外的已在布局层裁剪；拖拽中的片段用本地预览几何）
        for clip in layout.clips {
            guard let rect = layout.rect(for: clip, override: override) else { continue }
            let isDragging = (override?.clipId == clip.clipId)
            let path = Path(roundedRect: rect, cornerRadius: 4)
            context.fill(path, with: .color(
                isDragging ? Theme.timelineClipDragging : Theme.timelineClip))
            context.stroke(path, with: .color(Theme.timelineClipBorder), lineWidth: 1)
            if rect.width > 24 {
                let label = context.resolve(
                    Text("素材 \(clip.assetId)")
                        .font(.caption2)
                        .foregroundColor(Theme.timelineClipLabel))
                context.draw(label, at: CGPoint(x: rect.minX + rect.width / 2,
                                                y: rect.midY))
            }
        }

        // 播放头
        let playheadSeconds = Double(viewModel.playhead.value)
            / Double(viewModel.playhead.timescale)
        let px = layout.playheadX(playheadSeconds: playheadSeconds)
        if px >= 0 && px <= size.width {
            let head = Path { p in
                p.move(to: CGPoint(x: px, y: 0))
                p.addLine(to: CGPoint(x: px, y: size.height))
            }
            context.stroke(head, with: .color(Theme.playhead), lineWidth: 2)
        }
    }

    static func formatSeconds(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
