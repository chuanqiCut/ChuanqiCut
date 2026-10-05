// SharedUI — 独立播放器缩略图装载器（UIA-015；SPEC-UIA-020 §4.2）
//
// 进度条拖动气泡的帧预览：按秒取桶（bucket = floor(seconds)），命中 LRU
// 缓存直接返回；未命中按桶去重后用 AVAssetImageGenerator 异步生成
// （tolerance ±1s 换速度，maximumSize 钳制单张内存）。缓存上界 120 张，
// 超出按最久未用驱逐 —— 内存上界 ≈120 × 270KB ≈ 32MB [E]（待真机回填
// baselines；低端机若吃紧 V1 降 maximumSize/上界）。
//
// 本文件是 Player 域允许使用 AVFoundation 的四个文件之一。

import AVFoundation
import CoreGraphics
import Foundation
import os

@MainActor
final class VideoThumbnailLoader {

    /// 生成完成回调（bucket, image）。image = nil 表示该桶生成失败
    /// （调用方降级为纯时间气泡）。只在主隔离域回调。
    var onUpdate: ((Int, CGImage?) -> Void)?

    private let url: URL
    private let maximumSize: CGSize
    private var cache: [Int: CGImage] = [:]
    /// LRU 访问序（队尾 = 最近使用）。
    private var order: [Int] = []
    private var inflight: Set<Int> = []
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var warmupTask: Task<Void, Never>?

    private static let maxCachedThumbnails = 120
    private let log = Logger(subsystem: "com.chuanqi.cut", category: "VideoThumbnailLoader")

    init(url: URL, maximumSize: CGSize = CGSize(width: 480, height: 480)) {
        self.url = url
        self.maximumSize = maximumSize
    }

    /// 同步查缓存（命中返回；未命中返回 nil，不发起生成）。
    func cachedThumbnail(atSecond seconds: TimeInterval) -> CGImage? {
        let bucket = Int(seconds.rounded(.down))
        guard let image = cache[bucket] else { return nil }
        touch(bucket)
        return image
    }

    /// 异步生成（按桶去重；完成/失败都经 onUpdate 回调）。
    func requestThumbnail(atSecond seconds: TimeInterval) {
        let bucket = Int(seconds.rounded(.down))
        guard cache[bucket] == nil, !inflight.contains(bucket) else { return }
        inflight.insert(bucket)
        let target = CMTime(seconds: Double(bucket) + 0.5, preferredTimescale: 600)
        tasks[bucket] = Task { [weak self] in
            guard let self = self else { return }
            let asset = AVURLAsset(url: self.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = self.maximumSize
            // 放宽容差换速度：气泡预览不需要帧精确（RESEARCH-006 §3.2）。
            let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            do {
                let result = try await generator.image(at: target)
                self.finish(bucket: bucket, image: result.image)
            } catch {
                // 失败静默降级（无视频轨/文件不可读/被取消）——控制层退化为时间气泡。
                self.log.error("缩略图生成失败 bucket=\(bucket): \(String(describing: error), privacy: .public)")
                self.finish(bucket: bucket, image: nil)
            }
        }
    }

    /// 就绪后批量预热均匀分布的缩略图（拖动气泡就近命中缓存，不必现等生成）。
    /// 逐张错峰 50ms，避免就绪瞬间并发 N 个解码任务；按桶去重照常生效。
    func warmup(duration: TimeInterval, count: Int) {
        guard duration > 0, count > 0 else { return }
        warmupTask?.cancel()
        warmupTask = Task { [weak self] in
            for index in 0..<count {
                guard let self = self else { return }
                if Task.isCancelled { return }
                let seconds = duration * (Double(index) + 0.5) / Double(count)
                self.requestThumbnail(atSecond: seconds)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func invalidate() {
        warmupTask?.cancel()
        warmupTask = nil
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        inflight.removeAll()
        cache.removeAll()
        order.removeAll()
    }

    // MARK: 内部

    private func finish(bucket: Int, image: CGImage?) {
        inflight.remove(bucket)
        tasks[bucket] = nil
        if let image = image {
            cache[bucket] = image
            touch(bucket)
            evictIfNeeded()
        }
        onUpdate?(bucket, image)
    }

    private func touch(_ bucket: Int) {
        order.removeAll { $0 == bucket }
        order.append(bucket)
    }

    private func evictIfNeeded() {
        while order.count > Self.maxCachedThumbnails {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
