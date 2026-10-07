// SharedUI — 时间线布局验收（UIA-004）
//
// 覆盖：
//   * 时间↔像素换算往返、缩放/滚动语义
//   * 可见裁剪（视口外片段不产生矩形）
//   * 标尺刻度自适应（缩小时步长变大，避免刻度过密）
//   * 性能：500 片段布局 < 16ms（BACKLOG「数百片段不掉帧」的静态部分；
//     交互实帧率归 UIA-005 真机验证）
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import XCTest
import ChuanqiCut
@testable import ChuanqiCutEditor

final class TimelineLayoutTests: XCTestCase {

    private func makeClip(trackId: UInt64, clipId: UInt64,
                          startMs: Int64, durMs: Int64) -> ClipInfo {
        let ts = RationalTime.projectTimescale
        return ClipInfo(
            trackId: trackId, clipId: clipId, assetId: 1,
            start: RationalTime(value: startMs * 120, timescale: ts),
            duration: RationalTime(value: durMs * 120, timescale: ts),
            sourceIn: RationalTime(value: 0, timescale: ts),
            sourceDuration: RationalTime(value: durMs * 120, timescale: ts),
            inTransition: 0, outTransition: 0,
            transitionDuration: RationalTime(value: 0, timescale: ts))
    }

    private func makeLayout(trackCount: Int, clips: [ClipInfo],
                            pixelsPerSecond: CGFloat = 80,
                            scroll: Double = 0,
                            width: CGFloat = 1200) -> TimelineLayout {
        TimelineLayout(
            pixelsPerSecond: pixelsPerSecond,
            scrollSeconds: scroll,
            viewport: CGSize(width: width, height: 400),
            trackHeight: 44,
            rulerHeight: 24,
            tracks: (0..<trackCount).map {
                TrackInfo(trackId: UInt64($0 + 1), kind: 0, enabled: true, muted: false)
            },
            clips: clips)
    }

    // MARK: 换算

    func testTimePixelRoundTrip() {
        let layout = makeLayout(trackCount: 1, clips: [])
        // 0 秒在滚动 0 时位于 x=0
        XCTAssertEqual(layout.x(forSeconds: 0), 0)
        // 1 秒 = pixelsPerSecond
        XCTAssertEqual(layout.x(forSeconds: 1), 80)
        // 往返
        let seconds = 12.34
        XCTAssertEqual(layout.seconds(forX: layout.x(forSeconds: seconds)), seconds,
                       accuracy: 1e-9)
        // 滚动后原点平移
        let scrolled = makeLayout(trackCount: 1, clips: [], scroll: 5)
        XCTAssertEqual(scrolled.x(forSeconds: 5), 0, "滚动 5s 后 5s 处在原点")
        XCTAssertEqual(scrolled.seconds(forX: 0), 5)
    }

    // MARK: 可见裁剪

    func testVisibleClipping() {
        let clips = [
            makeClip(trackId: 1, clipId: 1, startMs: 0, durMs: 1000),      // 视口内
            makeClip(trackId: 1, clipId: 2, startMs: -5000, durMs: 1000),  // 完全在左侧外
            makeClip(trackId: 1, clipId: 3, startMs: 100_000, durMs: 1000), // 完全在右侧外
            makeClip(trackId: 1, clipId: 4, startMs: 13_000, durMs: 5000), // 跨视口右缘
        ]
        let layout = makeLayout(trackCount: 1, clips: clips, width: 1200) // 视口 15s
        let visible = layout.visibleClips
        XCTAssertEqual(visible.map { $0.clip.clipId }, [1, 4], "视口外片段被裁剪")
        // 未知轨道的片段不绘制
        let alien = makeClip(trackId: 99, clipId: 9, startMs: 0, durMs: 1000)
        XCTAssertNil(layout.rect(for: alien))
    }

    // MARK: 标尺

    func testRulerTicksAdaptToZoom() {
        // 高缩放：小步长
        let zoomIn = makeLayout(trackCount: 1, clips: [], pixelsPerSecond: 200)
        let ticksIn = zoomIn.rulerTicks()
        XCTAssertTrue(ticksIn.contains(where: { $0.major }), "放大时有主刻度")

        // 低缩放：步长必须变大（1s 刻度间距 < 60pt 不可接受）
        let zoomOut = makeLayout(trackCount: 1, clips: [], pixelsPerSecond: 2)
        let ticksOut = zoomOut.rulerTicks()
        if ticksOut.count > 1 {
            let gap = ticksOut[1].second - ticksOut[0].second
            XCTAssertGreaterThanOrEqual(CGFloat(gap) * 2, 60,
                                        "缩小后相邻刻度间距不足，刻度过密")
        }
    }

    // MARK: 性能（BACKLOG：数百片段）

    func testLayoutOfFiveHundredClipsUnder16ms() {
        // 5 轨 × 100 片段 = 500；间距 10s、时长 5s
        var clips: [ClipInfo] = []
        for track in 1...5 {
            for i in 0..<100 {
                clips.append(makeClip(trackId: UInt64(track),
                                      clipId: UInt64(track * 1000 + i),
                                      startMs: Int64(i) * 10_000, durMs: 5_000))
            }
        }
        let layout = makeLayout(trackCount: 5, clips: clips)

        // 预热（首次运行含类型元数据等一次性开销，不计入）
        _ = layout.visibleClips

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for scroll in stride(from: 0.0, to: 100.0, by: 1.0) {
                let scrolled = TimelineLayout(
                    pixelsPerSecond: 80, scrollSeconds: scroll,
                    viewport: CGSize(width: 1200, height: 400),
                    trackHeight: 44, rulerHeight: 24,
                    tracks: layout.tracks, clips: layout.clips)
                _ = scrolled.visibleClips
                _ = scrolled.rulerTicks()
            }
        }
        let perFrameMs = Double(elapsed.components.attoseconds)
            / 1e18 * 1000 / 100  // 100 帧平均
        print("[baseline] 500 片段单帧布局耗时: \(String(format: "%.3f", perFrameMs)) ms/帧")
        XCTAssertLessThan(perFrameMs, 16.0,
                          "500 片段单帧布局耗时 \(perFrameMs)ms 超预算")
    }
}
