// TimelinePalette — 轨道区视觉常量（UIA-041 / U1，对照 RESEARCH-017 §1 规格表）
//
// ## 为什么单独有这个文件，而不是直接改 SharedUI 的 `Theme`
//
// `Theme.playhead` 现在是**红色**（`Color.red`），而对标 App 的时间线播放头是**白色**。
// 改它是**跨包改动**（Theme 在 SharedUI，被 iOS/Mac 多个消费者共用），超出 UIA-041
// 声明的写集 `apps/apple/packages/ChuanqiCutEditor/**`。按 ADR-0034「写集不相交是硬约束」，
// 本批**不越界**：在编辑器域内建立**分域色表**，先由轨道区消费。
//
// 这不是临时绕过 —— 视觉常量的**正确归宿**本来就是功能域：
// 一个吸管色 palette.y 的语义是「轨道区配色」，只有轨道区读它。
// 后续统一进 Theme 时应整表迁移（见文末 TODO），而不是把每个值重新塞回一堆散点。
//
// ## 纯度约束
//
// **不 import SwiftUI / UIKit / AppKit** —— 只依赖 CoreGraphics（CGColor）与数值。
// 这样同一个常量既能喂 UIKit 的 `CALayer`（要 CGColor）也能喂 SwiftUI 的 `Color`
// （由调用侧转换），不需要维护两份 RGB。
//
// TODO(UIA-042 前): 与 SharedUI/Theme 的归属做一次收敛，二选一并把散数次搬完 ——
//  长期并存两套色表会分裂（本文件刻意不允许被 Theme 之外的域引用，届时迁移成本可控）。

import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

enum TimelinePalette {

    // MARK: - 选中态（S3）

    /// 选中描边：白（对标 App 图2/4）。与既有 `Theme.primaryText` 同色，此处显式命名便于走查。
    static let selectionBorder = RGBA(1.0, 1.0, 1.0, 1.0)
    static let selectionBorderWidth: CGFloat = 2
    /// 未选中时的描边（沿用既有 Theme.timelineClipBorder，此处只为了让操纵国同一摄入单位）。
    static let clipBorder = RGBA(0.38, 0.56, 0.78, 1.0)

    /// **左右把手**：宽取 `TimelineLayout.trimHandleWidth`（8pt）——
    /// 这是「看到的把手」与「按得中的热区」必须是同一个数的唯一保证。
    /// 若此处写成另一个常量，用户会看到把手在 8pt 处却点不中（或反过来能拖动看不见的区域）。
    static let handleWidth = TimelineLayout.trimHandleWidth
    static let handleCornerRadius: CGFloat = 2
    static let handleInsetY: CGFloat = 6
    /// 片段过窄时（<2×把手宽）不画把手 —— 与 `hitTest` 的 「整体归 move」判定同源。
    static let handleMinimumClipWidth = TimelineLayout.trimHandleWidth * 2

    /// 中央时长数字（如 `3.3s`）：片段宽度小于此值不画（防止数字溢出片段）。
    static let durationLabelMinimumClipWidth: CGFloat = 44
    static let durationLabel = RGBA(1.0, 1.0, 1.0, 0.92)
    static let durationLabelBadge = RGBA(0.06, 0.06, 0.08, 0.55)
    static let durationLabelFontSize: CGFloat = 11

    // MARK: - 播放头（S4）

    /// 白色（对标 App）。`Theme.playhead` 仍是红色，由轨道区之外的地方继续消费；
    /// 轨道区自本批起只用这一个白。
    static let playhead = RGBA(1.0, 1.0, 1.0, 1.0)
    static let playheadWidth: CGFloat = 2
    /// 顶部小把手（对标 App 有，作为 scrub 的视觉抓手）。
    static let playheadKnobSize = CGSize(width: 10, height: 5)
    static let playheadKnobCornerRadius: CGFloat = 2

    // MARK: - 刻度尺（S1）

    static let tick = RGBA(0.55, 0.58, 0.62, 1.0)
    static let tickLabel = RGBA(0.72, 0.74, 0.78, 1.0)
    static let majorTickHeight: CGFloat = 10
    static let minorTickHeight: CGFloat = 5
    /// 主刻度之间的分隔符：一个小圆点（对标 App 在图3/4/5 上表现为 `00:00 · 00:02` 的圆点串）。
    /// 画在主刻度的文字右侧，随刻度密度自动稀取碘
    static let tickDotRadius: CGFloat = 1.2

    // MARK: - 右端添加钮（S7）

    static let addButtonGlyph = RGBA(1.0, 1.0, 1.0, 0.9)
    static let addButtonBackground = RGBA(1.0, 1.0, 1.0, 0.14)
    static let addButtonSize: CGFloat = 28
    static let addButtonCornerRadius: CGFloat = 6

    // MARK: - 预览区选中描边（S11）

    /// 对标 App 选中时预览四周是红框（图2/4）—— 与己方 `Theme.playhead` 红同色。
    static let previewSelectionBorder = RGBA(1.0, 0.25, 0.25, 1.0)
    static let previewSelectionBorderWidth: CGFloat = 2

    // MARK: - 轨道头（S2）

    static let trackHeaderBackground = RGBA(0.10, 0.10, 0.12, 0.72)
    static let trackHeaderGlyph = RGBA(1.0, 1.0, 1.0, 0.82)
    static let trackHeaderFontSize: CGFloat = 9
    static let trackHeaderWidth: CGFloat = 56

    /// 极简 RGBA 值类型（不依赖 SwiftUI.Color / UIKit.UIColor 存储，
    /// 但提供到两者的转换 —— 由调用侧各取所需，避免维护两份 RGB）。
    struct RGBA: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        var cgColor: CGColor {
            CGColor(red: red, green: green, blue: blue, alpha: alpha)
        }

        #if canImport(UIKit)
        /// UIKit 侧（`UIView.backgroundColor` 要的是 UIColor，不能塞 CGColor）。
        var uiColor: UIColor {
            UIColor(red: red, green: green, blue: blue, alpha: alpha)
        }
        #endif

        /// 派生同色不同透明度（轨道头 disabled 态用）。
        func withAlpha(_ value: CGFloat) -> RGBA {
            RGBA(red, green, blue, value)
        }
    }
}

// MARK: - SwiftUI / UIKit 适配

#if canImport(SwiftUI)
import SwiftUI

extension TimelinePalette.RGBA {
    /// SwiftUI 侧转 `Color`（不需要额外维护一份 RGB）。
    var color: Color {
        Color(.sRGB, red: Double(red), green: Double(green),
              blue: Double(blue), opacity: Double(alpha))
    }
}
#endif
