// SharedUI — 时间线交互验收（UIA-005）
//
// 分两层测：
//   1. **纯函数层**（命中测试 / 几何覆盖 / 拖拽夹取）—— 手势判定逻辑必须可测，
//      不能埋在 View 里。
//   2. **ViewModel 层**（move/trim/undo/redo 端到端穿内核）—— 证明 UI 真的改了
//      内核模型，不是只有本地预览动。
//
// ⚠️ 未覆盖：SwiftUI 手势本身（DragGesture 的 onChanged/onEnded）无法在 XCTest
//    里驱动 —— 提交时机与「被拒后回到内核真值」的收口靠代码审查 + App 冒烟。
//    故把可判定的部分（命中、夹取、提交结果）全部抽到纯函数里，这里测得到。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import XCTest
import ChuanqiCut
@testable import ChuanqiCutEditor

@MainActor
final class TimelineInteractionTests: XCTestCase {

    private let ts: Int32 = RationalTime.projectTimescale  // 120000

    private func clip(id: UInt64, start: Int64, duration: Int64,
                      trackId: UInt64 = 1) -> ClipInfo {
        ClipInfo(trackId: trackId, clipId: id, assetId: 1,
                 start: RationalTime(value: start, timescale: ts),
                 duration: RationalTime(value: duration, timescale: ts),
                 sourceIn: RationalTime(value: 0, timescale: ts),
                 sourceDuration: RationalTime(value: duration, timescale: ts),
                 inTransition: 0, outTransition: 0,
                 transitionDuration: RationalTime(value: 0, timescale: ts))
    }

    private func layout(clips: [ClipInfo]) -> TimelineLayout {
        TimelineLayout(pixelsPerSecond: 100, scrollSeconds: 0,
                       viewport: CGSize(width: 800, height: 200),
                       trackHeight: 44, rulerHeight: 24,
                       tracks: [TrackInfo(trackId: 1, kind: 0, enabled: true, muted: false)],
                       clips: clips)
    }

    // MARK: - 命中测试（纯函数）

    func testHitTestDistinguishesMoveTrimAndMiss() throws {
        // clip: start 1s、duration 2s ⇒ x = 100、width = 200、y = 24..68
        let l = layout(clips: [clip(id: 10, start: Int64(ts), duration: Int64(2 * ts))])
        let rect = try XCTUnwrap(l.rect(for: l.clips[0]), "片段应在视口内")
        XCTAssertEqual(rect.minX, 100, accuracy: 0.5)
        XCTAssertEqual(rect.width, 200, accuracy: 0.5)

        // 主体 → 移动
        let moveHit = l.hitTest(CGPoint(x: 150, y: 40))
        XCTAssertEqual(moveHit?.clip.clipId, 10)
        XCTAssertEqual(moveHit?.region, .move)

        // 右边缘 8pt 内 → 裁剪（maxX = 300 ⇒ x ≥ 292）
        let trimHit = l.hitTest(CGPoint(x: 296, y: 40))
        XCTAssertEqual(trimHit?.region, .trimEnd)

        // 左边缘仍归移动（左裁剪要动 source_in，本期内核不支持 —— 任务卡 D2）
        XCTAssertEqual(l.hitTest(CGPoint(x: 102, y: 40))?.region, .move)

        // 空白 / 标尺区 → nil（调用方据此降级为平移视图）
        XCTAssertNil(l.hitTest(CGPoint(x: 500, y: 40)), "空白处不命中片段")
        XCTAssertNil(l.hitTest(CGPoint(x: 150, y: 10)), "标尺区不命中片段")
        XCTAssertNil(l.hitTest(CGPoint(x: 150, y: 100)), "轨道行以外不命中片段")
    }

    func testOverrideChangesGeometryForDraggedClipOnly() throws {
        let l = layout(clips: [clip(id: 10, start: 0, duration: Int64(2 * ts)),
                               clip(id: 11, start: Int64(3 * ts), duration: Int64(2 * ts))])
        let override = ClipPreviewOverride(clipId: 10, startSeconds: 1.0, durationSeconds: 4.0)

        let moved = try XCTUnwrap(l.rect(for: l.clips[0], override: override))
        XCTAssertEqual(moved.minX, 100, accuracy: 0.5, "被拖片段用预览几何")
        XCTAssertEqual(moved.width, 400, accuracy: 0.5)

        let untouched = try XCTUnwrap(l.rect(for: l.clips[1], override: override))
        XCTAssertEqual(untouched.minX, 300, accuracy: 0.5, "其它片段不受影响")
    }

    // MARK: - 拖拽夹取（纯函数）

    func testDragClampsNegativeStartAndTinyDuration() {
        var move = ClipDrag(clipId: 1, region: .move, originStart: 0.5, originDuration: 2.0)
        move.deltaSeconds = -3.0
        XCTAssertEqual(move.previewStart, 0, "起点不得为负（内核不校验负值，UI 先夹住）")
        XCTAssertEqual(move.previewDuration, 2.0, "移动不改时长")

        var trim = ClipDrag(clipId: 1, region: .trimEnd, originStart: 0.5, originDuration: 2.0)
        trim.deltaSeconds = -5.0
        XCTAssertEqual(trim.previewDuration, ClipDrag.minDurationSeconds, "裁剪不得为 0 或负")
        XCTAssertEqual(trim.previewStart, 0.5, "裁剪不改起点")
    }

    // MARK: - ViewModel 端到端（穿内核）

    private func goldenURL() -> URL {
        URL(fileURLWithPath: RepoPath.goldenVideo)
    }

    @discardableResult
    private func waitForTimelineVersion(_ vm: EditorViewModel, _ minVersion: UInt64,
                                        timeoutMs: Int = 5000) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while vm.timeline.version < minVersion && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return vm.timeline.version >= minVersion
    }

    /// 导入 golden → 移动 → 裁剪 → 撤销 ×2 → 重做 ×2，全程断言**内核查询值**。
    func testMoveTrimUndoRedoThroughViewModel() throws {
        let vm = try EditorViewModel()
        let url = goldenURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return XCTFail("golden 夹具缺失：\(url.path)")
        }

        XCTAssertEqual(vm.importMedia(url: url), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, 3), "导入推进到 v3")
        let clipId = try XCTUnwrap(vm.timeline.clips.first?.clipId)
        let originalDuration = try XCTUnwrap(vm.timeline.clips.first?.duration)
        XCTAssertEqual(vm.timeline.clips.first?.start, RationalTime(value: 0, timescale: ts))

        // ---- move 生效 ----
        var v = vm.timeline.version
        XCTAssertEqual(vm.moveClip(clipId: clipId,
                                   to: RationalTime(value: Int64(ts), timescale: ts)), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.clips.first?.start,
                       RationalTime(value: Int64(ts), timescale: ts), "move 生效（内核真值）")

        // ---- trim 生效（只改 duration，不动 sourceIn）----
        v = vm.timeline.version
        XCTAssertEqual(vm.trimClip(clipId: clipId,
                                   duration: RationalTime(value: 60000, timescale: ts)), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.clips.first?.duration,
                       RationalTime(value: 60000, timescale: ts), "trim 生效")
        XCTAssertEqual(vm.timeline.clips.first?.sourceIn,
                       RationalTime(value: 0, timescale: ts), "trim 不动 sourceIn")

        // ---- undo ×2 ----
        v = vm.timeline.version
        XCTAssertEqual(vm.undo(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.clips.first?.duration, originalDuration, "undo trim")

        v = vm.timeline.version
        XCTAssertEqual(vm.undo(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.clips.first?.start,
                       RationalTime(value: 0, timescale: ts), "undo move")

        // ---- redo ×2 ----
        v = vm.timeline.version
        XCTAssertEqual(vm.redo(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.clips.first?.start,
                       RationalTime(value: Int64(ts), timescale: ts), "redo move")

        v = vm.timeline.version
        XCTAssertEqual(vm.redo(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.clips.first?.duration,
                       RationalTime(value: 60000, timescale: ts), "redo trim")

        XCTAssertFalse(vm.canRedo, "redo 到底")
        XCTAssertTrue(vm.canUndo, "仍有可撤销历史（建轨 / 建片段）")
    }

    /// 提交被内核拒绝时：版本不推进、UI 查询值不变（不留"幽灵位置"）。
    func testRejectedMoveLeavesKernelValueIntact() throws {
        let vm = try EditorViewModel()
        let url = goldenURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return XCTFail("golden 夹具缺失：\(url.path)")
        }

        // 两次导入 ⇒ 同轨两个相邻片段
        XCTAssertEqual(vm.importMedia(url: url), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, 3))
        XCTAssertEqual(vm.importMedia(url: url), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, vm.timeline.version + 2))
        XCTAssertEqual(vm.timeline.clips.count, 2)

        let first = try XCTUnwrap(vm.timeline.clips.first)
        let second = vm.timeline.clips[1]

        // 把第一个片段拖到与第二个重叠的位置 → 内核拒绝
        let v = vm.timeline.version
        XCTAssertEqual(vm.moveClip(clipId: first.clipId, to: second.start), .ok,
                       "提交入队成功（校验在 session 线程）")
        Thread.sleep(forTimeInterval: 0.15)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(vm.timeline.version, v, "被拒：版本不推进")
        XCTAssertEqual(vm.timeline.clips.first?.start, first.start,
                       "被拒：片段起点保持内核原值")

        vm.refreshFromKernel()
        XCTAssertEqual(vm.timeline.clips.first?.start, first.start, "主动回查仍为真值")
    }
}
