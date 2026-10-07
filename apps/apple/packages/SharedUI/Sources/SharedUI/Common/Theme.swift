// SharedUI 基座 — 编辑器暗色主题常量（UI 基座唯一配色真源，ADR-0031）
//
// 2026-10-07 全域 Pod 化后 Theme 升 public：各功能 Pod（Editor/Import/Camera…）
// 均从基座取色；本文件之外不得再定义域级配色表（MediaPicker 的 PickerTheme
// 与本表 accent 的合并目标见 UIA-033 注记）。

import SwiftUI

public enum Theme {
    // MARK: - 背景

    public static let editorBackground = Color.black
    public static let previewBackground = Color(red: 0.06, green: 0.06, blue: 0.08)
    public static let timelineBackground = Color(red: 0.08, green: 0.08, blue: 0.10)
    public static let panelBackground = Color(red: 0.10, green: 0.10, blue: 0.12)

    // MARK: - 文字

    public static let primaryText = Color.white
    public static let secondaryText = Color.gray
    public static let tertiaryText = Color(red: 0.5, green: 0.5, blue: 0.55)

    // MARK: - 分隔线

    public static let divider = Color(red: 0.2, green: 0.2, blue: 0.24)

    // MARK: - 播放头

    public static let playhead = Color.red

    // MARK: - 轨道

    public static let trackFill = Color(red: 0.18, green: 0.18, blue: 0.22)
    public static let trackStroke = Color(red: 0.28, green: 0.28, blue: 0.32)

    // MARK: - 时间线自绘（UIA-004）

    public static let timelineRuler = Color(red: 0.12, green: 0.12, blue: 0.15)
    public static let timelineTick = Color(red: 0.35, green: 0.35, blue: 0.40)
    public static let timelineTrackA = Color(red: 0.14, green: 0.14, blue: 0.17)
    public static let timelineTrackB = Color(red: 0.11, green: 0.11, blue: 0.14)
    public static let timelineClip = Color(red: 0.26, green: 0.42, blue: 0.62)
    public static let timelineClipBorder = Color(red: 0.38, green: 0.56, blue: 0.78)
    public static let timelineClipLabel = Color.white
    /// 拖拽中的片段（UIA-005）：本地预览态，尚未提交内核 —— 用更亮的颜色提示。
    public static let timelineClipDragging = Color(red: 0.36, green: 0.56, blue: 0.82)

    // MARK: - 尺寸

    public enum Size {
        public static let timelineHeight: CGFloat = 220
        public static let panelWidth: CGFloat = 280
        public static let panelMinWidth: CGFloat = 200
        /// iOS 竖屏时间线固定条高（UIA-032 剪映式；调高/缩放留后续任务）。
        public static let timelineHeightCompact: CGFloat = 140
        public static let transportBarHeight: CGFloat = 44
        public static let bottomToolbarHeight: CGFloat = 58
    }

    // MARK: - 编辑页语义常量（UIA-033 增量；全量令牌清扫待批，RESEARCH-004 §6.0）

    /// 播放控制条底色（预览正下方）：比预览背景略抬升一级。
    public static let transportBackground = Color(red: 0.09, green: 0.09, blue: 0.11)

    /// 底部工具栏底色：比时间线背景再抬升一级，收拢拇指区。
    public static let toolbarBackground = Color(red: 0.11, green: 0.11, blue: 0.13)

    /// 品牌强调色：与时间线片段蓝同族（UIA-013 PickerTheme.accent 合并目标）。
    public static let accent = Color(red: 0.30, green: 0.55, blue: 0.95)

    /// 强调色上的文字/图标。
    public static let accentText = Color.white

    /// 间距阶梯（RESEARCH-004 §6.0）。
    public enum Space {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    /// 圆角阶梯。
    public enum Radius {
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        /// 胶囊（工具位图标底、按钮）。
        public static let capsule: CGFloat = 999
    }
}
