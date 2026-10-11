// CameraViewModel — 相机页状态桥（CAM-004）
//
// @MainActor：所有 @Published 状态主线程读写；采集/渲染的跨线程细节被
// CameraManager（回调线程）与 CameraRenderer（帧槽）封死在本层之外。
// UI 不直接触碰 AVFoundation 对象。

import AVFoundation
import Combine
import CoreImage
import CoreMedia
import Foundation
import Metal
import os
import Photos
import UIKit

@MainActor
final class CameraViewModel: ObservableObject {

    private static let photoLogger = Logger(subsystem: "com.chuanqi.cut", category: "camera.photo")

    enum Phase {
        case preparing      // 初始化/请求权限中
        case unauthorized   // 相机权限被拒（明示引导，不闪退）
        case running        // 会话运行中
    }

    enum CaptureMode {
        case photo
        case video
    }

    enum Position {
        case back
        case front

        var managerPosition: CameraManager.Position {
            self == .back ? .back : .front
        }
    }

    // MARK: UI 状态

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var position: Position = .back
    @Published private(set) var isRecording = false
    @Published private(set) var isCapturing = false   // 拍照瞬间（快门反馈/防连点）
    @Published private(set) var micAvailable = true
    /// 拍照/视频模式（默认照片，相机 App 惯例）。
    @Published var mode: CaptureMode = .photo
    /// 美颜参数（磨皮/美白）。实时预览即时生效；拍照按拍摄瞬间值处理；
    /// 录制在开始时锁定（录制中面板已禁用）。
    @Published var beauty = CameraBeautyParams() {
        didSet { renderer?.setBeauty(beauty) }
    }
    @Published var filter: CameraFilterPreset = .none {
        didSet { renderer?.setFilter(filter) }  // 录制中由视图层禁用滤镜条（锁定语义）
    }
    /// 美型参数（CAM-013：瘦脸/大眼/下巴）。语义与美颜一致：预览即时生效；
    /// 拍照按拍摄瞬间值处理；录制在开始时锁定。
    @Published var reshape = CameraReshapeParams() {
        didSet { renderer?.setReshape(reshape) }
    }
    /// 贴纸目录（CAM-014）：bundle 清单加载；空目录 = 贴纸入口整体隐藏（无假功能）。
    @Published private(set) var stickerCatalog: [StickerAsset] = []
    /// 当前选中贴纸；nil = 无。实时预览即时生效；录制在开始时锁定。
    @Published var selectedStickerID: String? {
        didSet { renderer?.setSticker(stickerCatalog.first { $0.id == selectedStickerID }) }
    }
    /// 最近一次录制产物（非 nil 时相机页展示「存相册/去编辑/放弃」面板）。
    @Published private(set) var recordedURL: URL?
    /// 录制开始时刻（录制计时 UI 用；nil = 未在录制）。
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var errorMessage: String?

    // MARK: 采集设置（2026-10-07 用户反馈轮）

    /// 采集分辨率档位（预览/录制共用 sessionPreset）。录制中锁定——会话重配
    /// 会改变缓冲尺寸，破坏 writer 的尺寸契约。失败时 errorMessage 明示。
    @Published private(set) var captureQuality: CameraManager.CaptureQuality = .hd1080

    func setCaptureQuality(_ quality: CameraManager.CaptureQuality) {
        guard !isRecording, quality != captureQuality else { return }
        manager.setCaptureQuality(quality) { [weak self] applied in
            if applied {
                self?.captureQuality = quality
            } else {
                self?.errorMessage = "当前设备不支持该分辨率档位"
            }
        }
    }

    /// 帧率（30/60）。录制中锁定；设备 activeFormat 不支持时 errorMessage 明示。
    @Published private(set) var frameRate: Int = 30

    func setFrameRate(_ fps: Int) {
        guard !isRecording, fps != frameRate else { return }
        manager.setFrameRate(fps) { [weak self] applied in
            if applied {
                self?.frameRate = fps
            } else {
                self?.errorMessage = "当前设备不支持 \(fps) fps"
            }
        }
    }

    /// 高清拍照（iOS 16 maxPhotoDimensions 全分辨率 + .quality 优先级）。
    @Published var highResPhoto = false

    /// 曝光补偿（EV，manager 夹取到设备区间；滑杆实时生效）。
    @Published var exposureBias: Float = 0 {
        didSet { manager.setExposureBias(exposureBias) }
    }
    /// 手动对焦 0（最近）...1（最远）；nil = 连续自动。
    @Published var focusLensPosition: Float? {
        didSet {
            if let position = focusLensPosition {
                manager.setFocusLensPosition(position)
            }
        }
    }
    /// 变焦（捏合手势驱动；1 = 广角）。UI 请求值粗限 1...16，manager 内按
    /// 设备 activeFormat.videoMaxZoomFactor 精确夹取（机型差异不进 UI 层）。
    @Published var zoomFactor: CGFloat = 1.0 {
        didSet { manager.setZoomFactor(zoomFactor) }
    }
    /// MetalFX 预览升采样（CAM-022，实验项）。默认关 = 与原链路逐位等价；
    /// 设备不支持时 manager/renderer 侧自动跳过（诚实降级）。
    @Published var fxUpscaleEnabled = false {
        didSet { renderer?.setFXUpscaleEnabled(fxUpscaleEnabled) }
    }

    // MARK: 双摄（CAM-021）

    /// 设备级双摄支持（A12+；UI 依此置灰开关）。
    let isDualCamSupported = CameraManager.isMultiCamSupported
    /// 双摄开关状态（会话重配成功后置位；失败保持原状并 errorMessage 明示）。
    @Published private(set) var dualCamEnabled = false
    /// PiP 画面选择（true = PiP 显示前摄、主画面为后摄；swap 互换）。
    @Published private(set) var pipShowsFront = true

    // MARK: 人像虚化（CAM-023；深度仅服务拍照路径）

    /// 深度能力（任意摄位有深度设备即可开；开启后当前摄位无深度会失败并明示）。
    let isPortraitBlurSupported = CameraManager.depthCapableDevice(for: .back) != nil
        || CameraManager.depthCapableDevice(for: .front) != nil
    @Published private(set) var portraitBlurEnabled = false
    /// f 值（0...1）：0 = 无虚化；对虚化半径线性单调。
    @Published var aperture: Double = 0.5

    func setPortraitBlurEnabled(_ enabled: Bool) {
        guard !isRecording, enabled != portraitBlurEnabled else { return }
        manager.setPortraitBlurEnabled(enabled) { [weak self] applied in
            guard let self else { return }
            if applied {
                self.portraitBlurEnabled = enabled
            } else {
                self.errorMessage = enabled
                    ? "人像虚化开启失败（当前摄位可能无景深能力，或与双摄冲突）"
                    : "人像虚化关闭失败"
            }
        }
    }

    func setDualCamEnabled(_ enabled: Bool) {
        guard !isRecording, enabled != dualCamEnabled else { return }
        guard isDualCamSupported || !enabled else { return }
        manager.setDualCamEnabled(enabled) { [weak self] applied in
            guard let self else { return }
            if applied {
                self.dualCamEnabled = enabled
                self.renderer?.setDualMode(enabled)
                if !enabled {
                    self.pipShowsFront = true
                    self.renderer?.setPiPShowsFront(true)
                }
            } else {
                self.errorMessage = enabled ? "双摄开启失败" : "双摄关闭失败"
            }
        }
    }

    /// 主画面与 PiP 互换（录制中锁定——WYSIWYG 合成锁语义）。
    func swapPiP() {
        guard dualCamEnabled, !isRecording else { return }
        pipShowsFront.toggle()
        renderer?.setPiPShowsFront(pipShowsFront)
    }
    /// 美体参数（CAM-025：瘦腰/长腿）。语义与美颜一致：预览即时生效；录制锁定。
    @Published var bodyReshape = BodyReshapeParams() {
        didSet { renderer?.setBodyReshape(bodyReshape) }
    }
    /// 美妆（CAM-026：唇/腮/眼影/眉/美瞳区域着色）。预览即时生效；录制锁定。
    @Published var makeup = MakeupParams() {
        didSet { renderer?.setMakeup(makeup) }
    }

    /// 对焦/曝光复位到连续自动（UI「自动」按钮）。
    func resetFocusAndExposure() {
        focusLensPosition = nil
        exposureBias = 0
        manager.resetFocusAndExposure()
    }

    // MARK: 引擎组件（渲染三件套共享同一 MTLDevice；Metal 不可用时为 nil，视图层兜底）

    let renderer: CameraPreviewRenderer?
    private let ciContext: CIContext?
    private let manager = CameraManager()
    /// CAM-011 检测桥（CAM-019 接入美颜区域化）：offer 在采集队列非阻塞，
    /// 检测降频 30Hz [E] + 忙丢弃；onResult 在检测队列写入 renderer.faceBoxes（锁）。
    /// ⚠️ 人脸框**单一真源 = renderer.faceBoxes**：预览 draw / 拍照 / 录制三路消费
    /// 读同一个 store。此前 ViewModel 自建了第二个 store，检测结果只写进它，
    /// 预览侧永远读不到 → 美颜整帧兜底（2026-10-07 真机「还是滤镜效果」反馈根因，
    /// CAM-019 修复轮；契约单测照不住装配层，见 pitfalls P86 候选）。
    private let detector = VisionDetector()
    /// 前摄检测桥（CAM-021 双摄 PiP 美颜）：与主检测桥同构，互不共享平滑状态
    ///（两路主体不同，交替喂同一检测器会破坏 One-Euro 帧间平滑）。
    private let frontDetector = VisionDetector()
    /// 录制器引用盒：帧回调在采集队列，**不得**触碰 MainActor 属性 —— 录制器
    /// 的启停经此线程安全中转（append 自身有锁，见 CameraRecorder）。
    private let recorderBox = RecorderBox()
    private var prepared = false

    init() {
        if let device = MTLCreateSystemDefaultDevice(),
           let queue = device.makeCommandQueue() {
            // CAM-018：显式 gamma sRGB 工作空间 —— 真机 kernel 输入域对齐
            // beauty_harness 的 σr 定标域（未标记 BGRA 实测 gamma 域）。
            // 默认线性域下皮肤边缘亮度差被放大约 1.5~2 倍 [E]，双边权重塌陷
            // → 磨皮逐帧沸腾/闪烁、保边失效（SPEC-CAM-018-019 §1.1）。
            // 滤镜观感基线可能随之变化，真机人工定案（TASK-CAM-018 风险栏）。
            let options: [CIContextOption: Any] = CGColorSpace(name: CGColorSpace.sRGB)
                .map { [.workingColorSpace: $0] } ?? [:]
            let context = CIContext(mtlDevice: device, options: options)
            ciContext = context
            let previewRenderer = CameraPreviewRenderer(ciContext: context, commandQueue: queue)
            renderer = previewRenderer
            // CAM-012：Metal 磨皮引擎注入（bundle 无 metallib 时静默走 SharedUI 默认实现）。
            BeautyKernel.installSharedSmoothingIfNeeded()
        } else {
            ciContext = nil
            renderer = nil
        }
        // ⚠️ 初始滤镜必须等**所有存储属性初始化完**再同步：init 里在 renderer
        //    赋值前访问 self.filter 会触发 phase-1 报错
        //    （'self' used in property access 'filter' before all stored properties are initialized）。
        renderer?.setFilter(filter)
        // 贴纸目录（CAM-014）：资产清单缺失/为空时 UI 隐藏入口。
        stickerCatalog = StickerCatalog.load()
        // CAM-019：检测结果 → 平滑后的人脸框（写入 renderer.faceBoxes 单一真源）。
        // onResult 在检测队列串行回调，FaceBoxStore 内加锁；weak detector 断开
        // detector → onResult → detector 环。renderer 为 nil（无 Metal）时不接检测：
        // wireCallbacks 不会 offer 帧，三路消费方也全部有 renderer 守卫。
        // CAM-013/014：同帧快照提取美型/贴纸锚点（关键点已在检测器侧平滑）。
        // CAM-024：检出宠物（有姿态）时提取双眼锚点——有脸优先人脸，无脸贴纸锚宠物。
        // CAM-025：人体四关节齐全时提取美体锚点。
        if let faceBoxes = renderer?.faceBoxes {
            // CAM-027：把皮肤语义蒙版装进美颜契约层（读同一 faceBoxes 的最新锚点）。
            // 不安装则 CameraBeauty 走 CAM-019 框级椭圆，逐位等价。
            PortraitSemantics.installSkinMask(faceBoxStore: faceBoxes)
            detector.onResult = { [faceBoxes, weak detector] snapshot in
                faceBoxes.update(with: snapshot.face?.box)
                faceBoxes.updateAnchors(snapshot.face.flatMap(CameraReshapeAnchors.init(face:)))
                faceBoxes.updateAnimalEyes(snapshot.animals.first.flatMap(StickerEyeAnchor.init(animal:)))
                faceBoxes.updateBodyAnchors(snapshot.body.flatMap(BodyReshapeAnchors.init(body:)))
                faceBoxes.updateMakeupAnchors(snapshot.face.flatMap(MakeupAnchors.init(face:)))
                if ProcessInfo.processInfo.environment["CQ_DEBUG_PROFILE"] == "1", let detector {
                    let ms = detector.lastDetectionDurationMs.map { String(format: "%.1f", $0) } ?? "nil"
                    print("cq.debug: face detect lastMs=\(ms) total=\(detector.totalDetections) failed=\(detector.totalFailed) dropped=\(detector.totalDroppedByRate)")
                }
            }
        }
        // CAM-021：前摄检测桥 → renderer.frontFaceBoxes（PiP 路单一真源，同主路纪律）。
        if let frontFaceBoxes = renderer?.frontFaceBoxes {
            frontDetector.onResult = { [frontFaceBoxes] snapshot in
                frontFaceBoxes.update(with: snapshot.face?.box)
                frontFaceBoxes.updateAnchors(snapshot.face.flatMap(CameraReshapeAnchors.init(face:)))
            }
        }
    }

    // MARK: 生命周期

    /// 进入相机页时调用：授权 → 配置 → 启动（幂等）。
    func prepare() {
        guard renderer != nil else { return }  // Metal 不可用：视图层已展示降级文案
        guard !prepared else {
            resumeIfNeeded()
            return
        }
        prepared = true
        CameraManager.requestAuthorization { [weak self] cameraGranted, micGranted in
            guard let self else { return }
            self.micAvailable = micGranted
            guard cameraGranted else {
                self.phase = .unauthorized
                return
            }
            self.wireCallbacks()
            self.manager.configureAndStart { [weak self] running in
                self?.phase = running ? .running : .preparing
                if !running {
                    self?.errorMessage = "相机启动失败（设备被占用或不存在）"
                }
                #if DEBUG
                if running { self?.runDeviceProbeIfRequested() }
                #endif
            }
        }
    }

    /// 退到后台由视图层调用（红线：后台不占相机资源）。
    func handleSceneInactive() {
        manager.stop()
    }

    /// 回到前台恢复。
    func resumeIfNeeded() {
        guard phase == .running || phase == .preparing else { return }
        manager.configureAndStart { [weak self] running in
            self?.phase = running ? .running : self?.phase ?? .preparing
        }
    }

    // MARK: 真机自动探针（DEBUG only；B-02 问卷机器侧取证，2026-10-11）
    //
    // CQ_CAM_PROBE=front：running 后切前摄 → 拍照（PNG 存 tmp，探针模式**跳过相册**
    // 避免权限弹窗阻塞自动化）→ 录 3s（mp4 落 tmp）。逐项 fputs 到 stderr
    // （devicectl launch --console 可见）；产物由机器侧 devicectl copy 拉回核验。

    #if DEBUG
    private var probeStarted = false

    private var probeActive: Bool {
        ProcessInfo.processInfo.environment["CQ_CAM_PROBE"] != nil
    }

    private func probeLog(_ text: String) {
        fputs("[cam-probe] \(text)\n", stderr)
        fflush(stderr)
    }

    /// P112 隔离实验：最小 AVAssetWriter（1080×1920 视频单轨、合成帧、脱离相机
    /// 会话）——startWriting 在此失败 = 系统级（mediaserverd/OS），成功 = 真实
    /// 录制上下文（文件 URL/尺寸/时序）问题。
    nonisolated private func standaloneWriterSmoke() {
        func smokeLog(_ text: String) {
            fputs("[cam-probe] smoke \(text)\n", stderr)
            fflush(stderr)
        }
        let mode = ProcessInfo.processInfo.environment["CQ_CAM_PROBE"] ?? ""
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer_smoke.mp4")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            smokeLog("writer init FAIL")
            return
        }
        let dims: (Int, Int) = (mode == "front") ? (1080, 1920) : (640, 480)
        // 变体开关（P112 二分）：CQ_SMOKE_VARIANT=C = 完全复刻真实 Recorder 构造
        //（realtime=true + adaptor 先建 + 色彩空间键）；A = 仅 realtime；缺省 = 全关。
        let variant = ProcessInfo.processInfo.environment["CQ_SMOKE_VARIANT"] ?? ""
        let realtime = (variant == "C" || variant == "A")
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dims.0, AVVideoHeightKey: dims.1,
        ])
        input.expectsMediaDataInRealTime = realtime
        writer.add(input)
        // adaptor 必须先于 startWriting 创建（之后创建直接抛 NSException——
        // "input has already started writing"，smoke 自身首轮踩过）。
        var sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: dims.0,
            kCVPixelBufferHeightKey as String: dims.1,
        ]
        if variant == "C" {
            // 毒性验证组：色键在源属性里 = iOS 26.6 startWriting 必炸（P112）
            sourceAttributes[kCVImageBufferCGColorSpaceKey as String] =
                CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes)
        smokeLog("adaptor pre-created (variant \(variant))")
        let started = writer.startWriting()
        smokeLog("startWriting=\(started) status=\(writer.status.rawValue)")
        guard started else {
            let e = writer.error as NSError?
            smokeLog("err=\(e?.domain ?? "nil")/\(e?.code ?? -1) \(e?.localizedDescription ?? "nil")")
            return
        }
        // append 的前置：必须先 startSession（缺它 = append 失败 → writer .failed
        // → 对 .failed 调 markAsFinished 抛异常——smoke 首轮崩溃真因）。
        writer.startSession(atSourceTime: CMTime(seconds: 0, preferredTimescale: 600))
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, dims.0, dims.1, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                            &pixelBuffer)
        if let pb = pixelBuffer {
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, 0x60, CVPixelBufferGetDataSize(pb))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let time = CMTime(seconds: 0, preferredTimescale: 600)
            adaptor.append(pb, withPresentationTime: time)
            smokeLog("append status=\(writer.status.rawValue)")
        }
        // markAsFinished 仅合法于 .writing（.failed 上调用抛异常——P110 同族）。
        if writer.status == .writing {
            input.markAsFinished()
        }
        writer.finishWriting {
            let ok = writer.status == .completed
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] ?? 0
            smokeLog("finish status=\(writer.status.rawValue) size=\(size) \(ok ? "PASS" : "FAIL")")
        }
    }

    func runDeviceProbeIfRequested() {
        guard !probeStarted, phase == .running,
              let mode = ProcessInfo.processInfo.environment["CQ_CAM_PROBE"] else { return }
        probeStarted = true
        if mode == "manual" {
            // 人工复现模式：不自动操作，仅开取证（用户手点录制/停止，日志给真相）。
            probeLog("manual mode: forensics on —— 请现在点录制，2 秒后点停止")
            return
        }
        probeLog("start mode=\(mode) position=\(position == .front ? "front" : "back")")
        // P112：smoke 挪到 detached 线程 + 2.5s 延迟——与真实录制同上下文
        //（非主线程、采集满负荷交付中）。若此时失败而主线程成功 = 上下文触发。
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            fputs("[cam-probe] smoke (detached, 2.5s) start\n", stderr)
            fflush(stderr)
            self?.standaloneWriterSmoke()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if mode == "front" {
                self.switchPosition()
                // 轮询等切换落地（switchPosition 是 sessionQueue 异步——固定睡
                // 1.2s 与队列忙闲竞态，B-02 曾读回 back 导致拍照/镜像判定全错位）。
                for _ in 0..<50 {
                    if self.position == .front { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                self.probeLog("switched position=\(self.position == .front ? "front" : "back")")
            }
            self.capturePhoto()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.probeLog("before startRecording")
            self.startRecording()
            self.probeLog("recording started")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.stopRecording()
            self.probeLog("recording stopped")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // B-02 用户实测复现：同一会话内连续第二段录制（首段后不重启 App）。
            if mode == "front" || mode == "double" {
                self.startRecording()
                self.probeLog("recording2 started")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.stopRecording()
                self.probeLog("recording2 stopped")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            // 产物回传：CQ_LOG_UPLOAD=host:port → HTTP PUT（WiFi 直传，绕开
            // devicectl 文件拷贝的不可靠——B-02 实测多次 0 该厂商）。
            if let endpoint = ProcessInfo.processInfo.environment["CQ_LOG_UPLOAD"] {
                let fm = FileManager.default
                let all = (try? fm.contentsOfDirectory(
                    at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
                let recordings = all.filter { $0.lastPathComponent.hasPrefix("cq_rec_") }
                let newestRecording = recordings.max { $0.lastPathComponent < $1.lastPathComponent }
                let photo = all.first { $0.lastPathComponent == "cam_probe_photo.png" }
                let newest = [newestRecording, photo].compactMap { $0 }
                for fileURL in newest {
                    guard let data = try? Data(contentsOf: fileURL) else { continue }
                    var request = URLRequest(url: URL(string: "http://\(endpoint)/\(fileURL.lastPathComponent)")!)
                    request.httpMethod = "PUT"
                    request.httpBody = data
                    let uploaded = try? await URLSession.shared.data(for: request)
                    self.probeLog("upload \(fileURL.lastPathComponent) \(data.count)B -> \(uploaded != nil ? "ok" : "fail")")
                }
            }
            self.probeLog("done")
        }
    }
    #endif

    // MARK: 操作

    func switchPosition() {
        let target: Position = (position == .back) ? .front : .back
        renderer?.faceBoxes.reset()   // 旧摄人脸框/平滑历史不污染新画面（CAM-019）
        zoomFactor = 1.0    // 切摄变焦重置（manager 侧同步归一；与系统相机惯例一致）
        manager.switchPosition(to: target.managerPosition) { [weak self] newPos in
            self?.position = (newPos == .front) ? .front : .back
        }
    }

    /// 界面方向变化（CAM-016，SPEC-CAM-001 v1.2 目标5）。
    /// 录制中锁定方向（与滤镜/美颜的开始锁定同语义）：AVAssetWriter 的像素缓冲
    /// 尺寸中途变化会导致 append 失败，录制流方向以开始瞬间为准（Spec v1.2 非目标）。
    func updateInterfaceOrientation(_ io: UIInterfaceOrientation) {
        guard !isRecording else { return }
        manager.setInterfaceOrientation(io)
    }

    /// 方向刷新入口（UIDevice.orientationDidChangeNotification 触发）。
    /// ⚠️ 该通知可能**早于** scene 提交转场（加速度计先 settle，界面后转），立即读
    /// `scene.interfaceOrientation` 可能拿到旧值 —— 故分 0 / 200 / 500ms 三次采样，
    /// 终值以后到的为准；manager 侧同值去重，重复采样是无害空转。
    func refreshInterfaceOrientation() {
        for delayNs in [0, 200_000_000, 500_000_000] {
            Task { @MainActor in
                if delayNs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayNs))
                }
                self.updateInterfaceOrientation(Self.currentInterfaceOrientation())
            }
        }
    }

    /// 当前前台 scene 的界面方向。读 scene 而非 UIDevice.orientation：后者有
    /// faceUp/flat 脏值，且设备方向 ≠ 界面方向（如页面锁向时）。读不到保守取竖屏。
    @MainActor
    static func currentInterfaceOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .interfaceOrientation ?? .portrait
    }

    func startRecording() {
        // phase == .running 前置要求 prepare 成功（renderer 非 nil）；显式解包仅为
        // 编译器——人脸框单一真源 = renderer.faceBoxes（CAM-019 修复轮）。
        guard phase == .running, !isRecording, recorderBox.get() == nil,
              let previewRenderer = renderer else { return }
        let faceBoxes = previewRenderer.faceBoxes
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cq_rec_\(Int(Date().timeIntervalSince1970 * 1000)).mp4")
        // 双摄（CAM-021）：录制源 = Renderer 合成器（主+PiP 两路完整链，与预览同序）；
        // 单摄走 Recorder 内联链路（锁定参数语义不变）。
        let dualComposer: ((CVImageBuffer, CMTime) -> CIImage)? = dualCamEnabled
            ? { buffer, time in previewRenderer.composeRecordingFrame(back: buffer, at: time) }
            : nil
        let recorder = CameraRecorder(
            outputURL: url,
            ciContext: ciContext!,
            preset: filter,       // 录制开始时锁定滤镜（WYSIWYG）
            beauty: beauty,       // 美颜同步锁定
            reshape: reshape,     // 美型同步锁定（CAM-013）
            bodyReshape: bodyReshape,  // 美体同步锁定（CAM-025）
            makeup: makeup,            // 美妆同步锁定（CAM-026）
            sticker: stickerCatalog.first { $0.id == selectedStickerID },  // 贴纸锁定（CAM-014）
            dualComposer: dualComposer,
            faceBoxes: faceBoxes, // 人脸框/锚点实时读取（蒙版跟随 + warp/贴纸跟随，WYSIWYG）
            withAudio: micAvailable
                && ProcessInfo.processInfo.environment["CQ_CAM_PROBE_NOAUDIO"] == nil)
        recorderBox.set(recorder)
        isRecording = true
        recordingStartedAt = Date()   // 录制计时 UI（View 端 TimelineView 渲染）
    }

    func stopRecording() {
        guard isRecording, let recorder = recorderBox.get() else { return }
        isRecording = false
        recordingStartedAt = nil
        recorderBox.set(nil)  // 先摘引用：后续帧不再写入（finish 中的余帧丢弃是诚实行为）
        recorder.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.recordedURL = url
                // 成品存相册一份（用户要求：直接在相册看效果；add-only 权限，
                // 不影响相册浏览导入的 read 权限语义）。
                self.saveRecordingToPhotos(url)
            case .failure(let error):
                self.errorMessage = "录制失败：\(error.localizedDescription)"
            }
        }
    }

    /// 放弃产物（不存相册不进编辑器）。
    func discardRecording() {
        if let url = recordedURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedURL = nil
    }

    /// 存相册（NSPhotoLibraryAddUsageDescription；只写不读，权限级别 addOnly）。
    func saveToPhotos() {
        guard let url = recordedURL else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self.errorMessage = "相册保存被拒绝（可在系统设置中开启）"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, error in
                Task { @MainActor in
                    if ok {
                        Self.photoLogger.info("拍照已入相册")
                        self.errorMessage = nil
                        self.recordedURL = nil  // 已入库，收起面板
                    } else {
                        Self.photoLogger.error("保存失败：\(error?.localizedDescription ?? "未知", privacy: .public)")
                        self.errorMessage = "保存失败：\(error?.localizedDescription ?? "未知")"
                    }
                }
            }
        }
    }

    // MARK: 拍照（CAM-003 追加）

    /// 拍照：原始帧 → 美颜/滤镜（与预览同一条 process 链，WYSIWYG）→ 存相册。
    func capturePhoto() {
        guard phase == .running, !isCapturing, let ciContext, renderer != nil else { return }
        isCapturing = true
        let failure = NSError(domain: "cq.camera", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "未取到照片数据"])
        // 拍照瞬间摄位快照（镜像连接判定用，P111 方向表）——闭包在采集队列跑，
        // 不能现场读 @Published。
        let photoMirrored = position == .front
        manager.capturePhoto(highResolution: highResPhoto,
                             depthDelivery: portraitBlurEnabled) { [weak self] buffer, depthData, metadata in
            // 回调在采集队列；单张照片的一次性处理在这里做，不抢主线程。
            // ciContext 线程安全，与预览/录制复用同一实例。
            // let（确定初始化）而非 var：Task 闭包是 @Sendable，捕获 var 直接编译错（P49）。
            let processed: Result<CGImage, Error>
            if let buffer {
                do {
                    var image = CIImage(cvPixelBuffer: buffer)
                    // P111：方向在照片元数据里（iOS 26 photoOutput 不旋转 buffer）。
                    // 摆正后再进效果链，否则美颜/贴纸的坐标全部错位。
                    //
                    // 有效方向表（iPhone 17 Pro / iOS 26.6 真机实证，B-02）：
                    //   连接不镜像（后摄）：metadata 6 → 有效 6（1080×1920 端正）
                    //   连接镜像    （前摄）：metadata 4 → 有效 6（直用 4 = 1920×1080 横躺）
                    // ⚠️ 镜像连接下 metadata 与有效值的关系未成公式（4→6 仅此一点实证；
                    //    横持场景未测）——未知组合按 metadata 原值走 + Warn（诚实降级 +
                    //    留现场日志），新增实测后扩表。
                    if let raw = metadata?[String(kCGImagePropertyOrientation)] {
                        let value: UInt32
                        if let n = raw as? NSNumber { value = n.uint32Value }
                        else if let str = raw as? String, let v = UInt32(str) { value = v }
                        else { value = 0 }
                        var effective = value
                        if photoMirrored && value == 4 {
                            effective = 6  // 前摄竖屏实测（B-02 探针三轮回放定案）
                        }
                        if let exif = CGImagePropertyOrientation(rawValue: effective),
                           effective != 0 {
                            image = image.oriented(exif)
                        }
                        if effective != value {
                            Self.photoLogger.warning("照片方向镜像修正 \(value, privacy: .public)→\(effective, privacy: .public)（P111 表）")
                        } else if value == 0 {
                            Self.photoLogger.warning("照片方向元数据缺失/不可解析，按原始缓冲出图（P111）")
                        }
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["CQ_CAM_PROBE"] != nil {
                            fputs("[cam-probe] vm orient raw=\(raw) value=\(value) effective=\(effective)"
                                  + " extent=\(image.extent)\n", stderr)
                            fflush(stderr)
                        }
                        #endif
                    }
                    if let renderer = self?.renderer {
                        image = renderer.process(image,
                                                 faces: renderer.faceBoxes.current(),
                                                 anchors: renderer.faceBoxes.currentAnchors(),
                                                 animalEyes: renderer.faceBoxes.currentAnimalEyes(),
                                                 bodyAnchors: renderer.faceBoxes.currentBodyAnchors())
                    }
                    // CAM-023：人像虚化（滤镜后、贴纸后语义保持——贴纸已在 process 内叠加，
                    // 虚化其上会糊掉贴纸 → 虚化置于 process 之前不可取；v1 口径 = 虚化
                    // 应用在整链之后（含贴纸），贴纸同为"画面主体"不参与景深，真机观感
                    // 定案后再决定是否调序）。深度缺失 = 跳过虚化（诚实降级）。
                    if let depthData, self?.portraitBlurEnabled == true {
                        image = PortraitBlur.composite(image, depthData: depthData,
                                                       aperture: self?.aperture ?? 0)
                    }
                    if let cgImage = ciContext.createCGImage(image, from: image.extent) {
                        processed = .success(cgImage)
                    } else {
                        Self.photoLogger.error("拍照：createCGImage 返回 nil")
                        throw NSError(domain: "cq.camera", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "照片处理失败"])
                    }
                } catch {
                    processed = .failure(error)
                }
            } else {
                processed = .failure(failure)
            }
            Task { @MainActor in
                guard let self else { return }
                self.isCapturing = false
                switch processed {
                case .success(let cgImage):
                    #if DEBUG
                    if self.probeActive {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("cam_probe_photo.png")
                        if let data = UIImage(cgImage: cgImage).pngData() {
                            try? data.write(to: url)
                        }
                        self.probeLog("photo saved \(cgImage.width)x\(cgImage.height) -> \(url.lastPathComponent)")
                        return
                    }
                    #endif
                    self.savePhotoToPhotos(cgImage)
                case .failure(let error):
                    self.errorMessage = "拍照失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func savePhotoToPhotos(_ image: CGImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self.errorMessage = "相册保存被拒绝（可在系统设置中开启）"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(
                    from: UIImage(cgImage: image))
            } completionHandler: { ok, error in
                Task { @MainActor in
                    if ok {
                        Self.photoLogger.info("拍照已入相册")
                        self.errorMessage = nil
                    } else {
                        Self.photoLogger.error("拍照保存失败：\(error?.localizedDescription ?? "未知", privacy: .public)")
                        self.errorMessage = "保存失败：\(error?.localizedDescription ?? "未知")"
                    }
                }
            }
        }
    }

    /// 录制产物存相册（PHPhotoLibrary add-only；与拍照同一权限面）。
    /// 失败不吞不崩：errorMessage 提示，tmp 原件保留（编辑器入口仍可用）。
    private func saveRecordingToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self.errorMessage = "相册保存被拒（系统设置中开启后，下次录制生效）"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, error in
                Task { @MainActor in
                    if ok {
                        Self.photoLogger.info("录制已存相册")
                    } else {
                        Self.photoLogger.error("录制存相册失败：\(error?.localizedDescription ?? "未知", privacy: .public)")
                        self.errorMessage = "存相册失败：\(error?.localizedDescription ?? "未知")（tmp 原件仍在，可进编辑器）"
                    }
                }
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: 帧接线（回调在采集队列；只做转发，不做主线程跳转）

    private func wireCallbacks() {
        guard let renderer else { return }
        // 捕获非隔离引用（renderer / recorderBox 局部化，不捕获 self：既满足
        // 显式捕获要求，又避免 manager → 闭包 → self 的保留环）；闭包体内
        // 不触碰 MainActor 状态。
        let recorderBox = self.recorderBox
        let detector = self.detector
        let frontDetector = self.frontDetector
        #if DEBUG
        nonisolated(unsafe) var probeFrameCount = 0
        #endif
        manager.onVideoFrame = { buffer, pts in
            #if DEBUG
            probeFrameCount += 1
            if probeFrameCount % 60 == 0 {
                fputs("[cam-probe] frames flowing N=\(probeFrameCount)\n", stderr)
                fflush(stderr)
            }
            #endif
            renderer.frameSlot.push(buffer)      // 预览（latest-wins）
            detector.offer(buffer, at: pts)      // 检测（内部降频+忙丢弃，永不阻塞采集）
            recorderBox.get()?.appendVideo(sourceBuffer: buffer, at: pts)  // 录制
        }
        // CAM-021：前摄帧（仅双摄有流）→ 前帧槽 + 前检测桥；录制由后摄回调驱动，
        // 前摄画面经 Renderer 合成器取 latest（见 startRecording）。
        manager.onFrontVideoFrame = { buffer, pts in
            renderer.frontFrameSlot.push(buffer)
            frontDetector.offer(buffer, at: pts)
        }
        manager.onAudioBuffer = { sampleBuffer in
            recorderBox.get()?.appendAudio(sampleBuffer: sampleBuffer)
        }
    }
}

// MARK: - 录制器引用盒（线程安全）

private final class RecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CameraRecorder?

    func get() -> CameraRecorder? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: CameraRecorder?) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
