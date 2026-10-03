// SharedUI — 时间线自绘视图（UIA-004）
//
// **单 Canvas 绘制全部实体**（BACKLOG：自绘、非组件堆叠 —— 数百片段时
// 组件树会拖垮 SwiftUI，Canvas 一次绘制不受影响）。几何换算全部在
// TimelineLayout（纯函数，可测）。
//
// 数据流：EditorViewModel 订阅内核快照 observer → 版本推进时重查询
// （Session.queryTracks/queryClips，读内核已发布快照，无锁）→ @Published 状态
// → Canvas 重绘。**视图不持有模型、不造假数据**。
//
// 本任务（UIA-004）只做显示：缩放 / 滚动 / 播放头。拖拽、裁剪、选择
// 归 UIA-005（届时提交 Move/Trim Command，MODEL-002 已就绪）。
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

// MARK: - 时间线视图

public struct EditorTimelineView: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    /// 每秒像素（缩放）。初值让 1 秒 ≈ 80pt。
    @State private var pixelsPerSecond: CGFloat = 80
    /// 水平滚动（秒）。
    @State private var scrollSeconds: Double = 0
    /// 拖拽起点的时间偏移（nil = 不在拖拽中）。
    @State private var scrollAtDragStart: Double?

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

            Canvas { context, size in
                draw(layout: layout, size: size, context: &context)
            }
            .clipped()
            .background(Theme.timelineBackground)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // 拖拽平移时间线：以按下时刻的位置为锚，避免累积漂移
                        if scrollAtDragStart == nil { scrollAtDragStart = scrollSeconds }
                        let delta = Double(-value.translation.width / pixelsPerSecond)
                        scrollSeconds = max(0, (scrollAtDragStart ?? 0) + delta)
                    }
                    .onEnded { _ in scrollAtDragStart = nil }
            )
        }
    }

    // MARK: 绘制（全部几何来自 TimelineLayout）

    private func draw(layout: TimelineLayout, size: CGSize,
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

        // 片段（视口外的已在布局层裁剪）
        for (clip, rect) in layout.visibleClips {
            let path = Path(roundedRect: rect, cornerRadius: 4)
            context.fill(path, with: .color(Theme.timelineClip))
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
