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

import AVFoundation
import CoreMedia

final class CameraManager: NSObject {

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
            guard let videoOutput = output as? AVCaptureVideoDataOutput,
                  let connection = videoOutput.connection(with: .video) else { continue }
            applyPortraitOrientation(connection)
            if position == .front && connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
    }

    /// 竖屏旋转：iOS 17+ 用 videoRotationAngle（旧 API 已弃用），16 走旧 API。
    private func applyPortraitOrientation(_ connection: AVCaptureConnection) {
        guard connection.isVideoRotationAngleSupported(90) || connection.isVideoOrientationSupported else {
            return
        }
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
