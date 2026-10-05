// SharedUI — 编辑器暗色主题常量

import SwiftUI

enum Theme {
    // MARK: - 背景

    static let editorBackground = Color.black
    static let previewBackground = Color(red: 0.06, green: 0.06, blue: 0.08)
    static let timelineBackground = Color(red: 0.08, green: 0.08, blue: 0.10)
    static let panelBackground = Color(red: 0.10, green: 0.10, blue: 0.12)

    // MARK: - 文字

    static let primaryText = Color.white
    static let secondaryText = Color.gray
    static let tertiaryText = Color(red: 0.5, green: 0.5, blue: 0.55)

    // MARK: - 分隔线

    static let divider = Color(red: 0.2, green: 0.2, blue: 0.24)

    // MARK: - 播放头

    static let playhead = Color.red

    // MARK: - 轨道

    static let trackFill = Color(red: 0.18, green: 0.18, blue: 0.22)
    static let trackStroke = Color(red: 0.28, green: 0.28, blue: 0.32)

    // MARK: - 时间线自绘（UIA-004）

    static let timelineRuler = Color(red: 0.12, green: 0.12, blue: 0.15)
    static let timelineTick = Color(red: 0.35, green: 0.35, blue: 0.40)
    static let timelineTrackA = Color(red: 0.14, green: 0.14, blue: 0.17)
    static let timelineTrackB = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let timelineClip = Color(red: 0.26, green: 0.42, blue: 0.62)
    static let timelineClipBorder = Color(red: 0.38, green: 0.56, blue: 0.78)
    static let timelineClipLabel = Color.white
    /// 拖拽中的片段（UIA-005）：本地预览态，尚未提交内核 —— 用更亮的颜色提示。
    static let timelineClipDragging = Color(red: 0.36, green: 0.56, blue: 0.82)

    // MARK: - 尺寸

    enum Size {
        static let timelineHeight: CGFloat = 220
        static let panelWidth: CGFloat = 280
        static let panelMinWidth: CGFloat = 200
        /// iOS 竖屏时间线固定条高（UIA-015 剪映式；调高/缩放留后续任务）。
        static let timelineHeightCompact: CGFloat = 140
        static let transportBarHeight: CGFloat = 44
        static let bottomToolbarHeight: CGFloat = 58
    }

    // MARK: - 编辑页语义常量（UIA-016 增量；全量令牌清扫待批，RESEARCH-004 §6.0）

    /// 播放控制条底色（预览正下方）：比预览背景略抬升一级。
    static let transportBackground = Color(red: 0.09, green: 0.09, blue: 0.11)

    /// 底部工具栏底色：比时间线背景再抬升一级，收拢拇指区。
    static let toolbarBackground = Color(red: 0.11, green: 0.11, blue: 0.13)

    /// 品牌强调色：与时间线片段蓝同族（UIA-013 PickerTheme.accent 合并目标）。
    static let accent = Color(red: 0.30, green: 0.55, blue: 0.95)

    /// 强调色上的文字/图标。
    static let accentText = Color.white

    /// 间距阶梯（RESEARCH-004 §6.0）。
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// 圆角阶梯。
    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        /// 胶囊（工具位图标底、按钮）。
        static let capsule: CGFloat = 999
    }
}
