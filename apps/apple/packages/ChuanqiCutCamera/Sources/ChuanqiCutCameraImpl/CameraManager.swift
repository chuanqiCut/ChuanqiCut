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

    /// 采集分辨率档位（2026-10-07 用户反馈轮）：预览与录制共用同一 sessionPreset
    /// （同一条采集流，所见即所得）。4K 档位依赖机型支持，canSetSessionPreset
    /// 不过 = 保持原档位并如实回调失败。
    enum CaptureQuality: String, CaseIterable {
        case hd720
        case hd1080
        case uhd4K

        var preset: AVCaptureSession.Preset {
            switch self {
            case .hd720: return .hd1280x720
            case .hd1080: return .hd1920x1080
            case .uhd4K: return .hd4K3840x2160
            }
        }
    }

    // MARK: 帧消费口（采集队列回调；调用方必须在会话运行前挂好）

    /// 视频帧（videoQueue 回调）。buffer 仅本次回调内有效，需持久消费须自行 retain
    /// （CVImageBuffer 是 CF 对象，Swift 赋值即 retain）。
    var onVideoFrame: ((CVImageBuffer, CMTime) -> Void)?
    /// 音频 sampleBuffer（audioQueue 回调）。录制路径直接 append 给 AVAssetWriterInput。
    var onAudioBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: 会话与队列

    /// 双摄机型（A12+）用 MultiCamSession；其余机型退回普通 Session（单摄行为不变）。
    private static func makeSession() -> AVCaptureSession {
        AVCaptureMultiCamSession.isMultiCamSupported ? AVCaptureMultiCamSession() : AVCaptureSession()
    }

    /// 设备级双摄支持（CAM-021：UI 依此置灰开关，SPEC A8 不支持机型诚实降级）。
    static var isMultiCamSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    let session: AVCaptureSession = CameraManager.makeSession()
    private let sessionQueue = DispatchQueue(label: "cq.camera.session")
    private let videoQueue = DispatchQueue(label: "cq.camera.video")
    private let audioQueue = DispatchQueue(label: "cq.camera.audio")
    private let relay = FrameRelay()
    private let photoRelay = PhotoRelay()
    private let photoOutput = AVCapturePhotoOutput()
    /// 后摄（主画面）视频输出。
    private let videoOutput = AVCaptureVideoDataOutput()
    /// 前摄（PiP）视频输出（CAM-021：仅双摄模式挂会话，无连接 = 无帧）。
    private let frontVideoOutput = AVCaptureVideoDataOutput()
    private let frontQueue = DispatchQueue(label: "cq.camera.video.front")
    private let frontRelay = FrameRelay()

    private var videoInput: AVCaptureDeviceInput?
    private var frontVideoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private(set) var currentPosition: Position = .back
    /// 双摄模式（sessionQueue 独占；开关经 setDualCamEnabled）。
    private(set) var dualCamEnabled = false
    /// 前摄帧（仅双摄模式有流；回调在 frontQueue，消费契约同 onVideoFrame）。
    var onFrontVideoFrame: ((CVImageBuffer, CMTime) -> Void)?
    /// 采集档位/帧率（只在 sessionQueue 读写；configure/重配时取用并重放）。
    private(set) var captureQuality: CaptureQuality = .hd1080
    private(set) var frameRate: Int = 30
    /// 变焦（只在 sessionQueue 读写；切摄重置为 1.0——新镜头从广角起）。
    private(set) var zoomFactor: CGFloat = 1.0
    /// 界面方向镜像（只在 sessionQueue 读写）。初始竖屏；configure 前收到设置也先存，
    /// configureLocked 会取用（避免「先旋转后启动」丢方向）。
    private(set) var interfaceOrientation: UIInterfaceOrientation = .portrait
    private var configured = false

    // MARK: 前摄安装朝向补偿（CAM-017 二修，pitfalls P72）
    //
    // videoRotationAngle 的 0° = **传感器 native 方向**（iPhone 横装，前后摄安装
    // 轴向相反）⇒ 后摄竖屏 90° 正确时前摄需 0°（真机两代现象反推：CAM-016 静态表
    // 后摄三方向正确 / 前摄竖屏横躺 = 恰差 270°）。
    // 曾试 RotationCoordinator 采样安装偏移 —— 新建即读 `videoRotationAngle-
    // ForHorizonLevelPreview` 拿到的是**未初始化的 0**（该值依赖传感器数据、KVO
    // 异步生效），后摄 90° 被偏到 0° 反向横躺（真机回归）。常量方案无时序依赖；
    // 例外机型出现时（无证据）再上 KVO 方案。

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
        frontRelay.onVideo = { [weak self] sampleBuffer in
            guard let self,
                  let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            self.onFrontVideoFrame?(buffer, pts)
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
    /// 双摄模式下禁用（SPEC v1.2：翻转按钮永远只做单摄切换；双摄互换走 swapPiP）。
    func switchPosition(to position: Position,
                        onDone: @escaping @MainActor (_ position: Position) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.configured, !self.dualCamEnabled else { return }
            self.currentPosition = position
            self.reconfigureVideoInputLocked(position: position)
            Task { @MainActor in
                onDone(position)
            }
        }
    }

    // MARK: 双摄（CAM-021，SPEC-CAM-001 v1.2 目标4/A8）

    /// 双摄开关（主线程调用）。停会话 → 重配输入（前后同开 / 单摄回退）→ 起会话
    /// （MultiCamSession 要求停止态改配置）。双摄建立失败（资源/机型边界）自动
    /// 回退单摄并如实回调 false，不伪造成功。
    func setDualCamEnabled(_ enabled: Bool,
                           onDone: @escaping @MainActor (_ applied: Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.configured else {
                Task { @MainActor in onDone(false) }
                return
            }
            guard enabled == false || AVCaptureMultiCamSession.isMultiCamSupported else {
                Task { @MainActor in onDone(false) }
                return
            }
            guard enabled != self.dualCamEnabled else {
                Task { @MainActor in onDone(true) }
                return
            }
            let wasRunning = self.session.isRunning
            if wasRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            self.reconfigureInputsLocked(position: self.currentPosition, dual: enabled)
            var applied = enabled
            if enabled, self.videoInput == nil || self.frontVideoInput == nil {
                applied = false   // 双摄建立失败：回退单摄（诚实降级）
                self.reconfigureInputsLocked(position: self.currentPosition, dual: false)
            }
            self.session.commitConfiguration()
            self.dualCamEnabled = applied
            if (wasRunning || applied) && !self.session.isRunning {
                self.session.startRunning()
            }
            let ok = applied && self.session.isRunning
            if !ok { self.dualCamEnabled = false }
            Task { @MainActor in onDone(ok) }
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
            self.reapplyOutputConnectionsLocked()
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

    // MARK: 采集设置（2026-10-07 用户反馈轮：档位 / 帧率；预览与录制共用）

    /// 采集分辨率档位（主线程调用）。走「停会话 → 换 preset → 起会话」窗口：
    /// 运行中直接换 preset 在部分机型不可靠，统一停起最稳。不支持（
    /// canSetSessionPreset 不过）时保持原档位并回调 false，不伪造成功。
    /// 未配置时只存值（configureLocked 会取用）。
    func setCaptureQuality(_ quality: CaptureQuality,
                           onDone: @escaping @MainActor (_ applied: Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.configured else {
                self.captureQuality = quality
                Task { @MainActor in onDone(true) }
                return
            }
            let wasRunning = self.session.isRunning
            if wasRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            var applied = false
            if self.session.canSetSessionPreset(quality.preset) {
                self.session.sessionPreset = quality.preset
                self.captureQuality = quality
                applied = true
            } else {
                Self.logger.error("采集档位 \(quality.rawValue, privacy: .public) 不被支持，保持原档位")
            }
            self.session.commitConfiguration()
            if wasRunning { self.session.startRunning() }
            Task { @MainActor in onDone(applied) }
        }
    }

    /// 帧率（主线程调用）。对视频设备设 min=max=1/fps（统一节拍，防漂移）。
    /// 设备 activeFormat 不支持时回调 false 并保持原值；未配置时先存值待重放。
    func setFrameRate(_ fps: Int,
                      onDone: @escaping @MainActor (_ applied: Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let input = self.videoInput, self.configured else {
                self.frameRate = fps
                Task { @MainActor in onDone(true) }
                return
            }
            if self.applyFrameRateLocked(fps, to: input.device) {
                self.frameRate = fps
                Task { @MainActor in onDone(true) }
            } else {
                Task { @MainActor in onDone(false) }
            }
        }
    }

    /// 对设备应用帧率（sessionQueue 调用；lockForConfiguration 纪律）。
    @discardableResult
    private func applyFrameRateLocked(_ fps: Int, to device: AVCaptureDevice) -> Bool {
        guard fps > 0 else { return false }
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate
        }
        guard supported else {
            Self.logger.error("帧率 \(fps, privacy: .public) fps 不被当前 activeFormat 支持，保持原帧率")
            return false
        }
        do {
            try device.lockForConfiguration()
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
            return true
        } catch {
            Self.logger.error("帧率设置失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: 变焦（2026-10-07 用户反馈轮；sessionQueue + 配置锁）

    /// 变焦（主线程调用；捏合手势/滑杆实时生效）。manager 内夹取到
    /// [1, activeFormat.videoMaxZoomFactor]——不同机型的光学/数码范围不同，
    /// UI 端的请求值只做粗限，以设备夹取为准。
    func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let clamped = min(max(factor, 1), device.activeFormat.videoMaxZoomFactor)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                self.zoomFactor = clamped
            } catch {
                Self.logger.error("变焦设置失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: 曝光 / 对焦（2026-10-07 用户反馈轮；全部 sessionQueue + 配置锁）

    /// 曝光补偿（EV）。manager 内夹取到设备支持区间；UI 滑杆实时生效。
    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let clamped = min(max(bias, device.activeFormat.minExposureTargetBias),
                              device.activeFormat.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped)
                device.unlockForConfiguration()
            } catch {
                Self.logger.error("曝光补偿设置失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 手动对焦（lensPosition 0 = 最近，1 = 最远）。切 .locked 并锁定透镜位置。
    func setFocusLensPosition(_ position: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let clamped = min(max(position, 0), 1)
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: clamped)
                }
                device.unlockForConfiguration()
            } catch {
                Self.logger.error("手动对焦设置失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 回到连续自动对焦 + 连续自动曝光（UI「自动」重置）。
    func resetFocusAndExposure() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                Self.logger.error("对焦/曝光重置失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: 拍照（CAM-003 追加）

    /// 拍一张静态照片。完成回调带回**未处理的**原始像素缓冲（美颜/滤镜由上层
    /// 统一走 process 链，保证与预览同序），错误/失败以 nil 上抛（诚实暴露）。
    /// 可在视频录制中调用（AVFoundation 支持拍录并发）。
    /// - Parameter highResolution: 高清拍照（2026-10-07 用户反馈轮）——iOS 16+
    ///   `maxPhotoDimensions` 突破 sessionPreset 的分辨率上限取全分辨率，并以
    ///   .quality 优先级编码（configure 时已把 photoOutput 上限设为 .quality）。
    func capturePhoto(highResolution: Bool = false,
                      onDone: @escaping (_ pixelBuffer: CVImageBuffer?) -> Void) {
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
            // ⚠️ 必须显式要 pixel buffer 格式（CAM-017 二修，P73）：默认 settings 走
            // HEIF/JPEG 文件编码管线，`photo.pixelBuffer` 为 nil —— PhotoRelay 只能
            // 回 nil，表现为「拍照无效」。BGRA 与预览/录制链同口径，WYSIWYG 直通；
            // 机型不含 BGRA 时取支持的第一个（CIImage 可直接吃 420f/420v），不赌。
            // available 列表 Swift 导入为 [OSType]，直接与 fourcc 枚举比较。
            let supportedTypes = self.photoOutput.availablePhotoPixelFormatTypes
            let pixelFormat: OSType
            if supportedTypes.contains(kCVPixelFormatType_32BGRA) {
                pixelFormat = kCVPixelFormatType_32BGRA
            } else if let first = supportedTypes.first {
                pixelFormat = first
            } else {
                Self.logger.error("拍照中止：photoOutput 无可用 pixel-buffer 格式")
                relay.deliver(nil)
                return
            }
            let settings = AVCapturePhotoSettings(format: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            ])
            // 高清拍照：maxPhotoDimensions 取 photoOutput 上限 = 超出 sessionPreset
            // 的全分辨率（iOS 16+ API，部署目标 16.0 无需门控）；质量优先 .quality。
            if highResolution {
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            }
            settings.photoQualityPrioritization = highResolution ? .quality : .balanced
            // 方向/镜像沿用 connection 的呈现设置（拍照接后摄，CAM-016）。
            if let connection = self.photoOutput.connection(with: .video) {
                self.applyOrientation(connection, self.interfaceOrientation, for: .back)
                self.applyMirrorIfFront(connection, for: .back)
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self.photoRelay)
        }
    }

    // MARK: 内部配置（必须在 sessionQueue 上调用）

    private func configureLocked(position: Position) {
        session.beginConfiguration()
        // 档位由 captureQuality 决定（默认 1080p；用户可在设置面板换 720p/4K）。
        session.sessionPreset = captureQuality.preset
        defer { session.commitConfiguration() }

        // 视频输出：32BGRA（与零拷贝链路同口径）+ 丢帧保实时。
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(relay, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        // 前摄输出（CAM-021）：delegate/设置配置一次；仅双摄模式挂会话。
        frontVideoOutput.videoSettings = videoOutput.videoSettings
        frontVideoOutput.alwaysDiscardsLateVideoFrames = true
        frontVideoOutput.setSampleBufferDelegate(frontRelay, queue: frontQueue)
        // 方向 + 镜像约定由 connection 如实设置（跟随界面方向，CAM-016）。
        if let connection = videoOutput.connection(with: .video) {
            applyOrientation(connection, interfaceOrientation, for: position)
            applyMirrorIfFront(connection, for: position)
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
        // 高清拍照前置：settings 的 photoQualityPrioritization 不得超过本上限
        //（.quality 为最高，.balanced/.fast 都在其下）。
        photoOutput.maxPhotoQualityPrioritization = .quality

        reconfigureVideoInputLocked(position: position)
    }

    /// 单摄输入重配（switchPosition / configure 入口）。
    private func reconfigureVideoInputLocked(position: Position) {
        reconfigureInputsLocked(position: position, dual: dualCamEnabled)
    }

    /// 输入重配（sessionQueue；MultiCamSession 要求停止态，调用方保证）。
    /// 双摄 = 前后两路 video input + 各自 video output；单摄 = 现行路径并摘前摄输出。
    private func reconfigureInputsLocked(position: Position, dual: Bool) {
        if let old = videoInput {
            session.removeInput(old)
            videoInput = nil
        }
        if let old = frontVideoInput {
            session.removeInput(old)
            frontVideoInput = nil
        }

        if dual {
            if !session.outputs.contains(frontVideoOutput), session.canAddOutput(frontVideoOutput) {
                session.addOutput(frontVideoOutput)
            }
            videoInput = addVideoInputLocked(position: .back, output: videoOutput)
            frontVideoInput = addVideoInputLocked(position: .front, output: frontVideoOutput)
        } else {
            if session.outputs.contains(frontVideoOutput) {
                session.removeOutput(frontVideoOutput)
            }
            videoInput = addVideoInputLocked(position: position, output: videoOutput)
        }
        // 变焦重置：新镜头组从 1.0 起（与系统相机惯例一致；VM 侧同步归一）。
        zoomFactor = 1.0
        // 输入重建会重连全部 output connection：方向/镜像按各自摄位重放。
        reapplyOutputConnectionsLocked()
    }

    /// 添加一路 video input 并接 output（帧率随路重放）。失败返回 nil（不伪造成功）。
    @discardableResult
    private func addVideoInputLocked(position: Position,
                                     output: AVCaptureVideoDataOutput) -> AVCaptureDeviceInput? {
        let deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
        let avPosition: AVCaptureDevice.Position = (position == .front) ? .front : .back
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: avPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return nil  // 设备缺失/被占用：调用方以 nil 判断
        }
        session.addInput(input)
        applyFrameRateLocked(frameRate, to: input.device)
        return input
    }

    /// 全部 video connection 重放方向/镜像（各按其摄位：双摄时前摄输出镜像 + 270° 偏移）。
    private func reapplyOutputConnectionsLocked() {
        for output in session.outputs {
            guard let connection = output.connection(with: .video) else { continue }
            let pos: Position = (output === frontVideoOutput) ? .front : .back
            applyOrientation(connection, interfaceOrientation, for: pos)
            applyMirrorIfFront(connection, for: pos)
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
    private func applyOrientation(_ connection: AVCaptureConnection, _ io: UIInterfaceOrientation,
                                  for position: Position) {
        if #available(iOS 17.0, *) {
            // 静态表 + 前摄安装差常量（CAM-017 二修，P72）。旧 API（else 分支）是
            // 语义方向（portrait=竖直），系统内处理安装差异，**不**加偏移。
            // 双摄（CAM-021）按各 connection 自己的摄位取偏移，不再看 currentPosition。
            let offset: CGFloat = (position == .front) ? 270 : 0
            let angle = Self.snappedToQuarter(Self.rotationAngle(for: io) + offset)
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else if connection.isVideoOrientationSupported, let vo = Self.videoOrientation(for: io) {
            connection.videoOrientation = vo
        }
    }

    /// 镜像（旋转之后应用，Apple 语义；按 connection 自己的摄位——双摄时后摄不镜像、
    /// 前摄镜像，与 currentPosition 无关）。
    private func applyMirrorIfFront(_ connection: AVCaptureConnection, for position: Position) {
        if position == .front && connection.isVideoMirroringSupported {
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
