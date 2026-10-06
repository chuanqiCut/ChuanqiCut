// CameraManager — 相机采集编排（CAM-002，ADR-0014：iOS 原生，不经 PAL/C ABI）
//
// 线程模型（扬长避短前提下仍守红线 #8「主线程零阻塞」）：
//   - 会话配置/启停全部在 sessionQueue 串行执行（AVFoundation 的经典约束：
//     MultiCamSession 甚至要求停止态才能改配置，单摄也照此纪律）。
//   - 帧回调在 videoQueue / audioQueue 专用串行队列，latest-wins
//     （alwaysDiscardsLateVideoFrames + 丢帧不排队），不做任何主线程跳转 ——
//     消费方（帧槽 / 录制器）自己决定如何跨线程。
//   - 可变状态（currentPosition / interfaceOrientation 等）只在 sessionQueue 触碰；
//     UI 经 CameraViewModel 的 @Published 镜像，不直接读本类状态。
//
// 方向（SPEC-CAM-001 v1.2 目标5）：采集方向跟随界面方向（竖 + 左右横屏），
// 由 CameraView 监听 UIWindowScene.interfaceOrientationDidChangeNotification 后
// 经 setInterfaceOrientation 注入；渲染端 aspect-fill 见 CameraRenderer。
//
// 双摄（AVCaptureMultiCamSession）按 SPEC-CAM-001 v1.1 归 CAM-021，本类留接口不实现：
// isMultiCamSupported 运行时查询（pitfalls P38：该类仅 iOS）。
//
// @unchecked Sendable：可变状态的线程安全由上面的队列独占纪律担保（sessionQueue
// 串行 + 帧回调闭包在会话启动前接线）；Swift 6 严格并发下 DispatchQueue.async
// 的 @Sendable 闭包捕获 self 依赖该声明（P49）。

import AVFoundation
import CoreMedia
import UIKit
import os

// @unchecked Sendable 的依据（不是静音警告，是已建立的线程模型）：
//   可变状态（configured / currentPosition）**只在 sessionQueue** 触碰，
//   session / photoOutput 是 let 且创建后不再改；跨队列只传不可变的 Bool /
//   Position / 帧缓冲。故本类实例跨队列传递是安全的。
final class CameraManager: NSObject, @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.chuanqi.cut", category: "camera.session")

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
    /// 界面方向镜像（只在 sessionQueue 读写）。初始竖屏；configure 前收到设置也先存，
    /// configureLocked 会取用（避免「先旋转后启动」丢方向）。
    private(set) var interfaceOrientation: UIInterfaceOrientation = .portrait
    private var configured = false

    // MARK: 逐传感器方向标定（CAM-017，iOS 17+）
    //
    // 前后摄传感器原生朝向不同 ⇒ 静态角度表（按背摄推导）对前摄失效——真机实证：
    // 前摄竖屏出横躺画面。官方解法 = RotationCoordinator 给「本设备本镜头」的
    // 正确角度；在「设备位姿 = 界面方向」（无系统旋转锁、位姿有效）时采样一次，
    // 折算成对静态表的**常量偏移**叠加。偏移只在换 position 时重标。
    /// iOS 17+ RotationCoordinator（存 AnyObject 规避存储属性的可用性标注限制，
    /// 用点在 #available 内 cast）。
    private var rotationCoordinator: AnyObject?
    /// 传感器安装偏移（coordinator 角度 − 静态表角度），90° 栅格值。sessionQueue 专属。
    private var sensorAngleOffset: CGFloat = 0
    /// 设备位姿。iOS 26 SDK 起 UIDevice 是 @MainActor 隔离（P71），sessionQueue
    /// 不能直接读 —— 由主线程入口（configureAndStart / switchPosition）显式传入。
    private var devicePose: UIDeviceOrientation = .unknown

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
        // done 只在 Bool 上传递（Sendable），且 requestAccess 的 completionHandler
        // 是 @Sendable —— 这里显式标注，避免外层闭包被推断成非 Sendable。
        @Sendable func request(_ mediaType: AVMediaType, _ done: @escaping @Sendable (Bool) -> Void) {
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
    /// - Parameter devicePose: 调用瞬间（主线程）的设备位姿，供方向标定用。
    func configureAndStart(devicePose: UIDeviceOrientation,
                           onReady: @escaping @MainActor (_ isRunning: Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.devicePose = devicePose
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
    /// - Parameter devicePose: 调用瞬间（主线程）的设备位姿，供方向标定用。
    func switchPosition(to position: Position,
                        devicePose: UIDeviceOrientation,
                        onDone: @escaping @MainActor (_ position: Position) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.configured else { return }
            self.devicePose = devicePose
            self.currentPosition = position
            self.reconfigureVideoInputLocked(position: position)
            Task { @MainActor in
                onDone(position)
            }
        }
    }

    /// 界面方向变化入口（主线程调用；SPEC-CAM-001 v1.2 目标5）。
    /// 会话未配置时只存值（configureLocked 会取用），已配置则即时重设所有
    /// video connection 的旋转/镜像。录制中由调用方（ViewModel）门控。
    func setInterfaceOrientation(_ io: UIInterfaceOrientation) {
        sessionQueue.async { [weak self] in
            guard let self, self.interfaceOrientation != io else { return }
            self.interfaceOrientation = io
            guard self.configured else { return }
            for output in self.session.outputs {
                guard let connection = output.connection(with: .video) else { continue }
                self.applyOrientation(connection, io)
                self.applyMirrorIfFront(connection)
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
        // onDone 的签名含 CVImageBuffer（CF 类型，不 Sendable），保持非 @Sendable，
        // 经 PhotoRelay（@unchecked Sendable）转交——@Sendable 的 async 闭包只捕获
        // relay，不捕获 onDone 本体（P49）。失败路径（设备缺失/未配置）同样回调 nil。
        // 跨线程安全性依据：闭包**强捕获** buffer，CVPixelBuffer 引用计数不会被
        // 池回收；消费方（CameraViewModel）只读渲染。
        let relay = photoRelay
        relay.onPhoto = onDone
        sessionQueue.async { [weak self] in
            guard let self, self.configured, self.session.outputs.contains(self.photoOutput) else {
                // 遥测（CAM-017）：「拍照无效」定位口 —— 输出没挂上/会话未配置在此现形。
                Self.logger.error("拍照中止 configured=\(self?.configured ?? false, privacy: .public) photoOutputInSession=\(self.map { $0.session.outputs.contains($0.photoOutput) } ?? false, privacy: .public)")
                relay.deliver(nil)
                return
            }
            let settings = AVCapturePhotoSettings()
            // 方向/镜像沿用 connection 的呈现设置（按当前界面方向，CAM-016）。
            if let connection = self.photoOutput.connection(with: .video) {
                self.applyOrientation(connection, self.interfaceOrientation)
                self.applyMirrorIfFront(connection)
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
        // 方向 + 前摄镜像约定由 connection 如实设置（跟随界面方向，CAM-016）。
        if let connection = videoOutput.connection(with: .video) {
            applyOrientation(connection, interfaceOrientation)
            applyMirrorIfFront(connection)
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
        // 逐传感器标定（iOS 17+）：换镜头即重标，先归零防串位。
        sensorAngleOffset = 0
        if #available(iOS 17.0, *) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotationCoordinator = coordinator
            let pose = devicePose
            if let poseInterface = Self.interfaceOrientation(fromDevicePose: pose),
               poseInterface == interfaceOrientation {
                let horizon = coordinator.videoRotationAngleForHorizonLevelPreview
                sensorAngleOffset = Self.snappedToQuarter(horizon - Self.rotationAngle(for: poseInterface))
                Self.logger.info("方向标定 pos=\(position == .front ? "front" : "back", privacy: .public) horizon=\(horizon, privacy: .public) offset=\(self.sensorAngleOffset, privacy: .public)")
            } else {
                Self.logger.info("方向标定跳过（位姿 \(pose.rawValue, privacy: .public) ≠ 界面方向）沿用静态表")
            }
        }
        // 新 input 生效后 connection 需重设方向/镜像（addInput 会重建 connection）。
        for output in session.outputs {
            guard let connection = output.connection(with: .video) else { continue }
            applyOrientation(connection, interfaceOrientation)
            applyMirrorIfFront(connection)
        }
    }

    /// 方向旋转：iOS 17+ 用 videoRotationAngle（旧 API 已弃用），16 走旧 API。
    /// 支持性检查必须各走各的分支：isVideoRotationAngleSupported 本身是 iOS 17+ API，
    /// 不能放在门控之前统一判断（编译错 + iOS 16 真机 unrecognized selector 崩溃）。
    ///
    /// 角度映射依据（CAM-016）：传感器原生位 = 机身横置 home 在右 =
    /// UIInterfaceOrientationLandscapeLeft（Apple 对该枚举的定义即「home 在右」），
    /// 故 landscapeLeft=0、landscapeRight=180、portrait=90。
    /// ⚠️ 横屏两项是文档推导，真机若出现横屏 180° 反接，交换 0/180（一行）。
    private func applyOrientation(_ connection: AVCaptureConnection, _ io: UIInterfaceOrientation) {
        if #available(iOS 17.0, *) {
            // 静态表 + 逐传感器偏移（CAM-017），snap 到 90° 栅格。
            let angle = Self.snappedToQuarter(Self.rotationAngle(for: io) + sensorAngleOffset)
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else if connection.isVideoOrientationSupported, let vo = Self.videoOrientation(for: io) {
            connection.videoOrientation = vo
        }
    }

    /// 前摄镜像（旋转之后应用，Apple 语义；各界面方向保持自拍镜像惯例）。
    private func applyMirrorIfFront(_ connection: AVCaptureConnection) {
        if currentPosition == .front && connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
    }

    /// 界面方向 → videoRotationAngle（iOS 17+）。
    /// 依据（SDK 头文件 UIOrientation.h 原文）：
    /// `UIInterfaceOrientationLandscapeLeft = UIDeviceOrientationLandscapeRight`，
    /// 且 AVCaptureVideoOrientationLandscapeRight 注释 =「home button on the right」
    /// —— 即 UI 的 landscapeLeft 位姿 = home 在右 = **传感器原生位**，故 0°；
    /// UI 的 landscapeRight = home 在左 = 180°。
    /// ⚠️ 横屏两项仍是文档推导链，真机若 180° 反接：交换 0/180（一行）。
    static func rotationAngle(for io: UIInterfaceOrientation) -> CGFloat {
        switch io {
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    /// 设备位姿 → 界面方向。**landscape 名互换**（UIOrientation.h：UI.L = Device.R，
    /// P67）；faceUp/faceDown/unknown 无对应界面方向。
    static func interfaceOrientation(fromDevicePose pose: UIDeviceOrientation) -> UIInterfaceOrientation? {
        switch pose {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }

    /// 角度 snap 到 0/90/180/270 栅格（coordinator 角度理论上为 90 的倍数，防御取整）。
    static func snappedToQuarter(_ angle: CGFloat) -> CGFloat {
        let snapped = (angle / 90).rounded() * 90
        let normalized = snapped.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }

    /// 界面方向 → 旧版 videoOrientation（iOS 16 fallback）。
    /// ⚠️ **UI 与 AVCapture 的 landscape 命名互换**（不是同名直映！）：
    /// AVCaptureVideoOrientationLandscapeRight = home 在右 = UIInterfaceOrientationLandscapeLeft。
    /// 未知方向返回 nil = 保持现状。
    static func videoOrientation(for io: UIInterfaceOrientation) -> AVCaptureVideoOrientation? {
        switch io {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return nil
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

    private static let logger = Logger(subsystem: "com.chuanqi.cut", category: "camera.photo")

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
            // 遥测（CAM-017）：失败原因直接可见，不靠 UI 层猜。
            Self.logger.error("拍照回调失败：\(error?.localizedDescription ?? "pixelBuffer 缺失", privacy: .public)")
            deliver(nil)
            return
        }
        deliver(buffer)
    }
}
