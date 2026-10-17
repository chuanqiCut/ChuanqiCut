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
import ChuanqiCutEngine

/// 拖拽/裁剪期间的**本地几何覆盖**（UIA-005）。
///
/// 拖拽期间不提交命令（结束时才提交一次，见任务卡 D1），故片段的"当前形状"
/// 是 UI 本地状态，不是内核模型。绘制与命中测试都必须能带上它，否则
/// 「看到的矩形」与「按下去命中的矩形」会不一致。
struct ClipPreviewOverride: Equatable {
    let clipId: UInt64
    let startSeconds: Double
    let durationSeconds: Double
}

/// 命中到的片段区域。
enum ClipHitRegion: Equatable {
    /// 片段主体 → 拖拽移动（改 start）。
    case move
    /// 左边缘 → 左缘裁剪（改 start / sourceIn，右缘不动；EDIT-008）。
    case trimStart
    /// 右边缘 → 裁剪（改 duration）。
    case trimEnd
}

struct TimelineHit: Equatable {
    let clip: ClipInfo
    let region: ClipHitRegion
}

/// 时间线布局参数与结果。`make` 是唯一构造路径（纯函数）。
///
/// `anchorX`（UIA-038 居中播放头）：`scrollSeconds` 时刻在坐标系里的 x 位置。
///   * SwiftUI 路径（视口坐标）：scrollSeconds = 播放头时刻，anchorX = 视口宽/2
///     —— 播放头恒在中央，画面随播放头铺开；
///   * UIKit 路径（内容坐标）：scrollSeconds = 0，anchorX = 前导留白（= 视口宽/2
///     的内容侧镜像），滚动偏移负责把「播放头时刻」送到视口中央。
///   两种形态共用同一套 rect/hitTest/刻度换算。
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
    /// `scrollSeconds` 时刻的 x 坐标（UIA-038，默认 0 = 既有行为）。
    var anchorX: CGFloat = 0

    // ---- 派生量 ----

    var contentHeight: CGFloat {
        rulerHeight + CGFloat(tracks.count) * (trackHeight + Self.trackSpacing)
            + Self.trackSpacing
    }

    static let trackSpacing: CGFloat = 4

    /// 时间（秒）→ 坐标系 x。
    func x(forSeconds s: Double) -> CGFloat {
        anchorX + CGFloat(s - scrollSeconds) * pixelsPerSecond
    }

    /// 坐标系 x → 时间（秒）。
    func seconds(forX x: CGFloat) -> Double {
        Double((x - anchorX) / pixelsPerSecond) + scrollSeconds
    }

    /// 可见时间窗口（秒）（anchorX 两侧各按偏移折算）。
    var visibleRange: Range<Double> {
        let left = scrollSeconds - Double(anchorX / pixelsPerSecond)
        let right = scrollSeconds + Double((viewport.width - anchorX) / pixelsPerSecond)
        return left..<max(left, right)
    }

    /// 右边缘裁剪手柄宽度（pt）。
    static let trimHandleWidth: CGFloat = 8

    /// 轨道行号（显示顺序，0 起）；未找到返回 nil。
    func trackRow(forTrackId id: UInt64) -> Int? {
        tracks.firstIndex(where: { $0.trackId == id })
    }

    /// 片段矩形（y 已含标尺偏移；行号以 trackId 在 tracks 中的位置定位）。
    /// 完全在视口外的片段返回 nil（布局层的可见裁剪，调用方跳过绘制）。
    ///
    /// `override`：拖拽/裁剪期间的本地预览值（未提交内核）。
    /// `rowOverride`：跨轨拖拽的预览行（UIA-040）—— **只对 override 命中的那个
    /// 片段生效**（片段还在源轨，预览画在目标行上）；nil 或非拖拽片段 = 按真实轨道。
    func rect(for clip: ClipInfo, override: ClipPreviewOverride? = nil,
              rowOverride: Int? = nil) -> CGRect? {
        var trackRow = tracks.firstIndex(where: { $0.trackId == clip.trackId })
        if let rowOverride, let o = override, o.clipId == clip.clipId {
            trackRow = rowOverride
        }
        guard let row = trackRow else {
            return nil
        }
        var startSeconds = Double(clip.start.value) / Double(clip.start.timescale)
        var durationSeconds = Double(clip.duration.value) / Double(clip.duration.timescale)
        if let o = override, o.clipId == clip.clipId {
            startSeconds = o.startSeconds
            durationSeconds = o.durationSeconds
        }
        let x = x(forSeconds: startSeconds)
        let width = CGFloat(durationSeconds) * pixelsPerSecond
        // 完全在视口外（含 1pt 边界容差）→ 跳过
        if x + width < 0 || x > viewport.width + 1 { return nil }
        let y = rulerHeight + CGFloat(row) * (trackHeight + Self.trackSpacing)
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

    /// 命中测试：点落在哪个片段、哪个区域（UIA-005）。
    ///
    /// 纯函数、可单测 —— 手势的判定逻辑不藏在 View 里。
    /// 未命中任何片段返回 nil（调用方据此降级为「平移时间线」）。
    ///
    /// 左 / 右边缘各留 `trimHandleWidth` 为裁剪区（EDIT-008 起左缘可裁）；
    /// 片段过窄（< 2×手柄宽）时整体归「移动」，避免两个手柄互相吃掉主体。
    func hitTest(_ point: CGPoint, override: ClipPreviewOverride? = nil) -> TimelineHit? {
        for clip in clips {
            guard let r = rect(for: clip, override: override) else { continue }
            guard point.x >= r.minX, point.x <= r.maxX,
                  point.y >= r.minY, point.y <= r.maxY else { continue }
            let region: ClipHitRegion
            if r.width >= Self.trimHandleWidth * 2 {
                if point.x >= r.maxX - Self.trimHandleWidth {
                    region = .trimEnd
                } else if point.x <= r.minX + Self.trimHandleWidth {
                    region = .trimStart
                } else {
                    region = .move
                }
            } else {
                region = .move
            }
            return TimelineHit(clip: clip, region: region)
        }
        return nil
    }

    /// 时刻 t 是否严格落在片段内部（开区间）：分割可用性判定（对标 App 语义：
    /// 在播放头处剪开；切在边界上无意义，内核同样拒绝 —— UI 先置灰）。
    /// 纯函数、可单测（ViewModel 与两侧工具栏共用）。
    static func isStrictlyInside(_ clip: ClipInfo, atSeconds t: Double) -> Bool {
        let start = Double(clip.start.value) / Double(clip.start.timescale)
        let end = start + Double(clip.duration.value) / Double(clip.duration.timescale)
        return t > start && t < end
    }

    /// 标尺刻度：返回 (时间秒, 是否主刻度)。步长随缩放自适应，保证相邻刻度 ≥ 60pt。
    /// 帧级候选（UIA-038：精度下限 = 一帧）排在最前——只在放大到帧级间距时胜出，
    /// 常规缩放下仍落到秒级候选（既有行为不变）。
    func rulerTicks() -> [(second: Double, major: Bool)] {
        let frame = TimelineZoomMath.defaultFrameDuration
        let candidates: [Double] = [frame, frame * 2, frame * 5,
                                    0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 300, 600]
        var step = 1.0
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

    /// U1（UIA-041）：带样式信息的刻度序列。
    ///
    /// 取代各展示层自己解释 `(second, major)` 元组 —— 主次判定、下一步长在哪
    /// 这些知识放在几何层，SwiftUI 与 UIKit 画出**同一个形状**。
    /// `dotOffsetSeconds` 是通往下一个主刻度的<｜hy_place▁holder▁no▁813｜>（画圆点分隔符用），最后一个主刻度为 0
    /// （其后不再有点）。
    struct StyledTick: Equatable {
        let second: Double
        let isMajor: Bool
        /// 到下一个主刻度的距离（秒）；0 = 其后无点。
        let dotOffsetSeconds: Double

        var hasDot: Bool { dotOffsetSeconds > 0 }
    }

    func styledRulerTicks() -> [StyledTick] {
        let raw = rulerTicks()
        var result: [StyledTick] = []
        // 先算出「主刻度的步长」：major 的出现周期 = step×5（见 rulerTicks）。
        let step = rulerStepSeconds
        let majorStep = step * 5
        for (index, tick) in raw.enumerated() {
            guard tick.major else {
                result.append(StyledTick(second: tick.second, isMajor: false,
                                         dotOffsetSeconds: 0))
                continue
            }
            let next = raw[(index + 1)...].first(where: { $0.major })?.second
            let gap = next.map { $0 - tick.second } ?? majorStep
            // 只在间距正常（非负且约等于 majorStep）时给点；异常间距视为不规则边界，不画。
            let valid = gap > 0 && abs(gap - majorStep) < step / 2
            result.append(StyledTick(second: tick.second, isMajor: true,
                                     dotOffsetSeconds: valid ? majorStep : 0))
        }
        return result
    }

    /// 当前刻度步长（秒）—— `rulerTicks` 里选出 `step` 的那套逻辑，抽出来给 U1 的圆点用。
    var rulerStepSeconds: Double {
        let frame = TimelineZoomMath.defaultFrameDuration
        let candidates: [Double] = [frame, frame * 2, frame * 5,
                                    0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 300, 600]
        for c in candidates {
            if CGFloat(c) * pixelsPerSecond >= 60 { return c }
        }
        return candidates.last ?? 1
    }

    /// 播放头的 x 坐标。
    func playheadX(playheadSeconds: Double) -> CGFloat {
        x(forSeconds: playheadSeconds)
    }
}
