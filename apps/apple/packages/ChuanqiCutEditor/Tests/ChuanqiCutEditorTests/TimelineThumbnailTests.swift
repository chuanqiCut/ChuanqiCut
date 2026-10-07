// SharedUI — 时间线缩略图 + 居中锚定/缩放界限验收（UIA-037/038）
//
// 三层：
//   1. ClipFrameSampler（采样几何纯函数）：槽宽/张数（≥3 帧）/采样点/槽位映射/桶。
//   2. TimelineZoomMath + TimelineLayout.anchorX（缩放与居中几何纯函数）。
//   3. TimelineThumbnailStore（缓存行为）：去重 / 失败不重试 / LRU / 并发上限 /
//      invalidate —— 抽帧 seam 注入桩，不碰 AVFoundation。
//
// 运行：cd apps/apple/packages/ChuanqiCutEditor && swift test --disable-sandbox

import XCTest
import CoreGraphics
import ChuanqiCutEngine
@testable import ChuanqiCutEditor

// MARK: - 采样几何（UIA-037）

final class ClipFrameSamplerTests: XCTestCase {

    func testSlotWidthNarrowClipShrinksToThreeFrames() {
        // 宽片段 → 首选槽宽；窄片段 → 压缩到三帧铺满（至少三帧的载体）
        XCTAssertEqual(ClipFrameSampler.slotWidth(clipWidth: 300, preferred: 36), 36)
        XCTAssertEqual(ClipFrameSampler.slotWidth(clipWidth: 90, preferred: 36), 30)
        XCTAssertEqual(ClipFrameSampler.slotWidth(clipWidth: 30, preferred: 36), 10)
    }

    func testSampleCountAtLeastThreeAtMostSixty() {
        // 极窄片段也有 3 帧（UIA-038：时间轴至少展示三帧画面）
        XCTAssertEqual(ClipFrameSampler.sampleCount(slotWidth: 30, clipWidth: 30), 3)
        XCTAssertEqual(ClipFrameSampler.sampleCount(slotWidth: 36, clipWidth: 108), 3)
        XCTAssertEqual(ClipFrameSampler.sampleCount(slotWidth: 36, clipWidth: 109), 4)
        // 超长片段钳制在 60 采样
        XCTAssertEqual(ClipFrameSampler.sampleCount(slotWidth: 36, clipWidth: 10_000), 60)
        // 零宽守卫
        XCTAssertEqual(ClipFrameSampler.sampleCount(slotWidth: 36, clipWidth: 0), 0)
    }

    func testSampleSourceSecondsUniformWithinRange() {
        let samples = ClipFrameSampler.sampleSourceSeconds(sourceIn: 5, span: 10, count: 4)
        XCTAssertEqual(samples.count, 4)
        // 均匀且单调，全部落在 [sourceIn, sourceIn + span]
        XCTAssertEqual(samples[0], 5 + 1.25, accuracy: 1e-9)
        XCTAssertEqual(samples[3], 5 + 8.75, accuracy: 1e-9)
        for pair in zip(samples, samples.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }
        for s in samples {
            XCTAssertGreaterThanOrEqual(s, 5)
            XCTAssertLessThanOrEqual(s, 15)
        }
    }

    func testSampleSourceSecondsGuards() {
        XCTAssertTrue(ClipFrameSampler.sampleSourceSeconds(sourceIn: 0, span: 0, count: 4).isEmpty)
        XCTAssertTrue(ClipFrameSampler.sampleSourceSeconds(sourceIn: 0, span: 5, count: 0).isEmpty)
        XCTAssertEqual(ClipFrameSampler.sampleSourceSeconds(sourceIn: 2, span: 4, count: 1), [4.0])
    }

    func testSlotSampleIndexReuse() {
        // 采样少于槽位（钳制 60）时相邻槽位复用；恒在界内且单调
        XCTAssertEqual(ClipFrameSampler.slotSampleIndex(slot: 0, slots: 100, samples: 60), 0)
        XCTAssertEqual(ClipFrameSampler.slotSampleIndex(slot: 99, slots: 100, samples: 60), 59)
        let mapping = (0..<100).map { ClipFrameSampler.slotSampleIndex(slot: $0, slots: 100, samples: 60) }
        for pair in zip(mapping, mapping.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1)
        }
        XCTAssertEqual(ClipFrameSampler.slotSampleIndex(slot: 2, slots: 3, samples: 3), 2)
    }

    func testBucketFloors() {
        XCTAssertEqual(ClipFrameSampler.bucket(of: 10.33), 10)
        XCTAssertEqual(ClipFrameSampler.bucket(of: 10.0), 10)
        XCTAssertEqual(ClipFrameSampler.bucket(of: -0.2), -1)
    }
}

// MARK: - 缩放界限（UIA-038）

final class TimelineZoomMathTests: XCTestCase {

    private let frame = 1.0 / 30.0

    func testClampBounds() {
        // 常规值不动；过小 → 全时长入视口；过大 → 一帧一槽（36pt/帧 = 1080pps @30fps）
        XCTAssertEqual(TimelineZoomMath.clamp(80, viewportWidth: 400, durationSeconds: 10,
                                              frameDuration: frame, thumbnailWidth: 36), 80)
        XCTAssertEqual(TimelineZoomMath.clamp(20, viewportWidth: 400, durationSeconds: 10,
                                              frameDuration: frame, thumbnailWidth: 36), 40)
        XCTAssertEqual(TimelineZoomMath.clamp(5_000, viewportWidth: 400, durationSeconds: 10,
                                              frameDuration: frame, thumbnailWidth: 36),
                       1080, accuracy: 0.001)
    }

    func testClampShortTimelineNeverInverts() {
        // 超短时间线：全时长入视口所需 pps 高于帧级上界 → 以上界封顶，不产生反向区间
        let clamped = TimelineZoomMath.clamp(20, viewportWidth: 400, durationSeconds: 0.1,
                                             frameDuration: frame, thumbnailWidth: 36)
        XCTAssertLessThanOrEqual(clamped, 1080.001)
        XCTAssertGreaterThan(clamped, 0)
    }

    func testSnapToFrame() {
        XCTAssertEqual(TimelineZoomMath.snapToFrame(seconds: 1.044, frameDuration: frame),
                       31.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(TimelineZoomMath.snapToFrame(seconds: -1, frameDuration: frame), 0)
    }
}

// MARK: - 居中锚定几何（UIA-038）

final class TimelineLayoutAnchorTests: XCTestCase {

    private func makeLayout(anchorX: CGFloat, viewportWidth: CGFloat = 300) -> TimelineLayout {
        TimelineLayout(pixelsPerSecond: 80, scrollSeconds: 10, viewport: CGSize(width: viewportWidth, height: 200),
                       trackHeight: 44, rulerHeight: 24, tracks: [], clips: [], anchorX: anchorX)
    }

    func testAnchorXMapsAnchorTimeToAnchorPoint() {
        let layout = makeLayout(anchorX: 100)
        XCTAssertEqual(layout.x(forSeconds: 10), 100)          // scrollSeconds → anchor
        XCTAssertEqual(layout.x(forSeconds: 11), 180)          // +1s = +pps
        XCTAssertEqual(layout.seconds(forX: 180), 11, accuracy: 1e-9)  // 往返
    }

    func testVisibleRangeSymmetricAroundAnchor() {
        let layout = makeLayout(anchorX: 100)  // viewport 300 → 左 100px 右 200px
        XCTAssertEqual(layout.visibleRange.lowerBound, 10 - 100.0 / 80.0, accuracy: 1e-9)
        XCTAssertEqual(layout.visibleRange.upperBound, 10 + 200.0 / 80.0, accuracy: 1e-9)
    }

    func testPlayheadXIsAnchor() {
        XCTAssertEqual(makeLayout(anchorX: 150).playheadX(playheadSeconds: 10), 150)
    }

    func testDefaultAnchorKeepsLegacyBehavior() {
        // anchorX 缺省 0：x/visibleRange 与既有行为逐位一致（零回归锚）
        let layout = TimelineLayout(pixelsPerSecond: 80, scrollSeconds: 5,
                                    viewport: CGSize(width: 400, height: 200),
                                    trackHeight: 44, rulerHeight: 24, tracks: [], clips: [])
        XCTAssertEqual(layout.x(forSeconds: 6), 80)
        XCTAssertEqual(layout.visibleRange.lowerBound, 5, accuracy: 1e-9)
        XCTAssertEqual(layout.visibleRange.upperBound, 10, accuracy: 1e-9)
    }

    func testRulerTicksReachFramePrecisionAtMaxZoom() {
        // 最大放大（一帧一槽 = 1080pps）：步长落到 2 帧（72pt ≥ 60pt 下限）
        let layout = TimelineLayout(pixelsPerSecond: 1080, scrollSeconds: 0,
                                    viewport: CGSize(width: 800, height: 200),
                                    trackHeight: 44, rulerHeight: 24, tracks: [], clips: [])
        let ticks = layout.rulerTicks()
        XCTAssertFalse(ticks.isEmpty)
        let step = ticks[1].second - ticks[0].second
        XCTAssertEqual(step, 2.0 / 30.0, accuracy: 1e-9)
    }
}

// MARK: - 抽帧缓存（UIA-037）

/// 线程安全的 provider 探针（@Sendable 闭包内计数必须加锁）。
private final class ProviderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var concurrent = 0
    private var peak = 0

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var peakConcurrency: Int { lock.lock(); defer { lock.unlock() }; return peak }

    func start() {
        lock.lock()
        calls += 1
        concurrent += 1
        peak = max(peak, concurrent)
        lock.unlock()
    }

    func end() {
        lock.lock()
        concurrent -= 1
        lock.unlock()
    }
}

@MainActor
final class TimelineThumbnailStoreTests: XCTestCase {

    private func makeImage() -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    /// 轮询等待（异步完成无固定时点；上限 2s 兜底）。
    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testCompletionCachesAndBumpsRevision() async {
        let image = makeImage()
        let store = TimelineThumbnailStore(frameProvider: { _, _, _ in image })
        store.setAssets([1: "/tmp/a.mp4"])
        store.requestSamples(assetId: 1, sourceSeconds: [0.5])
        await waitUntil { store.revision >= 1 }
        XCTAssertNotNil(store.cachedImage(assetId: 1, sourceSecond: 0.5))
        // 同桶其他源秒命中同缓存（桶粒度 1s）
        XCTAssertNotNil(store.cachedImage(assetId: 1, sourceSecond: 0.9))
        XCTAssertNil(store.cachedImage(assetId: 1, sourceSecond: 1.5))
    }

    func testDedupAcrossClipsAndRepeatRequests() async {
        let probe = ProviderProbe()
        let image = makeImage()
        let store = TimelineThumbnailStore(frameProvider: { _, _, _ in
            probe.start()
            try? await Task.sleep(nanoseconds: 10_000_000)
            probe.end()
            return image
        })
        store.setAssets([1: "/tmp/a.mp4"])
        // 两片段采样重叠桶（0..5s 与 2..8s）+ 重复请求 → 每桶只解码一次
        store.requestSamples(assetId: 1,
                             sourceSeconds: ClipFrameSampler.sampleSourceSeconds(sourceIn: 0, span: 5, count: 5))
        store.requestSamples(assetId: 1,
                             sourceSeconds: ClipFrameSampler.sampleSourceSeconds(sourceIn: 2, span: 6, count: 6))
        store.requestSamples(assetId: 1,
                             sourceSeconds: ClipFrameSampler.sampleSourceSeconds(sourceIn: 0, span: 5, count: 5))
        await waitUntil(timeout: 3) { probe.callCount >= 8 }
        await waitUntil { store.revision >= 8 }
        // 去重收口：等一波后再发同样请求，零新增调用
        let before = probe.callCount
        store.requestSamples(assetId: 1,
                             sourceSeconds: ClipFrameSampler.sampleSourceSeconds(sourceIn: 0, span: 5, count: 5))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.callCount, before)
    }

    func testFailureNotRetried() async {
        let probe = ProviderProbe()
        let store = TimelineThumbnailStore(frameProvider: { _, _, _ in
            probe.start()
            probe.end()
            return nil  // 全部失败
        })
        store.setAssets([1: "/tmp/a.mp4"])
        store.requestSamples(assetId: 1, sourceSeconds: [0.5])
        await waitUntil { store.revision >= 1 }
        XCTAssertNil(store.cachedImage(assetId: 1, sourceSecond: 0.5))
        // 失败桶再次请求 → 不重试（防风暴）
        store.requestSamples(assetId: 1, sourceSeconds: [0.5])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.callCount, 1)
    }

    func testMissingAssetIsNoOp() async {
        let probe = ProviderProbe()
        let store = TimelineThumbnailStore(frameProvider: { _, _, _ in
            probe.start()
            probe.end()
            return nil
        })
        store.requestSamples(assetId: 99, sourceSeconds: [0.5])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.callCount, 0)
        XCTAssertEqual(store.revision, 0)
    }

    func testLRUEviction() async {
        let image = makeImage()
        let store = TimelineThumbnailStore(frameProvider: { _, _, _ in image })
        store.setAssets([1: "/tmp/a.mp4"])
        // 241 个不同桶 → 容量 240，最早的桶被逐出
        let seconds = (0..<241).map { Double($0) + 0.5 }
        store.requestSamples(assetId: 1, sourceSeconds: seconds)
        await waitUntil(timeout: 4) { store.revision >= 241 }
        XCTAssertNil(store.cachedImage(assetId: 1, sourceSecond: 0.5))   // 最老 → 逐出
        XCTAssertNotNil(store.cachedImage(assetId: 1, sourceSecond: 240.5))  // 最新 → 保留
    }

    func testConcurrencyCap() async {
        let probe = ProviderProbe()
        let image = makeImage()
        let store = TimelineThumbnailStore(frameProvider: { _, _, _ in
            probe.start()
            try? await Task.sleep(nanoseconds: 30_000_000)
            probe.end()
            return image
        })
        store.setAssets([1: "/tmp/a.mp4"])
        let seconds = (0..<20).map { Double($0) + 0.5 }
        store.requestSamples(assetId: 1, sourceSeconds: seconds)
        await waitUntil(timeout: 4) { store.revision >= 20 }
        XCTAssertLessThanOrEqual(probe.peakConcurrency, TimelineThumbnailStore.maxConcurrentDecodes)
    }

    func testInvalidateClearsEverything() async {
        let image = makeImage()
        let store = TimelineThumbnailStore(frameProvider: { _, _, _ in image })
        store.setAssets([1: "/tmp/a.mp4"])
        store.requestSamples(assetId: 1, sourceSeconds: [0.5])
        await waitUntil { store.revision >= 1 }
        store.invalidate()
        XCTAssertNil(store.cachedImage(assetId: 1, sourceSecond: 0.5))
        // invalidate 后同请求重新发起（failed/inflight 已清）
        store.requestSamples(assetId: 1, sourceSeconds: [0.5])
        await waitUntil { store.revision >= 2 }
        XCTAssertNotNil(store.cachedImage(assetId: 1, sourceSecond: 0.5))
    }
}
