// SharedUI — 播放器外挂字幕解析器（UIA-018 SRT/WebVTT + UIA-025 ASS/SSA 子集）
//
// 架构归属（ADR-0023）：Swift 纯函数是**过渡性 UI 域豁免**（先例 ADR-0014/0022），
// 三端一致需求出现时下沉 core 并开 C ABI；渲染层只消费本文件的值类型，下沉时不动。
//
// 设计：
//   * 输出 = 有序 [SubtitleCue]（按 start 排序，二分查找当前条）；
//   * 文本 = [SubtitleSpan]（minimal 样式：粗/斜/下划/颜色/字号/字体），
//     SRT/VTT 恒为单 span 纯文本（剥离 HTML 标签）；
//   * ASS 支持子集（UIA-025 明确声明，非完整 libass）：
//       {\b}{\i}{\u}{\fn}{\fs}{\c / \1c}{\an1-9}{\pos(x,y)}；\N 换行；
//       未知 tag 剥离不致命。卡拉OK/矢量/blur/3D/clip 明确不做。
//   * 内存上界 1MB（防超大文件）；编码 UTF-8 优先、UTF-16 兜底。
//
// 时间轴口径：秒（TimeInterval），与 PlayerViewModel.displaySeconds 对齐。

import CoreGraphics
import Foundation
import SwiftUI  // Alignment / HorizontalAlignment / VerticalAlignment（numPad → SwiftUI 对齐映射）

// MARK: - 值类型

/// ASS 颜色（RGB，0...1）。解析自 &HBBGGRR&（BGR 字节序）。
struct SubtitleColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
}

/// 带最小样式的文本段。SRT/VTT 场景为单段默认样式。
struct SubtitleSpan: Equatable {
    /// var 而非 let：ASS 解析是「先攒样式、最后回填文本」（`flushSpan` 复制样式再
    /// 写 text），逐字符 visit 过程中不存在「先有文本后定样式」的路径。
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var color: SubtitleColor?
    /// ASS \fs / Style Fontsize（PlayRes 像素；渲染按容器高度 / 默认 288 归一）。
    var fontSize: Double?
    /// ASS \fn 字体名（系统无该字体时 SwiftUI 自动回退）。
    var fontName: String?
}

/// 一条字幕：时间区间 + 文本段 + 可选定位。
struct SubtitleCue: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let spans: [SubtitleSpan]
    /// ASS \pos(x,y) 归一化坐标（0...1，相对播放区；nil = 默认底部居中）。
    let position: CGPoint?
    /// ASS 对齐（numpad 1-9，Style 层或 \an；nil = 底部居中）。
    let alignment: Int?

    var text: String { spans.map { $0.text }.joined() }
}

// MARK: - 错误

enum SubtitleParserError: Error, Equatable {
    case empty
    case tooLarge
    case unsupportedFormat
}

// MARK: - 解析器

enum SubtitleParser {

    /// 内存上界：防超大文件（1MB 文本 ≈ 数千条字幕，足够）。
    static let maxDataSize = 1_000_000
    /// ASS PlayResY 默认值（Script Info 未声明时的渲染归一基准）。
    static let defaultPlayResHeight: Double = 288

    /// 统一入口：按内容嗅探分发（不信任文件扩展名）。
    static func parse(data: Data) throws -> [SubtitleCue] {
        guard data.count <= maxDataSize else { throw SubtitleParserError.tooLarge }
        // ⚠️ `String(data: encoding: .utf16)` 对「只有 BOM / 长度不足」会**成功返回空串**
        // —— 照单全收的话，一份坏文件会被判成 `.empty` 而非 `.unsupportedFormat`，
        // 「文件坏了」和「文件是空的」就分不开了（实测 Data([0xFF,0xFE,0x00])
        // 的 utf16 结果就是 ""）。故 utf16 解出空串一律按不可解码处理。
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let utf16 = String(data: data, encoding: .utf16), !utf16.isEmpty {
            text = utf16
        } else {
            throw SubtitleParserError.unsupportedFormat
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw SubtitleParserError.empty }
        if trimmed.hasPrefix("[Script Info]") || trimmed.hasPrefix("[V4+")
            || trimmed.hasPrefix("[V4 Styles]") {
            return parseASS(text)
        }
        if trimmed.hasPrefix("WEBVTT") {
            return parseWebVTT(text)
        }
        return parseSRT(text)
    }

    // MARK: SRT / WebVTT

    /// SRT：空行分块；块内首行序号可缺省；时间戳 "hh:mm:ss,mmm --> hh:mm:ss,mmm"。
    /// WebVTT 复用同一分块逻辑（时间戳用 '.'；WEBVTT 头/NOTE/STYLE 块无 "-->" 自动跳过）。
    static func parseSRT(_ raw: String) -> [SubtitleCue] {
        parseBlockFormat(raw)
    }

    static func parseWebVTT(_ raw: String) -> [SubtitleCue] {
        parseBlockFormat(raw)
    }

    // MARK: ASS/SSA

    static func parseASS(_ raw: String) -> [SubtitleCue] {
        let text = normalizedLines(raw)
        var section = ""
        var styleFieldOrder: [String] = []
        var styles: [String: ASSStyle] = [:]
        var playResX: Double = 384
        var playResY: Double = defaultPlayResHeight
        var cues: [SubtitleCue] = []

        for line in text {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") { continue }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = trimmed
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch section {
            case "[Script Info]":
                if key == "PlayResX" { playResX = Double(value) ?? 384 }
                if key == "PlayResY" { playResY = Double(value) ?? defaultPlayResHeight }
            case "[V4+ Styles]", "[V4 Styles]":
                if key == "Format" {
                    styleFieldOrder = value.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                }
                if key == "Style", let style = ASSStyle(styleLine: value, fieldOrder: styleFieldOrder) {
                    styles[style.name] = style
                }
            case "[Events]":
                if key == "Dialogue" {
                    // maxSplits = 9 → 恰好 10 段（最后一个字段 Text 允许含逗号）。
                    // 旧值 8 只能切出 9 段，`fields.count >= 10` 恒假 → 所有 Dialogue
                    // 行被静默丢弃（从未跑过测试，故一直没暴露）。
                    let fields = value.split(separator: ",", maxSplits: 9,
                                             omittingEmptySubsequences: false)
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                    // 固定序：Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
                    guard fields.count >= 10,
                          let start = parseTimestamp(fields[1]),
                          let end = parseTimestamp(fields[2]) else { continue }
                    let style = styles[fields[3]]
                    let parsed = parseASSText(fields[9],
                                              style: style,
                                              playRes: CGSize(width: playResX, height: playResY))
                    guard !parsed.spans.isEmpty else { continue }
                    cues.append(SubtitleCue(start: start, end: end,
                                            spans: parsed.spans,
                                            position: parsed.position,
                                            alignment: parsed.alignment))
                }
            default:
                break
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: 查询

    /// 二分查找当前时刻的条目（重叠区间取先出现者；间隙返回 nil）。
    static func cue(at seconds: TimeInterval, in cues: [SubtitleCue]) -> SubtitleCue? {
        guard !cues.isEmpty else { return nil }
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if seconds < cue.start {
                high = mid - 1
            } else if seconds > cue.end {
                low = mid + 1
            } else {
                return cue
            }
        }
        return nil
    }

    /// numpad 对齐（1-9）→ SwiftUI Alignment。
    static func alignment(forAn an: Int) -> Alignment? {
        guard an >= 1, an <= 9 else { return nil }
        let horizontal: HorizontalAlignment
        switch (an - 1) % 3 {
        case 0: horizontal = .leading
        case 1: horizontal = .center
        default: horizontal = .trailing
        }
        let vertical: VerticalAlignment
        switch an {
        case 1...3: vertical = .bottom
        case 4...6: vertical = .center
        default: vertical = .top
        }
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    // MARK: 内部 - 分块格式（SRT/VTT 共用）

    private static func parseBlockFormat(_ raw: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var block: [String] = []

        func flush() {
            defer { block = [] }
            guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }) else { return }
            let halves = block[timingIndex].components(separatedBy: "-->")
            guard halves.count == 2,
                  let start = parseTimestamp(halves[0]) else { return }
            // 终点后可能跟 VTT cue settings（取首个空白前 token）
            let endToken = halves[1].trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1).first
            guard let endToken = endToken, let end = parseTimestamp(String(endToken)) else { return }
            let body = block[(timingIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            cues.append(SubtitleCue(start: start, end: end,
                                    spans: [SubtitleSpan(text: strippedTags(body))],
                                    position: nil, alignment: nil))
        }

        for line in normalizedLines(raw) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                block.append(line)
            }
        }
        flush()
        return cues.sorted { $0.start < $1.start }
    }

    /// 剥离 SRT/VTT 的 HTML 风格标签（<i>、<font ...> 等）。
    private static func strippedTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        var inside = false
        for character in text {
            if character == "<" {
                inside = true
            } else if character == ">" {
                inside = false
            } else if !inside {
                result.append(character)
            }
        }
        return result
    }

    /// 时间戳：hh:mm:ss,mmm / hh:mm:ss.mmm / mm:ss.mmm（VTT 允许省略小时）。
    static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let seconds = Double(parts[parts.count - 1]) else { return nil }
        guard let minutes = Double(parts[parts.count - 2]) else { return nil }
        var total = seconds + minutes * 60
        if parts.count == 3 {
            guard let hours = Double(parts[0]) else { return nil }
            total += hours * 3600
        }
        return total
    }

    private static func normalizedLines(_ raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    // MARK: 内部 - ASS

    /// Style 行的最小样式（V4+/V4 字段序由 Format 行决定）。
    private struct ASSStyle {
        var name: String
        var fontSize: Double?
        var color: SubtitleColor?
        var bold = false
        var italic = false
        var underline = false
        var alignment: Int?

        init?(styleLine: String, fieldOrder: [String]) {
            let values = styleLine.split(separator: ",", maxSplits: fieldOrder.count - 1,
                                         omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard values.count == fieldOrder.count, fieldOrder.count > 5 else { return nil }
            var table: [String: String] = [:]
            for (index, field) in fieldOrder.enumerated() {
                table[field] = values[index]
            }
            guard let name = table["Name"], !name.isEmpty else { return nil }
            self.name = name
            fontSize = table["Fontsize"].flatMap { Double($0) }
            if let primary = table["PrimaryColour"] {
                color = Self.parseColor(primary)
            }
            bold = table["Bold"] == "1" || table["Bold"] == "-1"
            italic = table["Italic"] == "1" || table["Italic"] == "-1"
            underline = table["Underline"] == "1" || table["Underline"] == "-1"
            alignment = table["Alignment"].flatMap { Int($0) }
        }

        /// &HAABBGGRR& / &HBBGGRR&（BGR 字节序）→ RGB。
        static func parseColor(_ raw: String) -> SubtitleColor? {
            var hex = raw.trimmingCharacters(in: .whitespaces)
            if hex.hasPrefix("&H") || hex.hasPrefix("&h") {
                hex = String(hex.dropFirst(2))
            }
            if hex.hasSuffix("&") {
                hex = String(hex.dropLast())
            }
            // AABBGGRR → 取低 6 位 BBGGRR
            let rr = hex.suffix(2)
            let gg = hex.dropLast(2).suffix(2)
            let bb = hex.dropLast(4).suffix(2)
            let r = Double(UInt8(rr, radix: 16) ?? 0) / 255.0
            let g = Double(UInt8(gg, radix: 16) ?? 0) / 255.0
            let b = Double(UInt8(bb, radix: 16) ?? 0) / 255.0
            return SubtitleColor(red: r, green: g, blue: b)
        }
    }

    /// Dialogue 文本 → 样式 spans + \pos/\an。
    /// 样式切换即切段：每段 SubtitleSpan 持有落段时的样式快照。
    private static func parseASSText(_ raw: String,
                                     style: ASSStyle?,
                                     playRes: CGSize) -> (spans: [SubtitleSpan], position: CGPoint?, alignment: Int?) {
        var base = SubtitleSpan(text: "")
        if let style = style {
            base.bold = style.bold
            base.italic = style.italic
            base.underline = style.underline
            base.color = style.color
            base.fontSize = style.fontSize
        }

        var spans: [SubtitleSpan] = []
        var currentStyle = base
        var currentText = ""
        var position: CGPoint?
        var overrideAlignment: Int?

        func flushSpan() {
            guard !currentText.isEmpty else { return }
            var span = currentStyle
            span.text = currentText
            spans.append(span)
            currentText = ""
        }

        func appendPlain(_ plain: String) {
            guard !plain.isEmpty else { return }
            let body = plain.replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
            if body.isEmpty { return }
            currentText += body
        }

        var index = raw.startIndex
        while let braceStart = raw[index...].firstIndex(of: "{") {
            appendPlain(String(raw[index..<braceStart]))
            guard let braceEnd = raw[braceStart...].firstIndex(of: "}") else {
                // 未闭合 brace：从 brace 起的剩余文本按当前样式处理（容错）
                index = braceStart
                break
            }
            // brace 可能改变样式：先落盘已累积文本，保证每段样式单一
            flushSpan()
            let tagBody = String(raw[raw.index(after: braceStart)..<braceEnd])
            for token in tagBody.split(separator: "\\") {
                let tag = String(token).trimmingCharacters(in: .whitespaces)
                if tag.isEmpty { continue }
                if tag.hasPrefix("pos(") && tag.hasSuffix(")") {
                    let inner = tag.dropFirst(4).dropLast()
                    let xy = inner.split(separator: ",")
                    if xy.count == 2,
                       let x = Double(xy[0]), let y = Double(xy[1]),
                       playRes.width > 0, playRes.height > 0 {
                        position = CGPoint(x: x / playRes.width, y: y / playRes.height)
                    }
                    continue
                }
                if tag.hasPrefix("an"), let an = Int(tag.dropFirst(2)) {
                    overrideAlignment = an
                    continue
                }
                if tag.hasPrefix("fn") {
                    currentStyle.fontName = String(tag.dropFirst(2))
                    continue
                }
                if tag.hasPrefix("fs"), let fs = Double(tag.dropFirst(2)) {
                    currentStyle.fontSize = fs
                    continue
                }
                if tag.hasPrefix("1c") || tag.hasPrefix("c") {
                    let hexPart = tag.dropFirst(tag.hasPrefix("1c") ? 2 : 1)
                    if let color = ASSStyle.parseColor(String(hexPart)) {
                        currentStyle.color = color
                    }
                    continue
                }
                switch tag {
                case "b1": currentStyle.bold = true
                case "b0": currentStyle.bold = false
                case "i1": currentStyle.italic = true
                case "i0": currentStyle.italic = false
                case "u1": currentStyle.underline = true
                case "u0": currentStyle.underline = false
                default: break // 未知 tag 容错：仅剥离
                }
            }
            index = raw.index(after: braceEnd)
        }
        appendPlain(String(raw[index...]))
        flushSpan()

        // \N 产生的多行文本在 span 内以 \n 保存（Text 原生渲染换行）
        let alignment = overrideAlignment ?? style?.alignment
        return (spans, position, alignment)
    }
}
