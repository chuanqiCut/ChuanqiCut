// CameraManager — 相机采集编排（CAM-002，ADR-0014：iOS 原生，不经 Platform/C ABI）
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

        /// 档位目标尺寸（**MultiCamSession 专用**：那条路径不能设 preset，只能逐设备
        /// 选 activeFormat，用它做"最接近"筛选的目标）。
        var targetDimensions: CMVideoDimensions {
            switch self {
            case .hd720: return CMVideoDimensions(width: 1280, height: 720)
            case .hd1080: return CMVideoDimensions(width: 1920, height: 1080)
            case .uhd4K: return CMVideoDimensions(width: 3840, height: 2160)
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
        // CQ_CAM_FORCE_PLAIN=1：强制普通 AVCaptureSession（P112 二分实验——
        // MultiCam 会话下 AVAssetWriter startWriting/首帧 append 以 FigXPC -17281
        // 失败，本开关验证「MultiCam × Writer」是否为根因；按结论定终态）。
        let useMultiCam = AVCaptureMultiCamSession.isMultiCamSupported
            && ProcessInfo.processInfo.environment["CQ_CAM_FORCE_PLAIN"] == nil
        return useMultiCam ? AVCaptureMultiCamSession() : AVCaptureSession()
    }

    /// 当前会话是否是 MultiCam（**决定采集档位怎么设**，见 `applyCaptureQualityLocked`）。
    ///
    /// ⚠️ 实测（2026-10-09，iPhone 17 Pro）：`AVCaptureMultiCamSession` **不支持
    /// sessionPreset** —— 对它 `setSessionPreset:` 直接抛
    /// `NSInvalidArgumentException: AVCaptureSessionPreset1920x1080 is not a supported preset`
    /// 而崩溃（不是返回 false，也不是 canSetSessionPreset 能拦住的）。Apple 的口径是
    /// multi-cam 必须**逐设备设 activeFormat**。iPhone 15/17 这类机型
    /// `isMultiCamSupported` 恒为 true，所以这条路径是**默认路径**，不是边界情况。
    private var isMultiCamSession: Bool { session is AVCaptureMultiCamSession }

    /// 设备级双摄支持（CAM-021：UI 依此置灰开关，SPEC A8 不支持机型诚实降级）。
    static var isMultiCamSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    /// 深度能力设备查询（CAM-023；广角单摄**无深度**——需双摄/TrueDepth/LiDAR 虚拟设备）。
    /// UI 依此置灰人像虚化开关；无深度 = 如实降级，不伪造。
    static func depthCapableDevice(for position: Position) -> AVCaptureDevice? {
        let avPosition: AVCaptureDevice.Position = (position == .front) ? .front : .back
        let types: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInTrueDepthCamera]
            : [.builtInDualWideCamera, .builtInDualCamera, .builtInLiDARDepthCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: avPosition) {
                return device
            }
        }
        return nil
    }

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
    /// 深度输出（CAM-023 人像虚化；仅人像虚化开启时挂会话）。
    private let depthOutput = AVCaptureDepthDataOutput()
    private let depthQueue = DispatchQueue(label: "cq.camera.depth")
    private let depthRelay = DepthRelay()

    private var videoInput: AVCaptureDeviceInput?
    private var frontVideoInput: AVCaptureDeviceInput?

    // MARK: 系统人脸框（CAM-033，RESEARCH-015 决策 1）

    /// 采集栈原生人脸框输出：**零 Vision 调用、零图像转换**（AVFoundation 在采集
    /// 管线内送脸框），磨皮/美白蒙版的数据源。landmark（美型/贴纸锚点）仍走
    /// VisionDetector（按需）。
    private let metadataOutput = AVCaptureMetadataOutput()
    private let metadataQueue = DispatchQueue(label: "cq.camera.metadata")
    /// metadataOutput 是否已成功挂会话（VM 装配 BeautyDetectionPlan 的判据之一；
    /// 双摄模式下 metadata 框路属待真机标定，VM 侧对双摄回退 Vision 兜底）。
    private(set) var isMetadataFacesActive = false
    /// metadata 脸框回调（metadataQueue）：rect 已转视频帧归一化坐标
    /// （origin 左上 0...1，CAM-011 契约同向）。**空数组也回调**（目标离开画面
    /// → 消费方 FaceBoxStore 清空语义）。磨皮关闭时消费方也可忽略。
    var onMetadataFaces: ((_ rects: [CGRect], _ mirrored: Bool) -> Void)?
    private var audioInput: AVCaptureDeviceInput?
    private(set) var currentPosition: Position = .back
    /// 双摄模式（sessionQueue 独占；开关经 setDualCamEnabled）。
    private(set) var dualCamEnabled = false
    /// 人像虚化（CAM-023；sessionQueue 独占。开启时视频输入切深度能力设备）。
    private(set) var portraitBlurEnabled = false
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
        if Self.faceCalib {
            fputs("[cam-lifecycle] configureAndStart requested\n", stderr)
            CrashProbe.traceNow("configureAndStart")
            fflush(stderr)
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.configureLocked(position: self.currentPosition)
                self.configured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.activateMetadataFacesIfNeededLocked()
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
            // ⚠️ 必须用配置事务包裹（P113）：裸改输入时移除/添加**即时生效**，
            // 新旧输入交接的若干帧以默认方向（传感器横向）流出 → 预览横屏闪现
            //（B-02 用户实测）。事务内变更在 commit 才原子生效，方向已就位。
            self.session.beginConfiguration()
            self.reconfigureVideoInputLocked(position: position)
            self.session.commitConfiguration()
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

    // MARK: 景深人像（CAM-023；深度仅服务拍照路径）

    /// 人像虚化开关（主线程调用）。开启 = 视频输入切**深度能力设备**（仍出普通视频帧）
    /// + 挂深度输出（connection 方向随视频同步）；当前摄位无深度设备 → 如实回调 false。
    /// 与双摄互斥（v1：双摄开启时拒绝并明示）。
    func setPortraitBlurEnabled(_ enabled: Bool,
                                onDone: @escaping @MainActor (_ applied: Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.configured else {
                Task { @MainActor in onDone(false) }
                return
            }
            guard enabled != self.portraitBlurEnabled else {
                Task { @MainActor in onDone(true) }
                return
            }
            guard enabled == false || !self.dualCamEnabled else {
                Self.logger.error("人像虚化与双摄互斥（v1）：请先关闭双摄")
                Task { @MainActor in onDone(false) }
                return
            }
            let depthDevice = enabled ? Self.depthCapableDevice(for: self.currentPosition) : nil
            if enabled, depthDevice == nil {
                Self.logger.error("当前摄位无深度能力设备，人像虚化不可用")
                Task { @MainActor in onDone(false) }
                return
            }
            let wasRunning = self.session.isRunning
            if wasRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            self.portraitBlurEnabled = enabled
            // 重配输入：开启 = 深度能力设备（普通视频帧照常）；关闭 = 回广角。
            reconfigureInputsLocked(position: self.currentPosition, dual: self.dualCamEnabled)
            if enabled {
                if !session.outputs.contains(depthOutput), session.canAddOutput(depthOutput) {
                    depthOutput.isFilteringEnabled = false   // 不做系统内插，保原始深度
                    session.addOutput(depthOutput)
                }
            } else if session.outputs.contains(depthOutput) {
                session.removeOutput(depthOutput)
            }
            self.session.commitConfiguration()
            if (wasRunning || enabled) && !self.session.isRunning {
                self.session.startRunning()
            }
            let ok = enabled ? (self.session.isRunning
                                && self.depthOutput.connection(with: .depthData)?.isActive == true)
                             : true
            if !ok { self.portraitBlurEnabled = false }
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

    /// 启用 metadata 人脸框（sessionQueue 内、startRunning **之后**调用）：
    /// availableMetadataObjectTypes 只有在会话配置提交后才填充（真机实证）。
    /// 幂等：重复调用安全（configureAndStart 每次都会走）。
    private func activateMetadataFacesIfNeededLocked() {
        guard session.outputs.contains(metadataOutput) else {
            isMetadataFacesActive = false
            return
        }
        guard metadataOutput.metadataObjectTypes.isEmpty else {
            // ⚠️ 幂等分支也必须过闸门（CAM-033 闪帧根因之三，D2 日志实锤）：
            // 此前无条件置 true——types 已设但闸门关时，updateDetectionPlan 以为
            // metadata 会供框 → plan 空集，而回调被闸门挡住不写 store →
            // FaceBoxStore 永远空 → 磨皮/美白全直通 = 闪。
            isMetadataFacesActive = Self.metadataFacesCalibrated
            return
        }
        if metadataOutput.availableMetadataObjectTypes.contains(.face) {
            metadataOutput.metadataObjectTypes = [.face]
            // 标定闸门：映射未定标（metadataFacesCalibrated=false）时框不消费，
            // 数据通路保持（faceCalib 模式照常采集标定数据）。
            isMetadataFacesActive = Self.metadataFacesCalibrated
            if !Self.metadataFacesCalibrated, Self.faceCalib {
                fputs("[face-calib] metadata alive but gate closed (not calibrated)\n", stderr)
                fflush(stderr)
            }
        } else {
            isMetadataFacesActive = false   // 设备不支持：诚实降级，plan 回退 Vision
            if Self.faceCalib {
                fputs("[face-calib] metadata .face unavailable after startRunning\n", stderr)
                fflush(stderr)
            }
        }
    }

    /// 真机标定/取证模式（CAM-033：脸框标定 + 会话生命周期取证，stderr 探针口径）。
    static let faceCalib = ProcessInfo.processInfo.environment["CQ_CAM_FACE_CALIB"] == "1"

    /// metadata 脸框是否已标定可消费（CAM-033 标定闸门）。
    /// 真机二轮实证（2026-10-11，池 [15]）：`outputRectConverted(fromMetadataOutputRect:)`
    /// 输出与文档语义不符（实测像素级 + 旋转错位，height≈1248/1 归一化空间），
    /// **映射常数未定标前 metadata 框不得进蒙版**（坏框比慢更糟）——闸门关闭 =
    /// isMetadataFacesActive 强制 false，plan 自动回退 Vision faceRectangles 兜底
    /// （单阶段，坐标已验证正确）。定标 SOP：受控条件下（人脸对相机、画面中央）
    /// 跑 CQ_CAM_FACE_CALIB=1 采集 meta raw/vision box 对照数据 → 反解映射 →
    /// 修 MetadataFaceGeometry → 本闸门翻 true。标定数据采集不受闸门影响
    ///（faceCalib 模式照常打日志）。
    static let metadataFacesCalibrated = false

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if Self.faceCalib {
                fputs("[cam-lifecycle] stop requested running=\(self.session.isRunning)\n", stderr)
                fflush(stderr)
            }
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
            let applied = self.applyCaptureQualityLocked(quality)
            self.session.commitConfiguration()
            if wasRunning { self.session.startRunning() }
            Task { @MainActor in onDone(applied) }
        }
    }

    /// 应用采集档位（sessionQueue + 配置事务内调用）。
    /// - 普通 Session：走 `sessionPreset`（`canSetSessionPreset` 不过 = 保持原档位，如实 false）。
    /// - **MultiCamSession：禁止碰 preset**（设了必崩），改逐设备 `activeFormat`。
    /// 未建输入（configure 早期）时只记录档位值，等输入重建时重放。
    @discardableResult
    private func applyCaptureQualityLocked(_ quality: CaptureQuality) -> Bool {
        if isMultiCamSession {
            let inputs = [videoInput, frontVideoInput].compactMap { $0 }
            guard !inputs.isEmpty else {
                captureQuality = quality        // 输入还没建：存值，addVideoInputLocked 会重放
                return true
            }
            var anyApplied = false
            for input in inputs {
                anyApplied = applyFormatLocked(quality, to: input.device) || anyApplied
            }
            guard anyApplied else {
                Self.logger.warning("采集档位 \(quality.rawValue, privacy: .public) 在当前设备上无可用 activeFormat，保持原档位")
                return false
            }
            captureQuality = quality
            return true
        }
        guard session.canSetSessionPreset(quality.preset) else {
            Self.logger.warning("采集档位 \(quality.rawValue, privacy: .public) 不被支持，保持原档位")
            return false
        }
        session.sessionPreset = quality.preset
        captureQuality = quality
        return true
    }

    /// 逐设备选 activeFormat（MultiCam 路径）：在**帧率区间覆盖当前 fps** 的候选里，
    /// 取分辨率最接近档位目标的一个；选完必须重放帧率（换 format 会重置帧率范围）。
    @discardableResult
    private func applyFormatLocked(_ quality: CaptureQuality, to device: AVCaptureDevice) -> Bool {
        let target = quality.targetDimensions
        let wantFps = Double(frameRate)
        // 选择规则抽到契约层纯函数（可单测）：MultiCam 下 activeFormat 还有一条硬约束
        // ——只能落在 isMultiCamSupported 的子集里（AVCaptureDevice.h 原文）。
        // 以前这里只按帧率筛，等于把约束寄托在调用方记忆上。
        let candidates = device.formats.map { format in
            let dims = format.formatDescription.dimensions
            let range = format.videoSupportedFrameRateRanges
            let minFps = range.map { $0.minFrameRate }.min() ?? 0
            let maxFps = range.map { $0.maxFrameRate }.max() ?? 0
            return CameraFormatCandidate(width: Int(dims.width),
                                         height: Int(dims.height),
                                         minFrameRate: minFps,
                                         maxFrameRate: maxFps,
                                         multiCamSupported: format.isMultiCamSupported)
        }
        guard let picked = CameraFormatSelector.bestIndex(in: candidates,
                                                          targetWidth: Int(target.width),
                                                          targetHeight: Int(target.height),
                                                          frameRate: wantFps,
                                                          multiCam: isMultiCamSession) else {
            Self.logger.warning("设备 \(device.localizedName, privacy: .public) 在 \(self.frameRate, privacy: .public)fps 下无可用 activeFormat")
            return false
        }
        let format = device.formats[picked]
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
        } catch {
            Self.logger.error("activeFormat 设置失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
        applyFrameRateLocked(frameRate, to: device)
        return true
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
            // ⚠️ 曝光夹取区间在 **device** 上，不在 activeFormat 上（AVCaptureDevice.h:
            // min/maxExposureTargetBias 是 AVCaptureDevice 属性）。写错时 Swift 6 只报
            // 「cannot convert '_' to DispatchWorkItem」这类闭包级联错，看不出真因（P83 同族）。
            let clamped = min(max(bias, device.minExposureTargetBias),
                              device.maxExposureTargetBias)
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
    /// - Parameter depthDelivery: 人像虚化深度交付（CAM-023）——深度输出 active 时
    ///   请求内嵌 AVDepthData；失败/缺失以 nil 伴随上抛，上层诚实跳过虚化。
    /// - Parameter onDone: metadata 必须透传（P111）——iOS 26 photoOutput 交付
    ///   **未旋转** buffer，方向在 kCGImagePropertyOrientation 元数据里，消费管线
    ///   据 `.oriented()` 摆正；忽略它 = 照片横躺（B-02 真机实证）。
    func capturePhoto(highResolution: Bool = false, depthDelivery: Bool = false,
                      onDone: @escaping (_ pixelBuffer: CVImageBuffer?, _ depthData: AVDepthData?,
                                         _ metadata: [AnyHashable: Any]?) -> Void) {
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
            // 深度交付（CAM-023）：深度输出 active 才请求内嵌 AVDepthData。
            // ⚠️ isDepthDataDeliveryEnabled 命名本机无 SDK 头可核（P48/P83 同族），
            // 构建机首编译如有出入按头文件对表（一行级）。
            if depthDelivery,
               self.depthOutput.connection(with: .depthData)?.isActive == true {
                settings.isDepthDataDeliveryEnabled = true
            }
            // 方向/镜像按 connection 实际摄位，**两条线分开**（P111 真机实证）：
            //   角度 —— photoOutput 语义（前摄与后摄同款：90=竖屏；前摄 270° 偏移
            //           只属于 videoDataOutput，误用于 photo 会交付横向原生缓冲）；
            //   镜像 —— 真实摄位（前摄照片镜像，与预览 WYSIWYG 一致）。
            if let connection = self.photoOutput.connection(with: .video) {
                let pos = self.position(of: connection)
                self.applyOrientation(connection, self.interfaceOrientation, for: .back,
                                      photoOutputSemantics: true)
                self.applyMirrorIfFront(connection, for: pos)
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self.photoRelay)
        }
    }

    // MARK: 内部配置（必须在 sessionQueue 上调用）

    private func configureLocked(position: Position) {
        session.beginConfiguration()
        // 档位由 captureQuality 决定（默认 1080p；用户可在设置面板换 720p/4K）。
        // ⚠️ 不能直接 `session.sessionPreset = ...`：MultiCamSession 上会抛异常崩溃
        //（2026-10-09 实测）→ 走 applyCaptureQualityLocked 分流（multiCam 逐设备 format）。
        _ = applyCaptureQualityLocked(captureQuality)
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

        // 系统人脸框（CAM-033）：磨皮蒙版数据源（零 Vision 成本）。加输出需在
        // commitConfiguration 前；metadata 无帧方向语义，rect 转换在回调里经
        // outputRectConverted 对齐视频帧坐标系（镜像补偿在契约层纯函数）。
        if session.canAddOutput(metadataOutput) {
            // ⚠️ 顺序硬约束（真机 P0/P107' 实证 2026-10-11）：
            // ① setMetadataObjectTypes 必须在 addOutput **之后**（此前抛
            //    NSInvalidArgumentException 崩溃）；
            // ② availableMetadataObjectTypes 在 commitConfiguration/startRunning
            //    **之前仍为空**（真机二轮实证）→ types 设置延后到
            //    activateMetadataFacesIfNeededLocked（startRunning 后调用）。
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
        } else {
            isMetadataFacesActive = false
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

    /// 添加一路 video input 并接 output（帧率随路重放）。人像虚化开启时选**深度能力
    /// 设备**（广角无深度）；否则广角。失败返回 nil（不伪造成功）。
    @discardableResult
    private func addVideoInputLocked(position: Position,
                                     output: AVCaptureVideoDataOutput) -> AVCaptureDeviceInput? {
        let deviceType: AVCaptureDevice.DeviceType = portraitBlurEnabled
            ? (Self.depthCapableDevice(for: position)?.deviceType ?? .builtInWideAngleCamera)
            : .builtInWideAngleCamera
        let avPosition: AVCaptureDevice.Position = (position == .front) ? .front : .back
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: avPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return nil  // 设备缺失/被占用：调用方以 nil 判断
        }
        session.addInput(input)
        // 档位重放：MultiCam 下 preset 不可用，档位落在设备 activeFormat 上
        //（新建的 input 必须重放一次，否则新设备走默认 format）。
        if isMultiCamSession {
            _ = applyFormatLocked(captureQuality, to: input.device)
        }
        applyFrameRateLocked(frameRate, to: input.device)
        return input
    }

    /// connection 的实际摄位：从 inputPort 的源设备读（AVCaptureInput.h:157 ——
    /// port 的 sourceDevicePosition 恒等于 deviceInput.device.position）。
    /// ⚠️ 不能按「输出身份」推断（CAM-021 回归根因）：单摄前摄时前摄挂在**主**
    /// videoOutput 上，按 `output === frontVideoOutput` 判成后摄 → 偏移 0 而非
    /// 270° → 前摄横躺。摄位以 connection 实际连接的设备为准，单摄/双摄一视同仁。
    /// 端口缺失（连接尚未建立）时回退 currentPosition（防御，正常不可达）。
    private func position(of connection: AVCaptureConnection) -> Position {
        if let devicePosition = connection.inputPorts.first?.sourceDevicePosition {
            return devicePosition == .front ? .front : .back
        }
        return currentPosition
    }

    /// 全部 video connection 重放方向/镜像（各按其摄位：双摄时前摄输出镜像 + 270° 偏移）。
    /// 深度 connection（CAM-023）同步同向——深度图与照片配准的前提。
    private func reapplyOutputConnectionsLocked() {
        for output in session.outputs {
            guard let connection = output.connection(with: .video) else { continue }
            let pos = position(of: connection)
            applyOrientation(connection, interfaceOrientation, for: pos)
            applyMirrorIfFront(connection, for: pos)
        }
        if portraitBlurEnabled, let depthConnection = depthOutput.connection(with: .depthData) {
            applyOrientation(depthConnection, interfaceOrientation, for: currentPosition)
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
                                  for position: Position,
                                  photoOutputSemantics: Bool = false) {
        if #available(iOS 17.0, *) {
            // 静态表 + 前摄安装差常量（CAM-017 二修，P72）。旧 API（else 分支）是
            // 语义方向（portrait=竖直），系统内处理安装差异，**不**加偏移。
            // 双摄（CAM-021）按各 connection 自己的摄位取偏移，不再看 currentPosition。
            //
            // ⚠️ P111（B-02 真机探针实测）：前摄 270° 安装偏移**只适用于
            // videoDataOutput** —— photoOutput 的旋转参考与前摄安装差无关
            //（前摄 photo 用后摄同款语义：90=竖屏；angle 0 交付横向原生缓冲，
            // 真机照片 1920×1080 人脸横躺实证）。拍照路径传 photoOutputSemantics=true。
            let offset: CGFloat = (position == .front && !photoOutputSemantics) ? 270 : 0
            let angle = Self.snappedToQuarter(Self.rotationAngle(for: io) + offset)
            let supported = connection.isVideoRotationAngleSupported(angle)
            if supported {
                connection.videoRotationAngle = angle
            }
            #if DEBUG
            // B-02 真机探针（CQ_CAM_PROBE 在场时输出；P67/P72 语义的机器取证：
            // 后摄 portrait=90/前摄 portrait=0 + 前摄镜像）。打印**实际生效值**
            //（supported=false 时赋值被跳过，光看计算值会被骗——P111 排障实证）。
            if ProcessInfo.processInfo.environment["CQ_CAM_PROBE"] != nil {
                let mirrored = position == .front && connection.isVideoMirroringSupported
                    ? connection.isVideoMirrored : false
                fputs("[cam-probe] orientation pos=\(position == .front ? "front" : "back")"
                      + " photo=\(photoOutputSemantics ? 1 : 0)"
                      + " angle=\(Int(angle)) supported=\(supported)"
                      + " actual=\(Int(connection.videoRotationAngle))"
                      + " mirror=\(mirrored)\n", stderr)
                fflush(stderr)
            }
            #endif
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

    /// 深度数据（CAM-023）：depthDelivery 开启时随照片内嵌交付；nil = 无深度（诚实降级）。
    var onPhoto: ((_ pixelBuffer: CVImageBuffer?, _ depthData: AVDepthData?,
                   _ metadata: [AnyHashable: Any]?) -> Void)?

    /// 派发一次性拍照回调并清空（拍照单发，不重复触发）。
    /// metadata 必须透传（P111）：iOS 26 photoOutput 交付未旋转 buffer，
    /// 方向在 kCGImagePropertyOrientation 元数据里。
    func deliver(_ buffer: CVImageBuffer?, _ depth: AVDepthData? = nil,
                 _ metadata: [AnyHashable: Any]? = nil) {
        let callback = onPhoto
        onPhoto = nil
        callback?(buffer, depth, metadata)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        #if DEBUG
        // P111 取证：photoOutput 的 buffer 是否「不旋转、方向走元数据」——
        // kCGImagePropertyOrientation 在场 = 管线必须 .oriented() 消费。
        if ProcessInfo.processInfo.environment["CQ_CAM_PROBE"] != nil {
            let o: Any? = photo.metadata[String(kCGImagePropertyOrientation)]
            fputs("[cam-probe] photo meta orient=\(o ?? "nil")\n", stderr)
            fflush(stderr)
        }
        #endif
        guard error == nil, let buffer = photo.pixelBuffer else {
            // 遥测（CAM-017）：失败原因直接可见，不靠 UI 层猜。
            Self.logger.error("拍照回调失败：\(error?.localizedDescription ?? "pixelBuffer 缺失", privacy: .public)")
            deliver(nil)
            return
        }
        // ⚠️ AVCapturePhoto.depthData 命名本机无 SDK 头可核（P48/P83 同族），
        // 构建机首编译如有出入按头文件对表（一行级）。
        deliver(buffer, photo.depthData, photo.metadata)
    }
}

// MARK: - 深度中继（CAM-023；AVCaptureDepthDataOutputDelegate 回调在 depthQueue）

/// v1 仅持有回调口（拍照深度走 photo 内嵌交付，不走流）；流式深度供后续预览虚化轮。
private final class DepthRelay: NSObject, AVCaptureDepthDataOutputDelegate {

    var onDepth: ((AVDepthData, CMTime) -> Void)?

    func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                         didOutput depthData: AVDepthData,
                         timestamp: CMTime,
                         connection: AVCaptureConnection) {
        onDepth?(depthData, timestamp)
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate（CAM-033 系统人脸框）

extension CameraManager: AVCaptureMetadataOutputObjectsDelegate {

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        // 闸门源头挡（CAM-033 闪帧根因之一）：未定标（metadataFacesCalibrated=false）
        // 时 metadata 框为像素级乱坐标，**绝不能进 FaceBoxStore**（磨皮蒙版数据源）
        // ——此前闸门只关了 Vision plan，回调仍无条件写 store，错乱框与 Vision 框
        // 竞争写 = 磨皮/美白开启时蒙版乱跳闪帧。faceCalib 取证日志不受影响。
        guard Self.metadataFacesCalibrated else {
            if Self.faceCalib, let first = metadataObjects.compactMap({ ($0 as? AVMetadataObject)?.bounds }).first {
                fputs(String(format: "[face-calib] meta(raw only, gate closed) (%.4f,%.4f,%.4f,%.4f)\n",
                             first.minX, first.minY, first.width, first.height), stderr)
                fflush(stderr)
            }
            return
        }
        guard let callback = onMetadataFaces else { return }
        // rect 转换目标 = 主画面 videoOutput（磨皮蒙版只服务主画面；PiP 的人脸链
        // 走 VisionDetector 桥）。镜像读主 connection —— metadataQueue 读 connection
        // 状态是 AVFoundation 允许的轻量操作（属性快照）。
        let mirrored = videoOutput.connection(with: .video)?.isVideoMirrored ?? false
        // 标定模式同时打 metadata 原始 bounds（0...1，sensor 坐标）：converted 输出
        // 语义与文档不符（真机实证非归一化），映射关系以 vision box 对照数据反解。
        let rawBounds: [CGRect] = Self.faceCalib
            ? metadataObjects.compactMap { ($0 as? AVMetadataObject)?.bounds }
            : []
        let rects = metadataObjects.compactMap { metadata -> CGRect? in
            guard metadata.type == .face else { return nil }
            let converted = videoOutput.outputRectConverted(fromMetadataOutputRect: metadata.bounds)
            return MetadataFaceGeometry.contractRect(fromConvertedRect: converted, mirrored: mirrored)
        }
        // 空数组也回调：目标离开画面 → FaceBoxStore 清空语义（与 Vision 快照对齐）。
        if Self.faceCalib {
            let desc = rects.map { String(format: "(%.1f,%.1f,%.1f,%.1f)", $0.minX, $0.minY, $0.width, $0.height) }
                .joined(separator: " ")
            let raw = rawBounds.map { String(format: "(%.4f,%.4f,%.4f,%.4f)", $0.minX, $0.minY, $0.width, $0.height) }
                .joined(separator: " ")
            fputs("[face-calib] meta n=\(rects.count) mirrored=\(mirrored) raw=[\(raw)] conv=[\(desc)]\n", stderr)
            fflush(stderr)
        }
        callback(rects, mirrored)
    }
}
