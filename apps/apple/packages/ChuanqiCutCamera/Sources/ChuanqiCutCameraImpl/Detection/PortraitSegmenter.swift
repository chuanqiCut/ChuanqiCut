// PortraitSegmenter — 人像分割独立管道（CAM-035 P3 前半）
//
// 职责：磨皮/美白开启时，对采集帧按 **15Hz** 跑 VNGeneratePersonSegmentation，
// 产出人像 mask 供语义蒙版（「人像 ∩ 脸框」，美白不再整头发白、磨皮区域稳定）。
//
// 为什么独立于 VisionDetector（设计裁决，2026-10-11）：
//   - 前摄磨皮的框来自采集栈 metadata（CAM-033），detect 因 plan 空集早退——
//     分割若挂在 detect 里**永远不会跑**（E5 实证 det 冻结）。分割的驱动条件
//     是「磨皮开着」而非「detect 在跑」，故独立成管道，帧源 = onVideoFrame。
//   - 15Hz 跳跑在 offer 闸门处做（对齐 VisionDetector 惯例），mask 消费方
//     （FaceBoxStore → PortraitSemantics 闭包）拿最近一次 mask，与脸框求交。
//
// 线程模型（与 VisionDetector 同纪律）：offer 在采集队列非阻塞（闸门+忙检查），
// detect 在专用串行队列；onMask 在分割队列回调。mask = CIImage 不可变值语义。
// 开关：磨皮/美白全关时 offer 直接丢弃（零开销）。

import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Vision

final class PortraitSegmenter: @unchecked Sendable {

    private let configLock = NSLock()
    /// 分割降频上限（Hz）：mask 有脸框约束 + 轮廓时间相关性，15Hz 足够 [E]。
    private var _hz: Double = 15.0
    var hz: Double {
        get { configLock.lock(); defer { configLock.unlock() }; return _hz }
        set { configLock.lock(); _hz = min(max(newValue, 1), 30); configLock.unlock() }
    }
    /// 磨皮/美白开关（VM 在 beauty didSet 同步）。false = offer 直接丢弃。
    private var _enabled = false
    var isEnabled: Bool {
        get { configLock.lock(); defer { configLock.unlock() }; return _enabled }
        set { configLock.lock(); _enabled = newValue; configLock.unlock() }
    }

    /// 分割队列回调：mask（CIImage，白=人像，原生低分辨率 extent）。**不回调 nil**
    /// （失败/无脸静默——消费方持最近有效 mask，过期由脸框约束兜底）。
    var onMask: ((CIImage) -> Void)?

    private let queue = DispatchQueue(label: "cq.camera.segmentation")
    private let stateLock = NSLock()
    private var busy = false
    private var lastPtsSeconds: Double?

    /// 采集队列调用（onVideoFrame 消费口），非阻塞。
    func offer(_ pixelBuffer: CVImageBuffer, at pts: CMTime) {
        guard isEnabled else { return }
        let seconds = pts.seconds
        guard seconds.isFinite else { return }
        stateLock.lock()
        if busy || (lastPtsSeconds.map { seconds - $0 < 1.0 / _hz } ?? false) {
            stateLock.unlock()
            return
        }
        lastPtsSeconds = seconds
        busy = true
        stateLock.unlock()
        nonisolated(unsafe) let frame = pixelBuffer
        queue.async { [weak self] in
            self?.segment(frame)
        }
    }

    private func segment(_ pixelBuffer: CVImageBuffer) {
        defer {
            stateLock.lock()
            busy = false
            stateLock.unlock()
        }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced   // SDK 26.5 头文件实核（P83 纪律）
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return   // 静默：消费方持最近 mask，帧间由脸框约束兜底
        }
        guard let obs = request.results?.first as? VNPixelBufferObservation else { return }
        let raw = CIImage(cvPixelBuffer: obs.pixelBuffer)
        // 立即渲染成独立 bitmap-backed CIImage：CIImage(cvPixelBuffer:) 持有采集
        // buffer pool 的帧（15Hz×多帧滞留 = pool 膨胀，E6 实测 231↔283MB 锯齿）。
        // mask 原生 ~270×480，离线小图渲染开销可忽略 [E]。
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        var bitmap = [UInt8](repeating: 0, count: Int(raw.extent.width * raw.extent.height))
        ctx.render(raw,
                   toBitmap: &bitmap, rowBytes: Int(raw.extent.width),
                   bounds: raw.extent, format: .R8, colorSpace: nil)
        guard let cg = CGContext(data: &bitmap, width: Int(raw.extent.width),
                                 height: Int(raw.extent.height), bitsPerComponent: 8,
                                 bytesPerRow: Int(raw.extent.width),
                                 space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        let image = cg.makeImage()
        guard let cg = image else { return }
        onMask?(CIImage(cgImage: cg))
    }
}
