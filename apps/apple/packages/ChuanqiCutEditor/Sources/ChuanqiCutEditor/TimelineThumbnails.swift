// ChuanqiCutEditor — 时间线缩略图（UIA-037）+ 缩放数学（UIA-038）
//
// 域边界（对照 ADR-0022 决策 4 的 Player 域先例）：**AVFoundation 只许出现在
// 本文件**（抽帧默认实现），视图层只消费 CGImage。代码审查按此检查。
//
// 三块：
//   1. ClipFrameSampler —— 采样几何纯函数（可单测）：片段宽 → 槽位数（≥3，
//      UIA-038「时间轴至少展示三帧画面」）、槽位 → 源时间采样点。
//   2. TimelineThumbnailStore —— 抽帧缓存：键 = (assetId, 源秒桶)，同素材多片段
//      天然共享；in-flight 去重 + 失败记账（防重试风暴）；LRU 上界；并发解码上限
//      （pending 队列 + 完成泵下一发）。抽帧 seam = 注入闭包（测试桩不碰
//      AVFoundation）；默认实现按请求建 AVURLAsset + AVAssetImageGenerator
//      （maximumSize 钳单张内存、tolerance 放宽换速度——胶片条不需帧精确，
//      语义同 Player 域 VideoThumbnailLoader §4.2）。
//   3. TimelineZoomMath —— 缩放界限纯函数（UIA-038）：下界 = 全时长入视口
//      （「最大根据时长来定」），上界 = 一帧占一个缩略图槽宽（「最小就是每一帧
//      画面的间隔」）。帧时长取常数 30fps [E]（素材真实帧率探测未做，MEDIA 线
//      后续透传后替换）。
//
// 红线：主线程不解码 —— 抽帧走 AVAssetImageGenerator 的 async API（解码在其
// 内部队列，同 Player 域先例），完成回调才落 MainActor。

import AVFoundation
import CoreGraphics
import Foundation
import os

// MARK: - 采样几何（纯函数）

enum ClipFrameSampler {

    /// 单片段采样上限：超出后相邻槽位复用同一张图（不随宽度线性爆解码量）。
    static let maxSamplesPerClip = 60
    /// 每片段至少展示的缩略图帧数（UIA-038）。
    static let minFramesPerClip = 3

    /// 缩略图槽宽：片段足够宽用首选值；过窄时压缩到「三帧恰好铺满」，
    /// 保证窄片段也能展示 ≥3 帧。
    static func slotWidth(clipWidth: CGFloat, preferred: CGFloat) -> CGFloat {
        guard clipWidth > 0, preferred > 0 else { return preferred }
        return clipWidth >= preferred * CGFloat(minFramesPerClip)
            ? preferred
            : clipWidth / CGFloat(minFramesPerClip)
    }

    /// 采样张数：≥ minFramesPerClip，≤ maxSamplesPerClip。
    static func sampleCount(slotWidth: CGFloat, clipWidth: CGFloat) -> Int {
        guard slotWidth > 0, clipWidth > 0 else { return 0 }
        let slots = Int((clipWidth / slotWidth).rounded(.up))
        return min(max(slots, minFramesPerClip), maxSamplesPerClip)
    }

    /// 在 [sourceIn, sourceIn + span] 上均匀取 count 个采样点（半槽偏移）。
    static func sampleSourceSeconds(sourceIn: Double, span: Double, count: Int) -> [Double] {
        guard count > 0, span > 0, span.isFinite else { return [] }
        return (0..<count).map { index in
            let fraction = (Double(index) + 0.5) / Double(count)
            return min(sourceIn + span, max(sourceIn, sourceIn + fraction * span))
        }
    }

    /// 槽位 → 采样下标：采样数少于槽数（超长片段被钳制）时相邻槽位复用同图。
    static func slotSampleIndex(slot: Int, slots: Int, samples: Int) -> Int {
        guard samples > 0, slots > 0 else { return 0 }
        return min(samples - 1, slot * samples / slots)
    }

    /// 源秒 → 缓存桶（1s 桶，同 Player 域 VideoThumbnailLoader 粒度；
    /// 同素材多片段天然共享桶）。
    static func bucket(of sourceSecond: Double, granularity: Double = 1.0) -> Int {
        guard granularity > 0 else { return 0 }
        return Int((sourceSecond / granularity).rounded(.down))
    }
}

// MARK: - 缩放界限（纯函数，UIA-038）

enum TimelineZoomMath {

    /// 帧时长（秒）[E]：按 30fps 常数。素材真实帧率未探测/未透传（MEDIA 线），
    /// 后续替换为 probe 结果；红线 #4 注意这只是**渲染刻度**，时间存储仍是整数。
    static let defaultFrameDuration: Double = 1.0 / 30.0

    /// 缩放界限：
    ///   上界 = 一帧画面占一个缩略图槽宽（最大放大，帧级精度）；
    ///   下界 = 全时长入视口（最大缩小，按总时长定）。
    /// 下界 > 上界（超短时间线）时以两者较小值为准，不产生反向区间。
    static func clamp(_ pixelsPerSecond: CGFloat, viewportWidth: CGFloat,
                      durationSeconds: Double, frameDuration: Double,
                      thumbnailWidth: CGFloat) -> CGFloat {
        let maxPPS = frameDuration > 0 ? CGFloat(thumbnailWidth / CGFloat(frameDuration)) : pixelsPerSecond
        let minPPS = viewportWidth > 0 ? CGFloat(viewportWidth / CGFloat(max(durationSeconds, 1.0))) : pixelsPerSecond
        let lower = min(minPPS, maxPPS)
        return min(maxPPS, max(lower, pixelsPerSecond))
    }

    /// 拖动（scrub）时刻对帧栅格取整 —— 时间轴精度下限 = 一帧（UIA-038）。
    static func snapToFrame(seconds: Double, frameDuration: Double) -> Double {
        guard frameDuration > 0, seconds.isFinite else { return max(0, seconds) }
        return max(0, (seconds / frameDuration).rounded(.down) * frameDuration)
    }
}

// MARK: - 抽帧缓存

/// 缓存键：素材 + 源秒桶。
struct TimelineThumbnailKey: Hashable {
    let assetId: UInt64
    let bucket: Int
}

/// 抽帧 seam（@Sendable 闭包：完成/失败都返回，nil = 失败）。
/// 默认实现见 `TimelineThumbnailStore.avAssetProvider`。
typealias TimelineFrameProvider = @Sendable (_ url: URL, _ sourceSecond: Double,
                                              _ maximumSize: CGSize) async -> CGImage?

@MainActor
final class TimelineThumbnailStore: ObservableObject {

    /// 缓存有变化（新图 / 失败）时置位 —— SwiftUI 侧驱动 Canvas 重绘。
    @Published private(set) var revision = 0
    /// UIKit 侧回调（不依赖 Combine）。
    var onUpdate: (() -> Void)?

    static let maxConcurrentDecodes = 3
    static let maxCachedThumbnails = 240
    static let maxFailedEntries = 200
    /// 桶粒度（秒）。
    static let bucketSeconds = 1.0
    /// 抽帧目标像素尺寸（缩略图槽 36×44pt @2x）。
    static let pixelSize = CGSize(width: 72, height: 88)

    private var assets: [UInt64: String] = [:]
    private var cache: [TimelineThumbnailKey: CGImage] = [:]
    /// LRU 访问序（队尾 = 最近使用）。
    private var order: [TimelineThumbnailKey] = []
    private var inflight: Set<TimelineThumbnailKey> = []
    private var failed: Set<TimelineThumbnailKey> = []
    /// 并发闸：pending FIFO + 完成泵下一发（不重建 AVURLAsset 风暴）。
    private var pending: [TimelineThumbnailKey] = []
    private var running = 0
    private var tasks: [TimelineThumbnailKey: Task<Void, Never>] = [:]

    private let provider: TimelineFrameProvider
    private let log = Logger(subsystem: "com.chuanqi.cut", category: "TimelineThumbnails")

    /// 默认抽帧实现：AVAssetImageGenerator 异步 API（解码在 AVFoundation 内部
    /// 队列 —— 主线程不解码）。tolerance ±0.5s：胶片条不需帧精确，换吞吐。
    static let avAssetProvider: TimelineFrameProvider = { url, sourceSecond, maximumSize in
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let target = CMTime(seconds: sourceSecond, preferredTimescale: 600)
        return try? await generator.image(at: target).image
    }

    /// - Parameter frameProvider: 抽帧 seam；测试注入桩（不碰 AVFoundation）。
    init(frameProvider: @escaping TimelineFrameProvider = TimelineThumbnailStore.avAssetProvider) {
        self.provider = frameProvider
    }

    // MARK: 数据灌入

    /// assetId → 文件路径（mediaLibrary 变化时灌入；路径随内核素材表真值）。
    func setAssets(_ assets: [UInt64: String]) {
        self.assets = assets
    }

    /// 请求一个片段的采样集（已按 LRU/去重/失败记账过滤）。
    /// `sourceSeconds` 来自 ClipFrameSampler.sampleSourceSeconds。
    func requestSamples(assetId: UInt64, sourceSeconds: [Double]) {
        guard let path = assets[assetId] else { return }
        for second in sourceSeconds {
            let key = TimelineThumbnailKey(
                assetId: assetId,
                bucket: ClipFrameSampler.bucket(of: second, granularity: Self.bucketSeconds))
            if cache[key] != nil { continue }
            if failed.contains(key) { continue }
            if inflight.contains(key) { continue }
            inflight.insert(key)
            pending.append(key)
        }
        // 路径惰性解析：只在真正发起解码时转 URL。
        pendingPaths[path] = pendingPaths[path] ?? URL(fileURLWithPath: path)
        pump()
    }

    /// 同步查缓存（命中顺带 touch LRU；未命中不发起请求）。
    func cachedImage(assetId: UInt64, sourceSecond: Double) -> CGImage? {
        let key = TimelineThumbnailKey(
            assetId: assetId,
            bucket: ClipFrameSampler.bucket(of: sourceSecond, granularity: Self.bucketSeconds))
        guard let image = cache[key] else { return nil }
        touch(key)
        return image
    }

    /// 全量失效（编辑页销毁 / 素材表重置）。
    func invalidate() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        pending.removeAll()
        inflight.removeAll()
        running = 0
        cache.removeAll()
        order.removeAll()
        failed.removeAll()
        pendingPaths.removeAll()
    }

    // MARK: 内部

    /// 路径 → URL（pending 键关联；与键解耦以便 invalidate 清理）。
    private var pendingPaths: [String: URL] = [:]

    private func pump() {
        while running < Self.maxConcurrentDecodes, !pending.isEmpty {
            let key = pending.removeFirst()
            guard let path = assets[key.assetId] else {
                inflight.remove(key)
                continue
            }
            let url = pendingPaths[path] ?? URL(fileURLWithPath: path)
            running += 1
            let second = Double(key.bucket) * Self.bucketSeconds + Self.bucketSeconds / 2
            tasks[key] = Task { [weak self] in
                guard let self else { return }
                let image = await self.provider(url, second, Self.pixelSize)
                self.finish(key: key, image: image)
            }
        }
    }

    private func finish(key: TimelineThumbnailKey, image: CGImage?) {
        tasks[key] = nil
        running -= 1
        inflight.remove(key)
        if let image {
            failed.remove(key)
            cache[key] = image
            touch(key)
            evictIfNeeded()
        } else {
            // 失败记账：不重试（文件损坏/无视频轨的桶反复请求只会烧电）；
            // 上界钳制防病态素材表撑爆集合。
            if failed.count < Self.maxFailedEntries {
                failed.insert(key)
            }
            log.error("缩略图生成失败 asset=\(key.assetId) bucket=\(key.bucket)")
        }
        revision += 1
        onUpdate?()
        pump()
    }

    private func touch(_ key: TimelineThumbnailKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > Self.maxCachedThumbnails {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        while failed.count > Self.maxFailedEntries {
            failed.removeFirst()
        }
    }
}
