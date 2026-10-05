// SharedUI — 播放器外挂字幕渲染层（UIA-018/025；ADR-0023）
//
// 只消费 SubtitleParser 的值类型（解析层未来下沉 C++ 时本文件零改动）。
// 定位规则：
//   * 默认：底部居中，避开控制层（底距 72pt）；
//   * ASS \pos：归一化坐标绝对定位（锚点简化为居中——完整 \an 锚点语义 v1 不做）；
//   * ASS \an/Style Alignment：九宫格对齐（无 \pos 时生效）。
// 字号：ASS \fs / Style Fontsize 按 容器高度 / PlayResY(默认 288) 归一；
//       SRT/VTT 用 Dynamic Type 语义字号。整块加深色投影保证可读。

import SwiftUI

struct SubtitleOverlayView: View {
    let cue: SubtitleCue?

    private static let defaultBottomPadding: CGFloat = 72

    var body: some View {
        GeometryReader { geo in
            Group {
                if let cue = cue {
                    subtitleText(cue, containerHeight: geo.size.height)
                        .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: frameAlignment(for: cue))
            .padding(.bottom, bottomPadding(for: cue))
            .positionIfNeeded(cue, in: geo.size)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cue.map { "字幕：\($0.text)" } ?? "")
    }

    // MARK: 文本组装（逐 span 样式）

    @ViewBuilder
    private func subtitleText(_ cue: SubtitleCue, containerHeight: CGFloat) -> some View {
        if cue.position != nil {
            // \pos 绝对定位：Text 直接放点（锚点居中简化，见文件头）
            styledText(cue, containerHeight: containerHeight)
        } else {
            styledText(cue, containerHeight: containerHeight)
                .multilineTextAlignment(textAlignment(for: cue))
        }
    }

    private func styledText(_ cue: SubtitleCue, containerHeight: CGFloat) -> Text {
        var result = Text("")
        for span in cue.spans {
            var segment = Text(span.text)
            if let fontSize = span.fontSize {
                let resolved = containerHeight * fontSize / SubtitleParser.defaultPlayResHeight
                if let fontName = span.fontName {
                    segment = segment.font(.custom(fontName, size: resolved))
                } else {
                    segment = segment.font(.system(size: resolved,
                                                   weight: span.bold ? .bold : .regular))
                }
            } else if let fontName = span.fontName {
                segment = segment.font(.custom(fontName, size: 16))
            } else if span.bold {
                segment = segment.bold()
            }
            if span.italic {
                segment = segment.italic()
            }
            if span.underline {
                segment = segment.underline()
            }
            if let color = span.color {
                segment = segment.foregroundColor(Color(red: color.red,
                                                        green: color.green,
                                                        blue: color.blue))
            }
            result = result + segment
        }
        return result
    }

    // MARK: 定位辅助

    private func frameAlignment(for cue: SubtitleCue?) -> Alignment {
        guard let cue = cue, cue.position == nil else { return .center }
        if let an = cue.alignment, let mapped = SubtitleParser.alignment(forAn: an) {
            return mapped
        }
        return .bottom
    }

    private func bottomPadding(for cue: SubtitleCue?) -> CGFloat {
        (cue?.position == nil && (cue?.alignment == nil || (cue?.alignment ?? 0) <= 3))
            ? Self.defaultBottomPadding : 0
    }

    private func textAlignment(for cue: SubtitleCue) -> TextAlignment {
        guard let an = cue.alignment else { return .center }
        switch (an - 1) % 3 {
        case 0: return .leading
        case 1: return .center
        default: return .trailing
        }
    }
}

// MARK: - \pos 绝对定位

private extension View {
    /// \pos 存在时把字幕块放到归一化坐标点（锚点居中简化，v1）。
    @ViewBuilder
    func positionIfNeeded(_ cue: SubtitleCue?, in size: CGSize) -> some View {
        if let cue = cue, let position = cue.position {
            self.position(x: position.width * size.width,
                          y: position.height * size.height)
        } else {
            self
        }
    }
}
