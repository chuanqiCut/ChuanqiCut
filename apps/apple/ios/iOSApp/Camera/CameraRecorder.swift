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
// PTS 纪律（对齐 pal-apple.md PALA-012 口径）：会话起点 = 首个视频帧 PTS，
// 早于首帧到达的音频块被丢弃（首帧几乎即时到达，头部截断可忽略且语义诚实）。
//
// 线程模型：appendVideo 只在 videoQueue、appendAudio 只在 audioQueue（由
// CameraManager 回调保证）；start/finish 主线程调用；锁保护状态迁移。

import AVFoundation
import CoreImage
import Foundation
import SharedUI

final class CameraRecorder {

    enum RecordingError: Error, LocalizedError {
        case writerCreationFailed
        case notRecording
        case alreadyRecording

        var errorDescription: String? {
            switch self {
            case .writerCreationFailed: return "AVAssetWriter 创建失败"
            case .notRecording: return "没有进行中的录制"
            case .alreadyRecording: return "录制已在进行"
            }
        }
    }

    private(set) var outputURL: URL

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferPool: CVPixelBufferPool?

    private let preset: CameraFilterPreset
    private let ciContext: CIContext
    private let withAudio: Bool
    private let lock = NSLock()
    private var sessionStarted = false
    private var isFinished = false

    /// - Parameters:
    ///   - ciContext: 与预览共享的上下文（线程安全）。
    ///   - preset: 录制开始时锁定的滤镜（录制中不换滤镜，TASK-CAM-004 的简化决策）。
    ///   - withAudio: 麦克风权限被拒时传 false（录制降级为无声视频，不伪造有声音）。
    init(outputURL: URL, ciContext: CIContext, preset: CameraFilterPreset, withAudio: Bool) {
        self.outputURL = outputURL
        self.ciContext = ciContext
        self.preset = preset
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
            sourceBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
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
        self.pixelBufferPool = adaptor.pixelBufferPool  // 预热池（逐帧 8MB 分配不可接受）
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

        // 滤镜（开始时锁定）→ 渲染进池缓冲。渲染失败丢帧不崩溃（实时优先）。
        var image = CIImage(cvPixelBuffer: sourceBuffer)
        if let filtered = preset.apply(to: image) {
            image = filtered
        }
        guard let pool = pixelBufferPool, let pixelBuffer = createBuffer(from: pool) else {
            return  // 池耗尽：丢帧（同采集侧 latest-wins 语义）
        }
        do {
            try ciContext.render(image, to: pixelBuffer)
        } catch {
            return
        }

        startSessionIfNeeded(at: time)
        guard videoInput.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: time)
        // pixelBuffer 由 ARC 释放回池（append 内部按需 retain）。
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
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            let status = writer.status
            let error = writer.error
            let url = self?.outputURL
            Task { @MainActor in
                if status == .completed, let url {
                    completion(.success(url))
                } else {
                    if let url {
                        try? FileManager.default.removeItem(at: url)
                    }
                    completion(.failure(error ?? RecordingError.writerCreationFailed))
                }
            }
        }
    }

    private func createBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreateBuffer(kCFAllocatorDefault, pool, nil, &maybeBuffer)
        return maybeBuffer
    }
}
