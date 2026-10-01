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

    // MARK: - 尺寸

    enum Size {
        static let timelineHeight: CGFloat = 220
        static let panelWidth: CGFloat = 280
        static let panelMinWidth: CGFloat = 200
    }
}
