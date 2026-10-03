// SharedUI — 时间线几何布局（UIA-004）
//
// 纯函数：时间 ↔ 像素的全部换算集中在这里，**不触碰 SwiftUI 状态** ——
// 可单测、可 measure（500 片段布局耗时的验收对象，见 TimelineViewTests）。
//
// 设计约束（BACKLOG UIA-004）：时间线**自绘**（单 Canvas），非「一片段一视图」
// 的组件堆叠 —— 数百片段时组件树会拖垮 SwiftUI 渲染，Canvas 一次绘制不受影响。
//
// 时间一律 RationalTime（红线 #4）：布局入口接收已换算好的秒值（Double 秒仅是
// 渲染刻度，不是时间语义的存储形式 —— 存储/提交仍走整数 RationalTime）。

import CoreGraphics
import ChuanqiCut

/// 时间线布局参数与结果。`make` 是唯一构造路径（纯函数）。
struct TimelineLayout {

    /// 每秒多少像素（缩放）。
    let pixelsPerSecond: CGFloat
    /// 水平滚动偏移（秒）。
    let scrollSeconds: Double
    /// 视口尺寸。
    let viewport: CGSize
    /// 轨道行高。
    let trackHeight: CGFloat
    /// 标尺高度。
    let rulerHeight: CGFloat
    /// 轨道数据（显示顺序 = 数组顺序）。
    let tracks: [TrackInfo]
    /// 片段数据（全部轨道）。
    let clips: [ClipInfo]

    // ---- 派生量 ----

    var contentHeight: CGFloat {
        rulerHeight + CGFloat(tracks.count) * (trackHeight + Self.trackSpacing)
            + Self.trackSpacing
    }

    static let trackSpacing: CGFloat = 4

    /// 时间（秒）→ 视口 x 坐标。
    func x(forSeconds s: Double) -> CGFloat {
        CGFloat(s - scrollSeconds) * pixelsPerSecond
    }

    /// 视口 x 坐标 → 时间（秒）。
    func seconds(forX x: CGFloat) -> Double {
        Double(x / pixelsPerSecond) + scrollSeconds
    }

    /// 可见时间窗口（秒）。
    var visibleRange: Range<Double> {
        scrollSeconds..<scrollSeconds + Double(viewport.width / pixelsPerSecond)
    }

    /// 片段矩形（y 已含标尺偏移；行号以 trackId 在 tracks 中的位置定位）。
    /// 完全在视口外的片段返回 nil（布局层的可见裁剪，调用方跳过绘制）。
    func rect(for clip: ClipInfo) -> CGRect? {
        guard let trackRow = tracks.firstIndex(where: { $0.trackId == clip.trackId }) else {
            return nil
        }
        let startSeconds = Double(clip.start.value) / Double(clip.start.timescale)
        let durationSeconds = Double(clip.duration.value) / Double(clip.duration.timescale)
        let x = x(forSeconds: startSeconds)
        let width = CGFloat(durationSeconds) * pixelsPerSecond
        // 完全在视口外（含 1pt 边界容差）→ 跳过
        if x + width < 0 || x > viewport.width + 1 { return nil }
        let y = rulerHeight + CGFloat(trackRow) * (trackHeight + Self.trackSpacing)
        return CGRect(x: x, y: y, width: max(width, 2), height: trackHeight)
    }

    /// 可见片段（已裁剪视口外）。
    var visibleClips: [(clip: ClipInfo, rect: CGRect)] {
        var result: [(ClipInfo, CGRect)] = []
        for clip in clips {
            if let r = rect(for: clip) {
                result.append((clip, r))
            }
        }
        return result
    }

    /// 标尺刻度：返回 (时间秒, 是否主刻度)。步长随缩放自适应，保证相邻刻度 ≥ 60pt。
    func rulerTicks() -> [(second: Double, major: Bool)] {
        var step = 1.0
        let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 300, 600]
        for c in candidates {
            step = c
            if CGFloat(c) * pixelsPerSecond >= 60 { break }
        }
        var ticks: [(Double, Bool)] = []
        let first = (scrollSeconds / step).rounded(.down) * step
        var t = first
        while t <= visibleRange.upperBound {
            if t >= 0 {
                ticks.append((t, abs(t.remainder(dividingBy: step * 5)) < step / 1000))
            }
            t += step
        }
        return ticks
    }

    /// 播放头的 x 坐标。
    func playheadX(playheadSeconds: Double) -> CGFloat {
        x(forSeconds: playheadSeconds)
    }
}
