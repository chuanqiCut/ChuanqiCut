// SharedUI — 外挂字幕解析器验收（UIA-018 SRT/VTT + UIA-025 ASS 子集；ADR-0023）
//
// 纯函数全量覆盖：格式嗅探、时间戳方言（逗号/点/省略小时）、坏块容错、
// HTML 标签剥离、ASS 样式子集（粗斜下/颜色 BGR/字号/字体/对齐/\pos）、
// 未知 tag 剥离、1MB 上界、二分查找边界。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import CoreGraphics
import XCTest
@testable import SharedUI

final class PlayerSubtitleTests: XCTestCase {

    // MARK: SRT

    func testSRTParsesBlocksMultilineAndCommaMillis() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        第一条字幕
        第二行内容

        2
        00:00:05,200 --> 00:00:07,000
        第二条，带逗号。

        3
        00:00:08,000 --> 00:00:09,000
        <i>斜体标签</i> 应被剥离
        """
        let cues = SubtitleParser.parseSRT(srt)
        XCTAssertEqual(cues.count, 3, "三个块全部解析（坏块不存在时）")
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "第一条字幕\n第二行内容", "多行文本以 \\n 保留")
        XCTAssertEqual(cues[1].start, 5.2, accuracy: 0.001)
        XCTAssertFalse(cues[2].text.contains("<i>"), "HTML 标签剥离")
        XCTAssertTrue(cues[2].text.contains("斜体标签"), "标签内文本保留")
    }

    func testSRTToleratesGarbageBlocks() {
        let srt = """
        这不是字幕的行

        1
        00:00:01,000 --> 00:00:02,000
        正常条目

        另一个坏块：只有文字没有时间轴
        """
        let cues = SubtitleParser.parseSRT(srt)
        XCTAssertEqual(cues.count, 1, "坏块跳过不致命")
        XCTAssertEqual(cues[0].text, "正常条目")
    }

    // MARK: WebVTT

    func testWebVTTParsesHeaderNotesAndDotMillis() {
        let vtt = """
        WEBVTT

        NOTE 这是注释块，应被跳过

        00:01.000 --> 00:03.500
        省略小时的条目

        cue-2
        00:01:05.000 --> 00:01:07.000 position:50%
        有 cue id 与设置行
        """
        let cues = SubtitleParser.parseWebVTT(vtt)
        XCTAssertEqual(cues.count, 2, "WEBVTT 头与 NOTE 块自动跳过")
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001, "mm:ss.mmm 省略小时")
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, 65.0, accuracy: 0.001, "hh:mm:ss.mmm")
        XCTAssertEqual(cues[1].text, "有 cue id 与设置行", "时间轴后的 cue settings 不混入文本")
    }

    // MARK: 时间戳方言

    func testTimestampDialects() {
        XCTAssertEqual(SubtitleParser.parseTimestamp("01:02:03,456") ?? -1, 3723.456, accuracy: 0.001)
        XCTAssertEqual(SubtitleParser.parseTimestamp("01:02:03.456") ?? -1, 3723.456, accuracy: 0.001)
        XCTAssertEqual(SubtitleParser.parseTimestamp("02:03.5") ?? -1, 123.5, accuracy: 0.001)
        XCTAssertNil(SubtitleParser.parseTimestamp("3.5"), "裸秒不合法")
        XCTAssertNil(SubtitleParser.parseTimestamp("abc"))
    }

    // MARK: ASS/SSA 子集（UIA-025）

    func testASSParsesStylesDialogueAndSubsetTags() {
        let ass = """
        [Script Info]
        PlayResX: 384
        PlayResY: 288

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, Bold, Italic, Underline, Alignment
        Style: Default,思源黑体,20,&H00FFFFFF,0,0,0,2

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\b1}加粗{\\b0}普通{\\i1}斜体
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\\pos(192,50)}{\\1c&HFF00FF&}品红定位字幕{\\blur9}未知tag后
        """
        let cues = SubtitleParser.parseASS(ass)
        XCTAssertEqual(cues.count, 2)

        // 条目一：Style 默认样式 + \b/\i 子集
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "加粗普通斜体")
        XCTAssertEqual(cues[0].spans.count, 3, "样式切换切分 span：加粗/普通/斜体")
        XCTAssertEqual(cues[0].spans[0].bold, true)
        XCTAssertEqual(cues[0].spans[0].fontSize, 20, "Style Fontsize 继承")
        XCTAssertFalse(cues[0].spans[1].bold, "\\b0 关闭加粗")
        XCTAssertEqual(cues[0].spans[2].italic, true, "\\i1 生效")
        XCTAssertNil(cues[0].position)
        XCTAssertEqual(cues[0].alignment, 2, "Style Alignment=2（底部居中）")

        // 条目二：\pos 归一化 + \1c BGR→RGB + 未知 tag 剥离
        XCTAssertEqual(cues[1].position?.x ?? -1, 0.5, accuracy: 0.001, "192/384")
        XCTAssertEqual(cues[1].position?.y ?? -1, 50.0 / 288.0, accuracy: 0.001)
        let magenta = cues[1].spans[0].color
        XCTAssertEqual(magenta?.red ?? -1, 1.0, accuracy: 0.001, "&HFF00FF& → R=FF")
        XCTAssertEqual(magenta?.green ?? -1, 0.0, accuracy: 0.001, "G=00")
        XCTAssertEqual(magenta?.blue ?? -1, 1.0, accuracy: 0.001, "B=FF")
        XCTAssertFalse(cues[1].text.contains("blur"), "未知 tag 剥离不混入文本")
        XCTAssertTrue(cues[1].text.contains("未知tag后"), "tag 后文本保留")
    }

    func testASSOverridesAlignmentAndNewline() {
        let ass = """
        [Script Info]

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,{\\an7}顶部左侧\\N第二行
        """
        let cues = SubtitleParser.parseASS(ass)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].alignment, 7, "\\an 覆盖对齐")
        XCTAssertEqual(cues[0].text, "顶部左侧\n第二行", "\\N 渲染为换行")
        XCTAssertEqual(SubtitleParser.alignment(forAn: 7)?.horizontal, .leading)
        XCTAssertEqual(SubtitleParser.alignment(forAn: 7)?.vertical, .top)
        XCTAssertEqual(SubtitleParser.alignment(forAn: 3)?.vertical, .bottom)
        XCTAssertNil(SubtitleParser.alignment(forAn: 12), "越界对齐返回 nil")
    }

    func testASSWithoutStyleLineStillParses() {
        let ass = """
        [Script Info]

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:01.00,Unknown,,0,0,0,,无样式定义也能出条目
        """
        let cues = SubtitleParser.parseASS(ass)
        XCTAssertEqual(cues.count, 1, "未知 Style 名不致命（无默认样式渲染）")
        XCTAssertNil(cues[0].spans[0].fontSize)
    }

    // MARK: 嗅探与上界

    func testSniffingDispatchesByContent() throws {
        let srtCues = try SubtitleParser.parse(data: Data("1\n00:00:01,000 --> 00:00:02,000\n你好".utf8))
        XCTAssertEqual(srtCues.count, 1)

        let vttCues = try SubtitleParser.parse(data: Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n你好".utf8))
        XCTAssertEqual(vttCues.count, 1)

        let assCues = try SubtitleParser.parse(data: Data("[Script Info]\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.00,0:00:01.00,D,,0,0,0,,文本".utf8))
        XCTAssertEqual(assCues.count, 1)
    }

    func testTooLargeAndEmptyAndUndecodable() {
        XCTAssertThrowsError(try SubtitleParser.parse(data: Data(count: SubtitleParser.maxDataSize + 1))) { error in
            XCTAssertEqual(error as? SubtitleParserError, .tooLarge, "1MB 上界拒绝")
        }
        XCTAssertThrowsError(try SubtitleParser.parse(data: Data("   \n  ".utf8))) { error in
            XCTAssertEqual(error as? SubtitleParserError, .empty)
        }
        XCTAssertThrowsError(try SubtitleParser.parse(data: Data([0xFF, 0xFE, 0x00]))) { error in
            XCTAssertEqual(error as? SubtitleParserError, .unsupportedFormat, "无法按 UTF-8/16 解码")
        }
    }

    // MARK: 二分查找

    func testCueLookupBoundaries() {
        let cues = [
            SubtitleCue(start: 1, end: 2, spans: [SubtitleSpan(text: "a")], position: nil, alignment: nil),
            SubtitleCue(start: 4, end: 6, spans: [SubtitleSpan(text: "b")], position: nil, alignment: nil),
            SubtitleCue(start: 8, end: 9, spans: [SubtitleSpan(text: "c")], position: nil, alignment: nil),
        ]
        XCTAssertNil(SubtitleParser.cue(at: 0.5, in: cues), "首条之前")
        XCTAssertEqual(SubtitleParser.cue(at: 1.0, in: cues)?.text, "a", "起点边界含")
        XCTAssertEqual(SubtitleParser.cue(at: 2.0, in: cues)?.text, "a", "终点边界含")
        XCTAssertNil(SubtitleParser.cue(at: 3.0, in: cues), "间隙无字幕")
        XCTAssertEqual(SubtitleParser.cue(at: 5.0, in: cues)?.text, "b")
        XCTAssertEqual(SubtitleParser.cue(at: 8.5, in: cues)?.text, "c")
        XCTAssertNil(SubtitleParser.cue(at: 9.1, in: cues), "末条之后")
        XCTAssertNil(SubtitleParser.cue(at: 1.0, in: []), "空表防御")
    }
}
