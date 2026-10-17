// TrackInteraction reducer 验收（UIA-041 / U0）
//
// 这些用例的存在意义：**证明「手势 → 命令」这条链路可以在没有 UI 框架、没有内核 Session
// 的情况下被完整判定**（对比 TimelineInteractionTests 里那句「SwiftUI 手势无法在 XCTest 里
// 驱动」）。此前这部分逻辑埋在 View 里，只能靠代码审查；现在它是可断言的纯函数。
//
// 有两组用例是**直接证明 U0 价值的**（换不到的，加成顺序 [重要]）：
//   1. `testZeroDeltaDragEmitsNothing` —— 零位移不提交。此守卫原先**只有 UIKit 侧有**，
//      SwiftUI 侧无条件提交，同一操作在两条路径上产生不同的撤销栈。
//   2. `testDragEndedUsesFinalTranslation` —— 末次位移以 ended 为准。原先 UIKit 沿用最后一次
//      changed、SwiftUI 重算，两者在快速甩动下会落到不同的时间点。
//
// 运行：cd ui/ChuanqiCutEditor && swift test --disable-sandbox

import XCTest
import CoreGraphics
import ChuanqiCutEngine
@testable import ChuanqiCutEditor

final class TrackInteractionReducerTests: XCTestCase {

    private let ts: Int32 = RationalTime.projectTimescale  // 120000

    // MARK: - 夹具

    private func clip(id: UInt64, start: Double, duration: Double,
                      trackId: UInt64 = 1) -> ClipInfo {
        ClipInfo(trackId: trackId, clipId: id, assetId: 1,
                 start: RationalTime(value: Int64(start * Double(ts)), timescale: ts),
                 duration: RationalTime(value: Int64(duration * Double(ts)), timescale: ts),
                 sourceIn: RationalTime(value: 0, timescale: ts),
                 sourceDuration: RationalTime(value: Int64(duration * Double(ts)), timescale: ts),
                 inTransition: 0, outTransition: 0,
                 transitionDuration: RationalTime(value: 0, timescale: ts))
    }

    /// 单轨布局：pps=100、anchorX=0 ⇒ 时间 t 的 x = t·100。
    /// clip(start:1s, duration:2s) ⇒ rect = x 100…300、y 24…68。
    private func layout(clips: [ClipInfo], trackCount: Int = 1) -> TimelineLayout {
        let tracks = (1...trackCount).map {
            TrackInfo(trackId: UInt64($0), kind: 0, enabled: true, muted: false)
        }
        return TimelineLayout(pixelsPerSecond: 100, scrollSeconds: 0,
                              viewport: CGSize(width: 800, height: 220),
                              trackHeight: 44, rulerHeight: 24,
                              tracks: tracks, clips: clips)
    }

    private func ticks(_ seconds: Double) -> Int64 {
        Int64((seconds * Double(ts)).rounded())
    }

    // MARK: - tap

    func testTapOnClipEmitsSelectId() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)])

        let intents = TrackInteraction.reduce(&state, event: .tap(location: CGPoint(x: 150, y: 40)),
                                              layout: l)

        XCTAssertEqual(intents, [.selectClip(10)])
    }

    func testTapOnBlankAndRulerEmitsSelectNil() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)])

        XCTAssertEqual(TrackInteraction.reduce(&state, event: .tap(location: CGPoint(x: 500, y: 40)),
                                               layout: l),
                       [.selectClip(nil)], "点空白 = 取消选中")
        XCTAssertEqual(TrackInteraction.reduce(&state, event: .tap(location: CGPoint(x: 150, y: 10)),
                                               layout: l),
                       [.selectClip(nil)], "点标尺区 = 取消选中")
    }

    // MARK: - drag 生命周期

    /// **U0 修掉的双实现分歧之 ①**：零位移不得产出提交。
    /// 原 UIKit 侧有 `abs(deltaSeconds) > 1e-9` 守卫，SwiftUI 侧 `commit` 无条件调用。
    func testZeroDeltaDragEmitsNothing() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)])

        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 150, y: 40)),
                                layout: l)
        XCTAssertNotNil(state.drag, "命中片段主体 → 进入拖拽")

        let ended = TrackInteraction.reduce(&state,
                                            event: .dragEnded(translation: CGSize(width: 0, height: 0)),
                                            layout: l)

        XCTAssertTrue(ended.isEmpty, "零位移不提交，不给撤销栈塞垃圾记录")
        XCTAssertNil(state.drag, "结束时状态归位")
    }

    func testMoveDragCommitsMoveToPreviewStart() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)])

        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 150, y: 40)), layout: l)
        let ended = TrackInteraction.reduce(
            &state, event: .dragEnded(translation: CGSize(width: 50, height: 0)), layout: l)

        XCTAssertEqual(ended, [.commitEdit(.move(clipId: 10,
                                                start: RationalTime(value: ticks(1.5), timescale: ts)))])
    }

    func testTrimEndDragCommitsDurationOnly() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)])

        // x=296 ≥ maxX−8(292) ⇒ 右缘裁剪
        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 296, y: 40)), layout: l)
        XCTAssertEqual(state.drag?.region, .trimEnd)
        let ended = TrackInteraction.reduce(
            &state, event: .dragEnded(translation: CGSize(width: 50, height: 0)), layout: l)

        // 右缘 +0.5s ⇒ duration 2.0→2.5，起点不动
        XCTAssertEqual(ended, [.commitEdit(.trimEnd(clipId: 10,
                                                    duration: RationalTime(value: ticks(2.5), timescale: ts)))])
    }

    func testTrimStartDragCommitsStartOnly() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)])

        // x=102 ≤ minX+8(108) ⇒ 左缘裁剪
        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 102, y: 40)), layout: l)
        XCTAssertEqual(state.drag?.region, .trimStart)
        let ended = TrackInteraction.reduce(
            &state, event: .dragEnded(translation: CGSize(width: 50, height: 0)), layout: l)

        XCTAssertEqual(ended, [.commitEdit(.trimStart(clipId: 10,
                                                      start: RationalTime(value: ticks(1.5), timescale: ts)))],
                       "左缘裁剪只提交起点；sourceIn/duration 由内核按右缘不动推导")
    }

    func testDragCancelledEmitsNothing() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)])

        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 150, y: 40)), layout: l)
        TrackInteraction.reduce(&state, event: .dragChanged(translation: CGSize(width: 50, height: 0)),
                                layout: l)
        let cancelled = TrackInteraction.reduce(&state, event: .dragCancelled, layout: l)

        XCTAssertTrue(cancelled.isEmpty, "取消 = 不提交")
        XCTAssertNil(state.drag)
    }

    /// **U0 修掉的双实现分歧之 ②**：ended 携带的末次位移必须生效。
    /// 原 UIKit 侧沿用最后一次 changed 的值，SwiftUI 侧用 ended 重算。
    func testDragEndedUsesFinalTranslation() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)])

        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 150, y: 40)), layout: l)
        // changed 只到 20pt，真正的落点在 ended 的 80pt
        TrackInteraction.reduce(&state, event: .dragChanged(translation: CGSize(width: 20, height: 0)),
                                layout: l)
        let ended = TrackInteraction.reduce(
            &state, event: .dragEnded(translation: CGSize(width: 80, height: 0)), layout: l)

        XCTAssertEqual(ended, [.commitEdit(.move(clipId: 10,
                                                start: RationalTime(value: ticks(1.8), timescale: ts)))],
                       "以 ended 的累计位移为准（1.0 + 80/100 = 1.8s）")
    }

    // MARK: - 跨轨（UIA-040）

    func testCrossTrackTakesPriorityOverRegion() {
        var state = TrackInteractionState.idle
        // 两轨：片段在第 0 行（trackId=1），目标第 1 行（trackId=2）
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)], trackCount: 2)

        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 150, y: 40)), layout: l)
        // Δy=48 = 一行（trackHeight 44 + spacing 4）⇒ 落到第 1 行
        let ended = TrackInteraction.reduce(
            &state, event: .dragEnded(translation: CGSize(width: 50, height: 48)), layout: l)

        XCTAssertEqual(ended, [.commitEdit(.moveToTrack(clipId: 10, trackId: 2,
                                                        start: RationalTime(value: ticks(1.5), timescale: ts)))],
                       "跨轨优先于 region —— 与既有语义一致")
    }

    /// 只有跨轨、没有水平位移时**也要提交**（改的是所属轨道，时间是没动，但模型确实变了）。
    func testCrossTrackWithoutHorizontalDeltaStillCommits() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)], trackCount: 2)

        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 150, y: 40)), layout: l)
        let ended = TrackInteraction.reduce(
            &state, event: .dragEnded(translation: CGSize(width: 0, height: 48)), layout: l)

        XCTAssertEqual(ended.count, 1, "纯跨轨必须提交 —— 否则换轨操作会静默丢失")
        XCTAssertEqual(ended.first, .commitEdit(.moveToTrack(clipId: 10, trackId: 2,
                                                             start: RationalTime(value: ticks(1.0), timescale: ts))))
    }

    func testCrossTrackBeyondBoundsFallsBackToRegionEdit() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)], trackCount: 2)

        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 150, y: 40)), layout: l)
        // Δy=999 ⇒ 夹到末行（index 1）；仍在两轨内 ⇒ 走跨轨
        let ended = TrackInteraction.reduce(
            &state, event: .dragEnded(translation: CGSize(width: 30, height: 999)), layout: l)
        XCTAssertEqual(ended.first, .commitEdit(.moveToTrack(clipId: 10, trackId: 2,
                                                             start: RationalTime(value: ticks(1.3), timescale: ts))))
    }

    // MARK: - 渲染态派生

    func testRenderStateIsIdleWithoutDrag() {
        XCTAssertEqual(TrackInteraction.renderState(.idle),
                       TrackRenderState.idle)
        XCTAssertNil(TrackInteraction.renderState(.idle).override)
    }

    func testRenderStateDerivesOverrideAndRowOverride() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)], trackCount: 2)

        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 150, y: 40)), layout: l)
        TrackInteraction.reduce(&state, event: .dragChanged(translation: CGSize(width: 50, height: 48)),
                                layout: l)

        let render = TrackInteraction.renderState(state)
        XCTAssertEqual(render.draggingClipId, 10)
        XCTAssertEqual(render.override?.startSeconds ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(render.rowOverride, 1, "跨轨 → 预览画在目标行")

        // 未跨轨：rowOverride 必须为 nil（否则预览会画错行）
        var same = state
        if var d = same.drag { d.targetTrackRow = d.originTrackRow; same.drag = d }
        XCTAssertNil(TrackInteraction.renderState(same).rowOverride)
    }

    // MARK: - 平台仲裁 / scrub 数学

    func testOwnsPanFollowsHitAndKeepsOwnershipDuringDrag() {
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)])
        var idle = TrackInteractionState.idle

        XCTAssertTrue(TrackInteraction.ownsPan(at: CGPoint(x: 150, y: 40), layout: l, state: idle),
                      "命中片段 → 由编辑接管（UIKit 侧返回 true，UIScrollView 不抢）")
        XCTAssertFalse(TrackInteraction.ownsPan(at: CGPoint(x: 500, y: 40), layout: l, state: idle),
                       "未命中 → 让 UIScrollView 接管（原生 scrub 手感）")

        // 拖拽进行中即使指针滑出片段，也必须继续接管。
        TrackInteraction.reduce(&idle, event: .dragBegan(location: CGPoint(x: 150, y: 40)), layout: l)
        XCTAssertTrue(TrackInteraction.ownsPan(at: CGPoint(x: 500, y: 40), layout: l, state: idle),
                      "拖拽中不让滚动抢")
    }

    func testScrubSecondsSnapsToFrameAndNeverNegative() {
        let l = layout(clips: [])
        // anchor 1.0 + 50pt/100pps = 1.5s ⇒ 恰好 45 帧 @30fps
        XCTAssertEqual(TrackInteraction.scrubSeconds(anchorSeconds: 1.0, translationWidth: 50,
                                                     layout: l), 1.5, accuracy: 1e-9)
        // 向左拖过头：不得为负
        XCTAssertEqual(TrackInteraction.scrubSeconds(anchorSeconds: 1.0, translationWidth: -5000,
                                                     layout: l), 0, accuracy: 1e-9)
        // 非整帧位置 → 收到最近的帧边界（30fps ⇒ 1/30 s 栅格）
        let snapped = TrackInteraction.scrubSeconds(anchorSeconds: 1.0, translationWidth: 17, layout: l)
        let frames = (snapped * 30).rounded()
        XCTAssertEqual(snapped, frames / 30, accuracy: 1e-9, "结果必须落在帧栅格上")
    }

    func testPointerOutsideAnyClipEntersScrubbingFlag() {
        var state = TrackInteractionState.idle
        let l = layout(clips: [clip(id: 10, start: 1, duration: 2)])

        TrackInteraction.reduce(&state, event: .dragBegan(location: CGPoint(x: 500, y: 40)), layout: l)

        XCTAssertNil(state.drag)
        XCTAssertTrue(state.isScrubbing, "未命中 → 记 scrub 标记（SwiftUI 侧据此建锚点）")
    }
}
