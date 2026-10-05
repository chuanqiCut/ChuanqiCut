// CameraManager — 相机采集编排（CAM-002，ADR-0014：iOS 原生，不经 PAL/C ABI）
//
// 线程模型（扬长避短前提下仍守红线 #8「主线程零阻塞」）：
//   - 会话配置/启停全部在 sessionQueue 串行执行（AVFoundation 的经典约束：
//     MultiCamSession 甚至要求停止态才能改配置，单摄也照此纪律）。
//   - 帧回调在 videoQueue / audioQueue 专用串行队列，latest-wins
//     （alwaysDiscardsLateVideoFrames + 丢帧不排队），不做任何主线程跳转 ——
//     消费方（帧槽 / 录制器）自己决定如何跨线程。
//   - 可变状态（currentPosition 等）只在 sessionQueue 触碰；UI 经
//     CameraViewModel 的 @Published 镜像，不直接读本类状态。
//
// 双摄（AVCaptureMultiCamSession）按 SPEC-CAM-001 v1.1 归 CAM-021，本类留接口不实现：
// isMultiCamSupported 运行时查询（pitfalls P38：该类仅 iOS）。
//
// @unchecked Sendable：可变状态的线程安全由上面的队列独占纪律担保（sessionQueue
// 串行 + 帧回调闭包在会话启动前接线）；Swift 6 严格并发下 DispatchQueue.async
// 的 @Sendable 闭包捕获 self 依赖该声明（P49）。

import AVFoundation
import CoreMedia

final class CameraManager: NSObject, @unchecked Sendable {

    enum Position {
        case back
        case front
    }

    // MARK: 帧消费口（采集队列回调；调用方必须在会话运行前挂好）

    /// 视频帧（videoQueue 回调）。buffer 仅本次回调内有效，需持久消费须自行 retain
    /// （CVImageBuffer 是 CF 对象，Swift 赋值即 retain）。
    var onVideoFrame: ((CVImageBuffer, CMTime) -> Void)?
    /// 音频 sampleBuffer（audioQueue 回调）。录制路径直接 append 给 AVAssetWriterInput。
    var onAudioBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: 会话与队列

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cq.camera.session")
    private let videoQueue = DispatchQueue(label: "cq.camera.video")
    private let audioQueue = DispatchQueue(label: "cq.camera.audio")
    private let relay = FrameRelay()
    private let photoRelay = PhotoRelay()
    private let photoOutput = AVCapturePhotoOutput()

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private(set) var currentPosition: Position = .back
    private var configured = false

    override init() {
        super.init()
        relay.onVideo = { [weak self] sampleBuffer in
            guard let self,
                  let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            self.onVideoFrame?(buffer, pts)
        }
        relay.onAudio = { [weak self] sampleBuffer in
            self?.onAudioBuffer?(sampleBuffer)
        }
    }

    // MARK: 权限（主线程入口）

    /// 相机+麦克风授权。拒绝相机 = false；拒绝麦克风仍可拍（录制时静音轨降级）。
    static func requestAuthorization(_ completion: @escaping @MainActor (_ cameraGranted: Bool, _ micGranted: Bool) -> Void) {
        func request(_ mediaType: AVMediaType, _ done: @escaping (Bool) -> Void) {
            switch AVCaptureDevice.authorizationStatus(for: mediaType) {
            case .authorized:
                done(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: mediaType, completionHandler: done)
            default:
                done(false)
            }
        }
        request(.video) { camera in
            request(.audio) { mic in
                Task { @MainActor in
                    completion(camera, mic)
                }
            }
        }
    }

    // MARK: 会话生命周期（全部内部 sessionQueue）

    /// 配置并启动（幂等）。完成后主线程回调 isRunning。
    func configureAndStart(onReady: @escaping @MainActor (_ isRunning: Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.configureLocked(position: self.currentPosition)
                self.configured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            let running = self.session.isRunning
            Task { @MainActor in
                onReady(running)
            }
        }
    }

    /// 前后切换。配置变更在 sessionQueue 串行执行；切换结果主线程回调。
    func switchPosition(to position: Position, onDone: @escaping @MainActor (_ position: Position) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.configured else { return }
            self.currentPosition = position
            self.reconfigureVideoInputLocked(position: position)
            Task { @MainActor in
                onDone(position)
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    // MARK: 拍照（CAM-003 追加）

    /// 拍一张静态照片。完成回调带回**未处理的**原始像素缓冲（美颜/滤镜由上层
    /// 统一走 process 链，保证与预览同序），错误/失败以 nil 上抛（诚实暴露）。
    /// 可在视频录制中调用（AVFoundation 支持拍录并发）。
    func capturePhoto(onDone: @escaping (_ pixelBuffer: CVImageBuffer?) -> Void) {
        // onDone 保持非 @Sendable（调用方在闭包内做整帧处理，隔离随调用方）；
        // 经 PhotoRelay（@unchecked Sendable）转交——@Sendable 的 async 闭包只捕获
        // relay，不捕获 onDone 本体（P49）。失败路径（设备缺失/未配置）同样回调 nil。
        let relay = photoRelay
        relay.onPhoto = onDone
        sessionQueue.async { [weak self] in
            guard let self, self.configured, self.session.outputs.contains(self.photoOutput) else {
                relay.deliver(nil)
                return
            }
            let settings = AVCapturePhotoSettings()
            // 竖屏/镜像沿用 connection 的呈现设置（photoOutput 的 connection 一并设置）。
            if let connection = self.photoOutput.connection(with: .video) {
                self.applyPortraitOrientation(connection)
                if self.currentPosition == .front && connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self.photoRelay)
        }
    }

    // MARK: 内部配置（必须在 sessionQueue 上调用）

    private func configureLocked(position: Position) {
        session.beginConfiguration()
        session.sessionPreset = .high  // ≈1080p；实际分辨率以 activeFormat 为准（不猜）
        defer { session.commitConfiguration() }

        // 视频输出：32BGRA（与零拷贝链路同口径）+ 丢帧保实时。
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(relay, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        // 竖屏 + 前摄镜像约定由 connection 如实设置（UI 不再猜方向）。
        if let connection = videoOutput.connection(with: .video) {
            applyPortraitOrientation(connection)
            if position == .front && connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }

        // 音频输出（可选：麦克风被拒时跳过，录制降级为无声视频）。
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(relay, queue: audioQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }

        // 静态拍照输出（CAM-003 追加：拍照模式）。加输出需在 commitConfiguration 前。
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        reconfigureVideoInputLocked(position: position)
    }

    private func reconfigureVideoInputLocked(position: Position) {
        if let old = videoInput {
            session.removeInput(old)
            videoInput = nil
        }
        let deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
        let avPosition: AVCaptureDevice.Position = (position == .front) ? .front : .back
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: avPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return  // 设备缺失/被占用：主线程回调侧以 isRunning 判断，不伪造成功
        }
        session.addInput(input)
        videoInput = input
        // 新 input 生效后 connection 需重设方向/镜像（addInput 会重建 connection）。
        for output in session.outputs {
            guard let connection = output.connection(with: .video) else { continue }
            applyPortraitOrientation(connection)
            if position == .front && connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
    }

    /// 竖屏旋转：iOS 17+ 用 videoRotationAngle（旧 API 已弃用），16 走旧 API。
    /// 支持性检查必须各走各的分支：isVideoRotationAngleSupported 本身是 iOS 17+ API，
    /// 不能放在门控之前统一判断（编译错 + iOS 16 真机 unrecognized selector 崩溃）。
    private func applyPortraitOrientation(_ connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}

// MARK: - 帧中继（delegate 回调在采集队列；不持有 session）

/// AVCapture 委托回调落在采集队列，不能放进 @MainActor 类型；这个小中继只做
/// 「sampleBuffer → 闭包」的转发，闭包由 CameraManager 注入（弱引用 manager）。
private final class FrameRelay: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    var onVideo: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            onVideo?(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput {
            onAudio?(sampleBuffer)
        }
    }
}

// MARK: - 拍照中继（AVCapturePhotoCaptureDelegate 回调在系统队列）

private final class PhotoRelay: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    var onPhoto: ((_ pixelBuffer: CVImageBuffer?) -> Void)?

    /// 派发一次性拍照回调并清空（拍照单发，不重复触发）。
    func deliver(_ buffer: CVImageBuffer?) {
        let callback = onPhoto
        onPhoto = nil
        callback?(buffer)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let buffer = photo.pixelBuffer else {
            deliver(nil)
            return
        }
        deliver(buffer)
    }
}
