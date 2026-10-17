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
// 运行：cd ui/SharedUI && swift test --disable-sandbox

import XCTest
import ChuanqiCutEngine
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

        // 左边缘 8pt 内 → 左缘裁剪（EDIT-008：内核 trim-clip-in 已支持）
        XCTAssertEqual(l.hitTest(CGPoint(x: 102, y: 40))?.region, .trimStart)

        // 空白 / 标尺区 → nil（调用方据此降级为平移视图）
        XCTAssertNil(l.hitTest(CGPoint(x: 500, y: 40)), "空白处不命中片段")
        XCTAssertNil(l.hitTest(CGPoint(x: 150, y: 10)), "标尺区不命中片段")
        XCTAssertNil(l.hitTest(CGPoint(x: 150, y: 100)), "轨道行以外不命中片段")
    }

    func testHitTestNarrowClipFallsBackToMove() {
        // 宽度 < 2×手柄宽（8pt × 2 → 0.16s @ 100pps）：两个手柄互相吃掉主体，
        // 整体归「移动」，避免窄片段无法拖拽。
        let l = layout(clips: [clip(id: 10, start: 0, duration: Int64(ts) / 10)])  // 0.1s = 10pt
        XCTAssertEqual(l.hitTest(CGPoint(x: 2, y: 40))?.region, .move)
        XCTAssertEqual(l.hitTest(CGPoint(x: 9, y: 40))?.region, .move)
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

    /// 左缘裁剪（EDIT-008）：右缘恒定，duration 收缩量 = 起点位移量。
    func testDragTrimStartKeepsRightEdgeFixed() {
        var trim = ClipDrag(clipId: 1, region: .trimStart, originStart: 1.0, originDuration: 3.0)

        // 右拖 0.5s：start 1.0→1.5，duration 3.0→2.5（右缘 4.0 不动）
        trim.deltaSeconds = 0.5
        XCTAssertEqual(trim.previewStart, 1.5)
        XCTAssertEqual(trim.previewDuration, 2.5)

        // 左拖 1s（向左扩展）：start 1.0→0，duration 3.0→4.0 —— 右缘仍 4.0。
        // 内核侧若素材无余量（source_in < 0）会拒绝；UI 预览如实显示扩展。
        trim.deltaSeconds = -1.0
        XCTAssertEqual(trim.previewStart, 0)
        XCTAssertEqual(trim.previewDuration, 4.0)
        XCTAssertEqual(trim.previewStart + trim.previewDuration, 4.0,
                       "右缘（start + duration）在任何位移下恒定")

        // 越过右缘：夹到最短时长并锚住右缘（不滑走）
        trim.deltaSeconds = 10.0
        XCTAssertEqual(trim.previewDuration, ClipDrag.minDurationSeconds, "左裁不得为 0 或负")
        XCTAssertEqual(trim.previewStart + trim.previewDuration, 4.0, accuracy: 1e-9,
                       "夹取后右缘仍恒定")
    }

    /// 分割可用性判定（UIA-039）：播放头严格落在片段内部（开区间）。
    func testIsStrictlyInsideForSplit() {
        let c = clip(id: 1, start: Int64(ts), duration: Int64(2 * ts))  // [1.0, 3.0)s
        XCTAssertTrue(TimelineLayout.isStrictlyInside(c, atSeconds: 1.5), "片段中部可分割")
        XCTAssertFalse(TimelineLayout.isStrictlyInside(c, atSeconds: 1.0), "切在 start 边界不可分割")
        XCTAssertFalse(TimelineLayout.isStrictlyInside(c, atSeconds: 3.0), "切在 end 边界不可分割")
        XCTAssertFalse(TimelineLayout.isStrictlyInside(c, atSeconds: 0.5), "片段前不可分割")
        XCTAssertFalse(TimelineLayout.isStrictlyInside(c, atSeconds: 3.5), "片段后不可分割")
    }

    // MARK: - 多轨与面板（UIA-040）

    /// 跨轨落点行（纯函数）：Δy 按行距取整 + 夹取到 [0, rowCount)。
    func testDropTrackRowMath() {
        // 行距 48pt：+48 → 下一行，-100 → 上两行，越界夹取。
        XCTAssertEqual(ClipDrag.dropTrackRow(originRow: 0, deltaY: 48, rowPitch: 48, rowCount: 3), 1)
        XCTAssertEqual(ClipDrag.dropTrackRow(originRow: 0, deltaY: 23, rowPitch: 48, rowCount: 3), 0,
                       "不足半行不换轨")
        XCTAssertEqual(ClipDrag.dropTrackRow(originRow: 2, deltaY: -100, rowPitch: 48, rowCount: 3), 0,
                       "负向夹到首行")
        XCTAssertEqual(ClipDrag.dropTrackRow(originRow: 0, deltaY: 999, rowPitch: 48, rowCount: 2), 1,
                       "正向夹到末行")
        XCTAssertEqual(ClipDrag.dropTrackRow(originRow: 1, deltaY: 48, rowPitch: 48, rowCount: 0), 1,
                       "无轨道时原样返回（防呆）")
    }

    /// 跨轨预览行只作用于被拖拽片段（rect 的 rowOverride 语义）。
    func testRectRowOverrideOnlyAffectsDraggedClip() throws {
        let l = layout(clips: [clip(id: 10, start: 0, duration: Int64(2 * ts)),
                               clip(id: 11, start: Int64(3 * ts), duration: Int64(2 * ts))])
        let override = ClipPreviewOverride(clipId: 10, startSeconds: 0, durationSeconds: 2.0)
        // 行高 44 + 间距 4 = 48；clip10 在行 0（y=24），override 行 1（y=72）。
        let dragged = try XCTUnwrap(l.rect(for: l.clips[0], override: override, rowOverride: 1))
        XCTAssertEqual(dragged.minY, 24 + 48, accuracy: 0.5, "被拖片段画在目标行")
        let untouched = try XCTUnwrap(l.rect(for: l.clips[1], override: override, rowOverride: 1))
        XCTAssertEqual(untouched.minY, 24, accuracy: 0.5, "其它片段不受 rowOverride 影响")
        // 不带 override 时 rowOverride 不生效（命中测试等路径的既有行为不变）。
        let plain = try XCTUnwrap(l.rect(for: l.clips[0], rowOverride: 1))
        XCTAssertEqual(plain.minY, 24, accuracy: 0.5, "无 override 时按真实轨道")
        XCTAssertEqual(l.trackRow(forTrackId: 1), 0, "trackRow 解析")
        XCTAssertNil(l.trackRow(forTrackId: 999), "未知轨道返回 nil")
    }

    /// 面板分级状态机（UI 状态，VM 驱动）：选中 ↔ 一级 ↔ 抽屉，单焦点语义。
    func testToolbarModeTransitions() throws {
        let vm = try EditorViewModel()
        XCTAssertEqual(vm.toolbarMode, .primary)

        vm.selectClip(42)
        XCTAssertEqual(vm.toolbarMode, .clipSelected, "选中 → 选中动作条")
        vm.selectClip(42)
        XCTAssertNil(vm.selectedClipId)
        XCTAssertEqual(vm.toolbarMode, .primary, "取消选中 → 一级")

        vm.selectClip(42)
        vm.openDrawer(.ratio)
        XCTAssertEqual(vm.toolbarMode, .drawer(.ratio), "抽屉开启")
        vm.selectClip(7)
        XCTAssertEqual(vm.toolbarMode, .clipSelected,
                       "单焦点：选中开启时抽屉被选中条替换")
        // 选中条上再收起 = 退出选中（2026-10-15 修的 closePanel clipSelected 分支）。
        // 此前这条断言的是改前的旧语义「有选中就回 .clipSelected」，
        // 而改动的动机正是修「选中条上点返回底栏一动不动」（见 AppEntry.swift closePanel 注释）。
        vm.closePanel()
        XCTAssertNil(vm.selectedClipId)
        XCTAssertEqual(vm.toolbarMode, .primary, "选中条收起 → 退出选中")
        // drawer 分支（有选中时收起 → 回选中条）须从 drawer 态进，不能被上一步的 selectClip 替换掉。
        vm.selectClip(42)
        vm.openDrawer(.audio)
        vm.closePanel()
        XCTAssertEqual(vm.toolbarMode, .clipSelected, "抽屉收起 + 仍有选中 → 回选中条")
        vm.selectClip(nil)
        vm.openDrawer(.audio)
        vm.closePanel()
        XCTAssertEqual(vm.toolbarMode, .primary, "无选中 → 返回一级")
    }

    /// 画布 + 跨轨穿内核（UIA-040）：全程断言内核查询值（含快照里的画布字段）。
    func testCanvasAndCrossTrackThroughViewModel() throws {
        let vm = try EditorViewModel()
        let url = goldenURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return XCTFail("golden 夹具缺失：\(url.path)")
        }
        XCTAssertEqual(vm.timeline.canvasWidth, 1080)
        XCTAssertEqual(vm.timeline.canvasHeight, 1920, "默认画布 9:16")
        XCTAssertEqual(vm.importMedia(url: url), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, 3))
        let clipId = try XCTUnwrap(vm.timeline.clips.first?.clipId)

        // ---- 画布：切换 → 快照回流带新比例 → aspect 换算 ----
        var v = vm.timeline.version
        XCTAssertEqual(vm.setCanvas(width: 1080, height: 1080), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.canvasHeight, 1080, "画布经快照回流生效")
        XCTAssertEqual(vm.canvasAspect, 1.0, accuracy: 0.0001)
        v = vm.timeline.version
        XCTAssertEqual(vm.undo(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.canvasHeight, 1920, "undo 画布（可撤销）")

        // ---- 跨轨：新增画中画轨 → 片段移过去（id 不变）→ undo 回原轨 ----
        v = vm.timeline.version
        XCTAssertEqual(vm.addOverlayTrack(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        let overlayTrack = try XCTUnwrap(vm.timeline.tracks.last?.trackId)
        XCTAssertEqual(vm.moveClipToTrack(clipId: clipId, to: overlayTrack,
                                          start: RationalTime(value: 0, timescale: ts)), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, vm.timeline.version + 1))
        let moved = try XCTUnwrap(vm.timeline.clips.first { $0.clipId == clipId })
        XCTAssertEqual(moved.trackId, overlayTrack, "片段上画中画轨（id 不变）")
        v = vm.timeline.version
        XCTAssertEqual(vm.undo(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        let restored = try XCTUnwrap(vm.timeline.clips.first { $0.clipId == clipId })
        XCTAssertNotEqual(restored.trackId, overlayTrack, "undo 跨轨回原轨")
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

    /// 分割 / 删除穿内核（UIA-039，EDIT-007/008 收口）：全程断言内核查询值。
    /// 选中是 UI 本地态 —— 分割后左半保留原 id，选中态自然延续。
    func testSplitAndDeleteThroughViewModel() throws {
        let vm = try EditorViewModel()
        let url = goldenURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return XCTFail("golden 夹具缺失：\(url.path)")
        }
        XCTAssertEqual(vm.importMedia(url: url), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, 3), "导入推进到 v3")
        let clipId = try XCTUnwrap(vm.timeline.clips.first?.clipId)
        let originalDuration = try XCTUnwrap(vm.timeline.clips.first?.duration)

        // ---- 选中 + 边界置灰判定 ----
        vm.selectClip(clipId)
        XCTAssertEqual(vm.selectedClipId, clipId)
        vm.selectClip(clipId)  // 再点同一片段 = 取消
        XCTAssertNil(vm.selectedClipId, "重复点选取消选中")
        vm.selectClip(clipId)
        XCTAssertFalse(vm.canSplitSelected, "播放头 0 在片段外（片段从追加时刻起）→ 分割置灰")

        // ---- 播放头推进到片段内部 → 分割生效 ----
        let start = try XCTUnwrap(vm.timeline.clips.first?.start)
        let mid = RationalTime(value: start.value + originalDuration.value / 2,
                               timescale: ts)
        vm.setPlayhead(mid)
        XCTAssertTrue(vm.canSplitSelected, "播放头严格在片段内部 → 可分割")
        var v = vm.timeline.version
        XCTAssertEqual(vm.splitSelectedAtPlayhead(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.clips.count, 2, "分割后两个片段")
        XCTAssertEqual(vm.selectedClipId, clipId, "左半保留原 id，选中态延续")
        let left = try XCTUnwrap(vm.timeline.clips.first { $0.clipId == clipId })
        let right = try XCTUnwrap(vm.timeline.clips.first { $0.clipId != clipId })
        XCTAssertEqual(left.duration, RationalTime(value: originalDuration.value / 2,
                                                   timescale: ts), "左半收缩")
        XCTAssertEqual(right.start, mid, "右半从分割点起（内核真值）")
        XCTAssertEqual(right.sourceIn,
                       RationalTime(value: originalDuration.value / 2, timescale: ts),
                     "右半 sourceIn 推进（媒体引用联动）")

        // ---- undo：回到单片段（选中片段仍在 → 选中态保留）----
        v = vm.timeline.version
        XCTAssertEqual(vm.undo(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.clips.count, 1, "undo split 回到单片段")
        XCTAssertEqual(vm.selectedClipId, clipId)

        // ---- redo → 删除右半（VM 路径 deleteSelected 靶子是选中 id=左半，
        //      这里直接删右半验证 removeClip 命令本身）----
        XCTAssertEqual(vm.redo(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, vm.timeline.version + 1))
        XCTAssertEqual(vm.timeline.clips.count, 2)
        v = vm.timeline.version
        XCTAssertEqual(vm.removeClip(clipId: right.clipId), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertEqual(vm.timeline.clips.count, 1)

        // ---- 删除选中（UI 路径）：选中清除 + 片段消失 ----
        XCTAssertEqual(vm.selectedClipId, clipId, "右半被删不影响左半选中")
        v = vm.timeline.version
        XCTAssertEqual(vm.deleteSelectedClip(), .ok)
        XCTAssertTrue(waitForTimelineVersion(vm, v + 1))
        XCTAssertNil(vm.selectedClipId, "删除后选中清除")
        XCTAssertTrue(vm.timeline.clips.isEmpty, "删除后时间线为空（只剩空轨道）")
    }
}
