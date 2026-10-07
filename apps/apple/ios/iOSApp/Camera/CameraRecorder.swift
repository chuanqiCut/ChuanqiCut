// CameraRecorder — 所见即所得录制（CAM-005，ADR-0014）
//
// 视频：采集帧 → 滤镜（录制开始时锁定的预设）→ CIContext 渲染进 CVPixelBufferPool
//       缓冲 → PixelBufferAdaptor（H.264 / 32BGRA）。
// 音频：AVCaptureAudioDataOutput 的 PCM CMSampleBuffer 直喂 AVAssetWriterInput，
//       输出设置指定 AAC，由 AVFoundation 完成编码。
//
// ⚠️ AVFoundation 时序硬约束（PALA-012 同款教训）：**所有 input 必须在
// startWriting 之前 add**。本类在**首个视频帧**上一次性建立 writer + 视频轨 +
// （若带音频）音频轨，然后才 startWriting —— 不允许运行中补轨。
//
// ⚠️ pixelBufferPool 时序（P69，CAM-017 实证）：`adaptor.pixelBufferPool` 在
// `startWriting()` **之前是 nil**。池守卫若排在 startSession 之前 = 每帧必丢、
// writer 永不启动的死锁（真机首验「录制无效」根因）。现序：setup →
// startSession（首帧）→ 取池（懒取+缓存，取不到直配兜底）→ 渲染 → append。
//
// PTS 纪律（对齐 pal-apple.md PALA-012 口径）：会话起点 = 首个视频帧 PTS，
// 早于首帧到达的音频块被丢弃（首帧几乎即时到达，头部截断可忽略且语义诚实）。
//
// 线程模型：appendVideo 只在 videoQueue、appendAudio 只在 audioQueue（由
// CameraManager 回调保证）；start/finish 主线程调用；锁保护状态迁移。

import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import SharedUI
import os

// @unchecked Sendable 的依据：状态迁移由 `lock` 保护，append 只在 videoQueue /
// audioQueue，start/finish 主线程调用（见文件头线程模型）；本类实例在
// CameraViewModel 与采集队列之间传递是安全的。
final class CameraRecorder: @unchecked Sendable {

    enum RecordingError: Error, LocalizedError {
        case writerCreationFailed
        case notRecording
        case alreadyRecording
        case nothingWritten

        var errorDescription: String? {
            switch self {
            case .writerCreationFailed: return "AVAssetWriter 创建失败"
            case .notRecording: return "没有进行中的录制"
            case .alreadyRecording: return "录制已在进行"
            case .nothingWritten: return "没有录制到任何画面"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.chuanqi.cut", category: "camera.recorder")

    private(set) var outputURL: URL

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    /// 池缓存（P69：startWriting 后才非 nil，取到后复用）。只在 videoQueue 触碰。
    private var pixelBufferPool: CVPixelBufferPool?
    private var bufferWidth = 0
    private var bufferHeight = 0
    private var appendedFrames = 0

    private let preset: CameraFilterPreset
    private let beauty: CameraBeautyParams
    /// 人脸框槽（CAM-019）：逐帧读最新值 —— 主体移动时蒙版跟随（WYSIWYG），
    /// 与预览同源（同一 FaceBoxStore，检测队列写 / 本队列读，锁保护）。
    private let faceBoxes: FaceBoxStore?
    private let ciContext: CIContext
    private let withAudio: Bool
    private let lock = NSLock()
    private var sessionStarted = false
    private var isFinished = false

    /// - Parameters:
    ///   - ciContext: 与预览共享的上下文（线程安全）。
    ///   - preset / beauty: 录制开始时锁定的滤镜与美颜（WYSIWYG；录制中面板已锁）。
    ///   - faceBoxes: 人脸框槽（CAM-019 区域化）；nil = 不区域化（美颜全画面，兼容测试）。
    ///   - withAudio: 麦克风权限被拒时传 false（录制降级为无声视频，不伪造有声音）。
    init(outputURL: URL, ciContext: CIContext,
         preset: CameraFilterPreset, beauty: CameraBeautyParams,
         faceBoxes: FaceBoxStore? = nil, withAudio: Bool) {
        self.outputURL = outputURL
        self.ciContext = ciContext
        self.preset = preset
        self.beauty = beauty
        self.faceBoxes = faceBoxes
        self.withAudio = withAudio
    }

    // MARK: 内部建立（只在 videoQueue 首个视频帧上执行一次）

    /// 按首个视频帧的实际尺寸建立 writer 与全部轨道（尺寸不猜，用帧事实）。
    private func setupIfNeeded(with sourceBuffer: CVImageBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if writer != nil { return true }
        if isFinished { return false }

        let width = CVPixelBufferGetWidth(sourceBuffer)
        let height = CVPixelBufferGetHeight(sourceBuffer)

        // 产物路径重建（语义同 IMediaMuxer.Open：存在即删后重建）。
        try? FileManager.default.removeItem(at: outputURL)
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            return false
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { return false }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                // CAM-018：池缓冲显式标 sRGB —— 不标则 CI 线性→gamma 转换结果
                // 按未标记写出，播放器按 sRGB 解读 → 产物与预览颜色不一致
                // （SPEC-CAM-018-019 §1.2；池若实际不接受该键，真机冒烟后
                //  按任务卡备选方案自建带色彩空间的 CVPixelBufferPool）。
                // 修正（P83，2026-10-07）：kCVPixelBufferColorSpaceKey 不存在于
                // SDK（美颜合并轮凭记忆书写，App target 首次真编译才炸）；
                // 色彩空间附件键是 CVImageBuffer 系的 kCVImageBufferCGColorSpaceKey
                // （iOS 4.0+，CVPixelBuffer 继承生效），值 = CGColorSpaceRef。
                kCVImageBufferCGColorSpaceKey as String:
                    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            ])

        var audioInput: AVAssetWriterInput?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = adaptor
        self.bufferWidth = width
        self.bufferHeight = height
        // ⚠️ 此处**不取** pixelBufferPool：startWriting 前它是 nil（P69）。
        Self.logger.info("录制开始 \(width, privacy: .public)×\(height, privacy: .public) audio=\(self.withAudio, privacy: .public)")
        return true
    }

    private func startSessionIfNeeded(at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let writer, !sessionStarted, !isFinished else { return }
        guard writer.startWriting() else { return }  // 失败在 finish 时经 writer.error 暴露
        writer.startSession(atSourceTime: time)
        sessionStarted = true
    }

    // MARK: 帧注入（videoQueue）

    func appendVideo(sourceBuffer: CVImageBuffer, at time: CMTime) {
        guard setupIfNeeded(with: sourceBuffer) else { return }
        lock.lock()
        guard let adaptor, let videoInput, !isFinished else {
            lock.unlock()
            return
        }
        lock.unlock()

        // ⚠️ startSession（含 startWriting）必须在取池**之前**（P69：池在
        // startWriting 前是 nil；旧实现池守卫在前 = 每帧必丢死锁）。
        startSessionIfNeeded(at: time)

        // 美颜（人脸区域化，faces 实时读取）→ 滤镜（与预览 process 同序）。
        // 失败丢帧不崩溃（实时优先）。
        var image = CIImage(cvPixelBuffer: sourceBuffer)
        image = beauty.apply(to: image, faces: faceBoxes?.current())
        if let filtered = preset.apply(to: image) {
            image = filtered
        }
        guard let pixelBuffer = createBuffer(from: adaptor) else {
            return  // 池与直配都失败：丢帧（同采集侧 latest-wins 语义）
        }
        // render(toCVPixelBuffer:) 非 throws（P48）；CI 内部失败不会抛出到此层。
        ciContext.render(image, to: pixelBuffer)

        guard videoInput.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: time)
        let total = recordAppendedFrame()
        if total % 240 == 0 {
            Self.logger.info("录制已写入 \(total, privacy: .public) 帧")
        }
        // pixelBuffer 由 ARC 释放回池（append 内部按需 retain）。
    }

    /// 帧计数自增（锁内：跨线程读经 currentAppendedFrameCount，P74）。
    /// 返回自增后的值供节流日志。只在 videoQueue 调用。
    private func recordAppendedFrame() -> Int {
        lock.lock()
        appendedFrames += 1
        let total = appendedFrames
        lock.unlock()
        return total
    }

    /// 当前已写入帧数（线程安全读；收尾回调用）。
    private func currentAppendedFrameCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return appendedFrames
    }

    // MARK: 音频注入（audioQueue）

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard let audioInput, !isFinished else {
            lock.unlock()
            return  // writer 未建立（尚无视频帧）= 头部丢弃，语义见文件头
        }
        lock.unlock()

        guard audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    // MARK: 收尾（主线程）

    /// 停止录制并等待落盘。完成/失败都在主线程回调；失败删除半成品（不留坏文件）。
    func finish(completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        lock.lock()
        if isFinished {
            lock.unlock()
            Task { @MainActor in
                completion(.failure(RecordingError.notRecording))
            }
            return
        }
        isFinished = true
        let writer = self.writer
        let videoInput = self.videoInput
        let audioInput = self.audioInput
        lock.unlock()

        guard let writer else {
            Task { @MainActor in
                completion(.failure(RecordingError.notRecording))
            }
            return
        }
        // markAsFinished 仅合法于 .writing 态；从未 startWriting 的 writer（未知态）
        // 调它会触发 NSInternalInconsistencyException —— 走显式失败路径。
        if writer.status == .writing {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
        }
        // AVAssetWriter 不 Sendable。依据：finishWriting 的回调由 writer 自己在
        // 串行队列上调用一次，闭包只读 status/error，且 writer 此后不再被写入
        // （markAsFinished 已调用）—— 跨闭包持有没有数据竞争。
        nonisolated(unsafe) let finishingWriter = writer
        finishingWriter.finishWriting { [weak self] in
            let status = finishingWriter.status
            let error = finishingWriter.error
            let url = self?.outputURL
            // ⚠️ 帧数必须在回调内经锁读（P74）：finish 主线程直读会与 videoQueue 的
            // 自增竞争，脏读成 0 时把成功录制误判 .nothingWritten 删文件 —— 真机
            // 「修了池仍然录制无效」的残余根因。回调此刻 isFinished 已挡新帧。
            let writtenFrames = self?.currentAppendedFrameCount() ?? 0
            Self.logger.info("录制收尾 status=\(status.rawValue, privacy: .public) frames=\(writtenFrames, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
            Task { @MainActor in
                if status == .completed, let url, writtenFrames > 0 {
                    completion(.success(url))
                } else {
                    if let url {
                        try? FileManager.default.removeItem(at: url)
                    }
                    // 0 帧完成 ≠ 成功（P60 族：计数必须绑定真出了效果）——不产空文件假成功。
                    completion(.failure(writtenFrames == 0
                        ? RecordingError.nothingWritten
                        : (error ?? RecordingError.writerCreationFailed)))
                }
            }
        }
    }

    /// 取渲染目标缓冲：池（startWriting 后可用，P69）优先并缓存复用；
    /// 池未就绪或耗尽时直配兜底（adaptor 接受外部缓冲，代价是慢一点，不丢帧）。
    private func createBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        if pixelBufferPool == nil {
            pixelBufferPool = adaptor.pixelBufferPool
        }
        if let pool = pixelBufferPool {
            var maybeBuffer: CVPixelBuffer?
            // 本 SDK 桥接为 3 参（auxAttributes 被导入器吞掉，P48）：allocator, pool, &out。
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuffer) == kCVReturnSuccess,
               let buffer = maybeBuffer {
                return buffer
            }
            pixelBufferPool = nil  // 池耗尽/失效：下次重建缓存
        }
        guard bufferWidth > 0, bufferHeight > 0 else { return nil }
        var direct: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: bufferWidth,
            kCVPixelBufferHeightKey: bufferHeight,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, bufferWidth, bufferHeight,
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                                  &direct) == kCVReturnSuccess else {
            return nil
        }
        return direct
    }
}
