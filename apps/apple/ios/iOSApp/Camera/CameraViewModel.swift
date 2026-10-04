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
import Photos
import SharedUI

@MainActor
final class CameraViewModel: ObservableObject {

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
    /// 最近一次录制产物（非 nil 时相机页展示「存相册/去编辑/放弃」面板）。
    @Published private(set) var recordedURL: URL?
    @Published private(set) var errorMessage: String?

    // MARK: 引擎组件（渲染三件套共享同一 MTLDevice；Metal 不可用时为 nil，视图层兜底）

    let renderer: CameraPreviewRenderer?
    private let ciContext: CIContext?
    private let manager = CameraManager()
    /// 录制器引用盒：帧回调在采集队列，**不得**触碰 MainActor 属性 —— 录制器
    /// 的启停经此线程安全中转（append 自身有锁，见 CameraRecorder）。
    private let recorderBox = RecorderBox()
    private var prepared = false

    init() {
        if let device = MTLCreateSystemDefaultDevice(),
           let queue = device.makeCommandQueue() {
            let context = CIContext(mtlDevice: device)
            ciContext = context
            let previewRenderer = CameraPreviewRenderer(ciContext: context, commandQueue: queue)
            previewRenderer.setFilter(filter)
            renderer = previewRenderer
        } else {
            ciContext = nil
            renderer = nil
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

    // MARK: 操作

    func switchPosition() {
        let target: Position = (position == .back) ? .front : .back
        manager.switchPosition(to: target.managerPosition) { [weak self] newPos in
            self?.position = (newPos == .front) ? .front : .back
        }
    }

    func startRecording() {
        guard phase == .running, !isRecording, recorderBox.get() == nil else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cq_rec_\(Int(Date().timeIntervalSince1970 * 1000)).mp4")
        let recorder = CameraRecorder(
            outputURL: url,
            ciContext: ciContext!,
            preset: filter,       // 录制开始时锁定滤镜（WYSIWYG）
            beauty: beauty,       // 美颜同步锁定
            withAudio: micAvailable)
        recorderBox.set(recorder)
        isRecording = true
    }

    func stopRecording() {
        guard isRecording, let recorder = recorderBox.get() else { return }
        isRecording = false
        recorderBox.set(nil)  // 先摘引用：后续帧不再写入（finish 中的余帧丢弃是诚实行为）
        recorder.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.recordedURL = url
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
                        self.errorMessage = nil
                        self.recordedURL = nil  // 已入库，收起面板
                    } else {
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
        manager.capturePhoto { [weak self] buffer in
            // 回调在采集队列；单张照片的一次性处理在这里做，不抢主线程。
            // ciContext 线程安全，与预览/录制复用同一实例。
            var processed: Result<CGImage, Error> = .failure(failure)
            if let buffer {
                do {
                    var image = CIImage(cvPixelBuffer: buffer)
                    if let renderer = self?.renderer {
                        image = renderer.process(image)
                    }
                    if let cgImage = ciContext.createCGImage(image, from: image.extent) {
                        processed = .success(cgImage)
                    } else {
                        throw NSError(domain: "cq.camera", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "照片处理失败"])
                    }
                } catch {
                    processed = .failure(error)
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.isCapturing = false
                switch processed {
                case .success(let cgImage):
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
                        self.errorMessage = nil
                    } else {
                        self.errorMessage = "保存失败：\(error?.localizedDescription ?? "未知")"
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
        // 捕获非隔离引用（renderer / recorderBox），闭包体内不触碰 MainActor 状态。
        manager.onVideoFrame = { buffer, pts in
            renderer.frameSlot.push(buffer)      // 预览（latest-wins）
            recorderBox.get()?.appendVideo(sourceBuffer: buffer, at: pts)  // 录制
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
