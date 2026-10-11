// CameraRecorder — 所见即所得录制（CAM-005，ADR-0014）
//
// 视频：采集帧 → 美颜 → 美型 warp → 滤镜 → 贴纸（开始时锁定的参数）→ CIContext
//       渲染进 CVPixelBufferPool 缓冲 → PixelBufferAdaptor（H.264 / 32BGRA）。
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
// PTS 纪律（对齐 platform-apple.md PALA-012 口径）：会话起点 = 首个视频帧 PTS，
// 早于首帧到达的音频块被丢弃（首帧几乎即时到达，头部截断可忽略且语义诚实）。
//
// 线程模型：appendVideo 只在 videoQueue、appendAudio 只在 audioQueue（由
// CameraManager 回调保证）；start/finish 主线程调用；锁保护状态迁移。

import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
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
    /// 美型参数（CAM-013）：录制开始时锁定（WYSIWYG，与滤镜/美颜同语义）。
    private let reshape: CameraReshapeParams
    /// 美体参数（CAM-025）：录制开始时锁定。
    private let bodyReshape: BodyReshapeParams
    /// 美妆参数（CAM-026）：录制开始时锁定。
    private let makeup: MakeupParams
    /// 贴纸资产（CAM-014）：录制开始时锁定；nil = 无贴纸。
    private let sticker: StickerAsset?
    /// 双摄合成器（CAM-021）：提供时以合成结果为录制源（主+PiP 已按预览同链处理）；
    /// nil = 单摄内联链路（现行路径）。合成闭包强持有 Renderer（录制期生命周期）。
    private let dualComposer: ((CVImageBuffer, CMTime) -> CIImage)?
    /// 人脸框槽（CAM-019）：逐帧读最新值 —— 主体移动时蒙版跟随（WYSIWYG），
    /// 与预览同源（同一 FaceBoxStore，检测队列写 / 本队列读，锁保护）。
    /// CAM-013/014 起锚点（currentAnchors）也经本槽逐帧读取。
    private let faceBoxes: FaceBoxStore?
    private let ciContext: CIContext
    private let withAudio: Bool
    /// 预热/装配串行队列（与 videoQueue 解耦——P115 首录卡顿修复）。
    private let setupQueue = DispatchQueue(label: "com.chuanqi.cut.recorder.setup")
    /// CAM-018：产物 sRGB 标记（渲染后附着的色彩空间，全录制期同一实例）。
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var sessionStarted = false
    /// 会话起点 = 首个视频帧 PTS（startSession 时记录）。音频 append 的 PTS 下界。
    private var sessionStartPTS: CMTime?
    private var isFinished = false
    private var appendFailures = 0

    /// - Parameters:
    ///   - ciContext: 与预览共享的上下文（线程安全）。
    ///   - preset / beauty / reshape: 录制开始时锁定的滤镜、美颜与美型（WYSIWYG；
    ///     录制中面板已锁）。
    ///   - sticker: 录制开始时锁定的贴纸资产；nil = 无（CAM-014）。
    ///   - faceBoxes: 人脸框槽（CAM-019 区域化 + CAM-013/014/025 锚点）；nil = 全部效果
    ///     直通（美颜无算法不生效——不做滤镜式全画面修改；美型/贴纸跳过，兼容测试）。
    ///   - withAudio: 麦克风权限被拒时传 false（录制降级为无声视频，不伪造有声音）。
    init(outputURL: URL, ciContext: CIContext,
         preset: CameraFilterPreset, beauty: CameraBeautyParams,
         reshape: CameraReshapeParams = .off, bodyReshape: BodyReshapeParams = .off,
         makeup: MakeupParams = .off,
         sticker: StickerAsset? = nil,
         dualComposer: ((CVImageBuffer, CMTime) -> CIImage)? = nil,
         faceBoxes: FaceBoxStore? = nil, withAudio: Bool) {
        self.outputURL = outputURL
        self.ciContext = ciContext
        self.preset = preset
        self.beauty = beauty
        self.reshape = reshape
        self.bodyReshape = bodyReshape
        self.makeup = makeup
        self.sticker = sticker
        self.dualComposer = dualComposer
        self.faceBoxes = faceBoxes
        self.withAudio = withAudio
    }

    // MARK: 内部建立（只在 videoQueue 首个视频帧上执行一次）

    /// 建立 writer 与全部轨道。尺寸可预热传入（P115：写码器装配重——writer 创建、
    /// startWriting、编码器 XPC 初始化原先全在**采集回调线程**的首帧上做，做不完
    /// 帧就堵 → 首录预览卡顿；现支持 startRecording 时后台预热，appendVideo 以
    /// 实际帧尺寸对账，不符则重建（罕见路径，诚实降级）。
    private func setupIfNeeded(width: Int, height: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if writer != nil {
            // 已建：尺寸对账（预测 ≠ 实际的罕见路径——拆了重建）。
            if bufferWidth != width || bufferHeight != height {
                Self.logger.warning("录制预热尺寸与实际不符（\(self.bufferWidth, privacy: .public)x\(self.bufferHeight, privacy: .public) → \(width, privacy: .public)x\(height, privacy: .public)），重建 writer")
                writer = nil
                videoInput = nil
                audioInput = nil
                adaptor = nil
                pixelBufferPool = nil
                sessionStarted = false
            } else {
                return true
            }
        }
        if isFinished { return false }


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
                // ⚠️ P112（B-02 真机探针实证）：这里**禁止** kCVImageBufferCGColorSpaceKey
                // —— iOS 26.6 上它让 AVAssetWriter.startWriting 以 -11800
                //（底层 FigXPC -17281）直接失败，writer .failed、录制 0 帧。
                // 隔离复现：adaptor 先建+色键必炸、去键即愈、adaptor 后建即愈。
                // CAM-018 的 sRGB 标记改为渲染后经 CVBufferSetAttachment 附着
                // 在 buffer 上（见 appendVideo，色彩一致性诉求等价）。
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
        // P112：startWriting 的失败此前被静默吞掉（错误被后续 append 的错误覆盖），
        // 案情一直错位到 append 头上——探针在此处即时取证。
        let started = writer.startWriting()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CQ_CAM_PROBE"] != nil {
            let nsError = writer.error as NSError?
            fputs("[cam-probe] startWriting=\(started)"
                  + " status=\(writer.status.rawValue)"
                  + " err=\(nsError?.domain ?? "nil")/\(nsError?.code ?? -1)"
                  + " \(nsError?.localizedDescription ?? "nil")\n", stderr)
            if let nsError, !started {
                for (key, value) in nsError.userInfo {
                    fputs("[cam-probe]   userInfo[\(key)] = \(value)\n", stderr)
                }
                // 对照组：同目录裸写 10B（区分「沙盒不可写」与「writer 管线问题」）。
                let control = outputURL.deletingLastPathComponent()
                    .appendingPathComponent("cq_write_control.txt")
                let writable = (try? Data("probe".utf8).write(to: control)) != nil
                fputs("[cam-probe]   control write=\(writable) url=\(outputURL.path)\n", stderr)
                fflush(stderr)
            }
        }
        #endif
        guard started else { return }
        writer.startSession(atSourceTime: time)
        sessionStarted = true
        sessionStartPTS = time
    }

    // MARK: 帧注入（videoQueue）

    func appendVideo(sourceBuffer: CVImageBuffer, at time: CMTime) {
        guard setupIfNeeded(width: CVPixelBufferGetWidth(sourceBuffer),
                            height: CVPixelBufferGetHeight(sourceBuffer)) else { return }
        lock.lock()
        // writer 状态守卫：只拦「已失败/已收尾」——.failed 之后 append 全部无效
        //（P60 伪绿同族：失败伪装成进度）。⚠️ .unknown（尚未 startWriting）必须
        // 放行：首帧要走到下方 startSessionIfNeeded 才会 startWriting；先查
        // .writing 再 startWriting = 永远到不了 startWriting 的死锁（P108，
        // B-02 真机探针实锤：录制 0 帧 + stop 即 finishWriting 崩溃）。
        guard let adaptor, let videoInput, let writer, !isFinished,
              writer.status == .writing || writer.status == .unknown else {
            lock.unlock()
            return
        }
        lock.unlock()

        // ⚠️ startSession（含 startWriting）必须在取池**之前**（P69：池在
        // startWriting 前是 nil；旧实现池守卫在前 = 每帧必丢死锁）。
        startSessionIfNeeded(at: time)

        // 美颜（人脸区域化，faces 实时读取）→ 美型 warp → 美体 warp → 滤镜 → 贴纸。
        // 与 CameraRenderer.process 同序（顺序锁定，TASK-CAM-013/014/025）。
        // 双摄：合成器已含主+PiP 两路完整链（Renderer 同源），此处直接采用。
        // 引擎缺失/无锚点：对应段跳过（诚实降级）。失败丢帧不崩溃（实时优先）。
        let image: CIImage
        if let dualComposer {
            image = dualComposer(sourceBuffer, time)
        } else {
            var composed = CIImage(cvPixelBuffer: sourceBuffer)
            composed = beauty.apply(to: composed, faces: faceBoxes?.current())
            if let warp = FaceWarp.shared {
                if let anchors = faceBoxes?.currentAnchors() {
                    composed = warp.apply(to: composed, anchors: anchors, params: reshape)
                }
                if let bodyAnchors = faceBoxes?.currentBodyAnchors() {
                    composed = warp.apply(to: composed,
                                          controls: BodyWarpGeometry.controls(from: bodyAnchors,
                                                                              params: bodyReshape))
                }
            }
            if let makeupAnchors = faceBoxes?.currentMakeupAnchors() {
                composed = MakeupRenderer.apply(to: composed, anchors: makeupAnchors,
                                                params: makeup)
            }
            if let filtered = preset.apply(to: composed) {
                composed = filtered
            }
            if let sticker {
                if let anchors = faceBoxes?.currentAnchors() {
                    composed = StickerOverlay.composite(sticker, over: composed, anchors: anchors)
                } else if let animalEyes = faceBoxes?.currentAnimalEyes() {
                    composed = StickerOverlay.composite(sticker, over: composed, eyeAnchor: animalEyes)
                }
            }
            image = composed
        }
        guard let pixelBuffer = createBuffer(from: adaptor) else {
            return  // 池与直配都失败：丢帧（同采集侧 latest-wins 语义）
        }
        // render(toCVPixelBuffer:) 非 throws（P48）；CI 内部失败不会抛出到此层。
        ciContext.render(image, to: pixelBuffer)
        // CAM-018 色彩一致性：sRGB 标记附着在 buffer 上（原放在 adaptor 源属性，
        // P112 实证毒化 startWriting——附件方式等价且安全）。
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey,
                              sRGBColorSpace, CVAttachmentMode.shouldPropagate)

        #if DEBUG
        if ProcessInfo.processInfo.environment["CQ_CAM_PROBE"] != nil {
            let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let chars = [UInt8((fmt >> 24) & 0xFF), UInt8((fmt >> 16) & 0xFF),
                         UInt8((fmt >> 8) & 0xFF), UInt8(fmt & 0xFF)]
            var fourcc = ""
            for ch in chars { fourcc.append(Character(UnicodeScalar(ch))) }
            let dims = "\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
            let pts = CMTimeGetSeconds(time)
            let hasPool = adaptor.pixelBufferPool != nil
            fputs("[cam-probe] append dims=\(dims) fmt=\(fourcc) pts=\(pts)"
                  + " pool=\(hasPool) ready=\(videoInput.isReadyForMoreMediaData)\n", stderr)
            fflush(stderr)
        }
        #endif
        guard videoInput.isReadyForMoreMediaData else { return }
        // append 返回值必须检查：失败帧不计入进度（旧实现无条件计数 = 失败伪装成
        // 正常写入），原因按 30 次节流落日志（P60：静默失败不能复现）。
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            let total = recordAppendedFrame()
            if total % 240 == 0 {
                Self.logger.info("录制已写入 \(total, privacy: .public) 帧")
            }
        } else {
            let failures = recordAppendFailure()
            if failures % 30 == 1 {
                lock.lock()
                let writerError = writer.error
                lock.unlock()
                #if DEBUG
                if ProcessInfo.processInfo.environment["CQ_CAM_PROBE"] != nil {
                    let nsError = writerError as NSError?
                    let domain = nsError?.domain ?? "nil"
                    let code = nsError?.code ?? -1
                    let desc = writerError?.localizedDescription ?? "nil"
                    let underlying = nsError?.userInfo[NSUnderlyingErrorKey] ?? "nil"
                    fputs("[cam-probe] append FAIL #\(failures) domain=\(domain)"
                          + " code=\(code) desc=\(desc) underlying=\(underlying)"
                          + " writerStatus=\(writer.status.rawValue)\n", stderr)
                    fflush(stderr)
                }
                #endif
                Self.logger.error("视频帧 append 失败 #\(failures, privacy: .public)：\(writerError?.localizedDescription ?? "未知", privacy: .public)")
            }
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

    /// append 失败计数（锁内自增；节流日志用，视频/音频共用）。
    private func recordAppendFailure() -> Int {
        lock.lock()
        appendFailures += 1
        let total = appendFailures
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
        // ⚠️ 会话起点守卫（2026-10-07 真机「assetwriter 报错」根因修复）：
        // startSession 在**首个视频帧**（videoQueue）执行，而音频在会话 startRunning
        // 后立即流入（audioQueue）—— 早于 startWriting/startSession 的音频 buffer、
        // 或 PTS 早于会话起点的音频 buffer，都会让 AVAssetWriter 直接进 .failed
        // （不可恢复：之后所有 append 失败，收尾报错）。文件头此前声称「早于首帧的
        // 音频块被丢弃」，但旧实现没有守卫 —— 注释与实现不符，本次补齐。
        lock.lock()
        guard let audioInput, let writer, !isFinished, sessionStarted,
              writer.status == .writing else {
            lock.unlock()
            return  // writer 未建立/未起会话 = 头部丢弃，语义见文件头
        }
        let startPTS = sessionStartPTS
        lock.unlock()

        // PTS 早于会话起点：丢弃（音频起点几乎必然早于首个视频帧的呈现时间）。
        if let startPTS,
           CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), startPTS) < 0 {
            return
        }

        guard audioInput.isReadyForMoreMediaData else { return }
        if !audioInput.append(sampleBuffer) {
            let failures = recordAppendFailure()
            if failures % 30 == 1 {
                lock.lock()
                let writerError = writer.error
                lock.unlock()
                #if DEBUG
                if ProcessInfo.processInfo.environment["CQ_CAM_PROBE"] != nil {
                    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    let nsError = writerError as NSError?
                    let domain = nsError?.domain ?? "nil"
                    let code = nsError?.code ?? -1
                    let desc = writerError?.localizedDescription ?? "nil"
                    var rate: Double = 0
                    var channels: UInt32 = 0
                    if let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) {
                        rate = asbd.pointee.mSampleRate
                        channels = asbd.pointee.mChannelsPerFrame
                    }
                    fputs("[cam-probe] audio FAIL #\(failures) domain=\(domain)"
                          + " code=\(code) desc=\(desc) pts=\(pts)"
                          + " rate=\(rate) ch=\(channels)\n", stderr)
                    fflush(stderr)
                }
                #endif
                Self.logger.error("音频帧 append 失败 #\(failures, privacy: .public)：\(writerError?.localizedDescription ?? "未知", privacy: .public)")
            }
        }
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
        // markAsFinished / finishWriting 均仅合法于 .writing 态；从未 startWriting
        // 的 writer（状态 0）调 finishWriting 会抛 NSInternalInconsistencyException
        //（P108 真机实锤：0 帧录制 stop 即崩）—— 走显式失败路径，不碰 writer。
        guard writer.status == .writing else {
            let err = writer.error ?? RecordingError.nothingWritten
            Self.logger.error("录制收尾：writer 状态 \(writer.status.rawValue, privacy: .public)（未进入 writing），按失败收尾")
            Task { @MainActor in
                completion(.failure(err))
            }
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        // AVAssetWriter 不 Sendable。依据：finishWriting 的回调由 writer 自己在
        // 串行队列上调用一次，闭包只读 status/error，且 writer 此后不再被写入
        // （markAsFinished 已调用）—— 跨闭包持有没有数据竞争。
        nonisolated(unsafe) let finishingWriter = writer
        // ⚠️ P114（B-02 真机实锤）：完成回调必须**强持有 self**——stopRecording
        // 先 recorderBox.set(nil) 再 finish，弱引用下 recorder 在回调执行前析构，
        // currentAppendedFrameCount() 读出 0 → 把 status=.completed 的成功录制
        // 误判 nothingWritten → 删文件 + 报「没有录制到任何画面」。
        // 竞态 = 回调与析构赛跑（间歇性：探针赢过、用户手点输过）。
        // 无保留环：writer 的完成回调一次性执行后即释放。
        finishingWriter.finishWriting { [self] in
            let status = finishingWriter.status
            let error = finishingWriter.error
            let url = self.outputURL
            // 帧数必须在回调内经锁读（P74）：finish 主线程直读会与 videoQueue 的
            // 自增竞争。回调此刻 isFinished 已挡新帧，锁读为终值。
            let writtenFrames = self.currentAppendedFrameCount()
            #if DEBUG
            fputs("[cam-probe] finish status=\(status.rawValue) frames=\(writtenFrames)"
                  + " err=\(error?.localizedDescription ?? "nil")\n", stderr)
            fflush(stderr)
            #endif
            Self.logger.info("录制收尾 status=\(status.rawValue, privacy: .public) frames=\(writtenFrames, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
            Task { @MainActor in
                if status == .completed, writtenFrames > 0 {
                    completion(.success(url))
                } else {
                    try? FileManager.default.removeItem(at: url)
                    // 0 帧完成 ≠ 成功（P60 族：计数必须绑定真出了效果）——不产空文件假成功。
                    completion(.failure(writtenFrames == 0
                        ? RecordingError.nothingWritten
                        : (error ?? RecordingError.writerCreationFailed)))
                }
            }
        }
    }

    /// 录制预热（P115）：startRecording 时在后台队列预建 writer/轨道/adaptor，
    /// 首帧到达即只做 startWriting + append——采集回调线程不再被装配堵住
    ///（首录预览卡顿的真因）。尺寸 = 预测值（竖屏 UI 下前后摄均交付竖向帧）。
    func warmup(width: Int, height: Int) {
        setupQueue.async { [weak self] in
            _ = self?.setupIfNeeded(width: width, height: height)
            Self.logger.info("录制预热 \(width, privacy: .public)x\(height, privacy: .public)")
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
        // ⚠️ IOSurface 背板必带（P112）：硬编管线（VideoToolbox/Fig）只吃
        // IOSurface-backed buffer——直配缺这个键时 append 以 AVFoundation -11800
        //（底层 FigXPC -17281）拒收，writer 进入 .failed 不可恢复（B-02 真机实证：
        // pool 未就绪的首帧全部走本路径，录制 0 帧全案真因）。
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: bufferWidth,
            kCVPixelBufferHeightKey: bufferHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, bufferWidth, bufferHeight,
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                                  &direct) == kCVReturnSuccess else {
            return nil
        }
        return direct
    }
}
