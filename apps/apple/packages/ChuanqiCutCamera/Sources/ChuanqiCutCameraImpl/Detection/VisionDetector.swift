// VisionDetector — Vision 系统能力桥（CAM-011，ADR-0014：iOS 原生功能域）
//
// 能力范围（RESEARCH-002 §4）：人脸关键点（76 点级）+ 头部姿态角、人体姿态
// （iOS 14+，19 关节）、动物检测（猫/狗物种，iOS 14+ VNRecognizeAnimalsRequest
// —— 比 DetectAnimalsRequest 多物种标签，贴纸选择需要）、动物姿态（iOS 17+，
// @available 门控，低版本如实无 pose，不做假能力）。
//
// 线程模型（与 CameraManager/CameraRenderer 同纪律）：
//   - offer() 在**采集队列**调用：锁内做降频闸门 + 忙检查，异步转投检测队列，
//     **永不等待** —— 检测再慢也只会丢帧，不会拖住采集/渲染（三队列互不阻塞）。
//   - 检测在**专用串行队列**执行；同一时刻最多一帧在检（busy 信号量，
//     latest-wins：检测中到来的新帧直接丢弃）。
//   - onResult 在**检测队列**回调：只带归一化数据，不持像素缓冲；
//     消费方（013 warp / 014 贴纸）自行决定跨线程方式。
//   - 平滑状态只在检测队列触碰（队列独占，无锁）；配置与诊断计数跨线程，
//     锁保护。
//
// 消费契约：观测结构见 FaceObservation.swift（origin 左上归一化坐标）。
// 单主脸 / 单主体策略：B 期特效只服务主目标（最大框人脸 / 最高置信度人体），
// 多目标留 C 期按需扩展。

import CoreMedia
import CoreVideo
import Foundation
import Vision

final class VisionDetector: @unchecked Sendable {

    // MARK: 配置（主线程写 / 检测队列读，锁保护）

    private let configLock = NSLock()
    /// 检测降频上限（Hz）。2026-10-07 提频 15→30（传哲：贴纸/美型「慢半拍」）——
    /// 检测与采集/渲染队列完全解耦（offer 非阻塞 + 忙丢弃），提频**不影响预览帧率**，
    /// 代价是检测开销 ×2（30Hz ≈ 6-15% ANE/CPU 份额 [E]），功耗真机对账后定频。
    private var _detectionHz: Double = 30.0
    /// 检测降频上限（Hz）。下限 1（防 0 除），上限 60（无意义高于帧率）。
    var detectionHz: Double {
        get { configLock.lock(); defer { configLock.unlock() }; return _detectionHz }
        set { configLock.lock(); _detectionHz = min(max(newValue, 1), 60); configLock.unlock() }
    }

    private var _smoothingStrength: Double = 0.5   // [E]，随美颜面板（CAM-013 接 UI）
    /// 关键点帧间平滑强度 0...1（0 = 关）。语义见 SharedUI KeypointSmoothingParams。
    var smoothingStrength: Double {
        get { configLock.lock(); defer { configLock.unlock() }; return _smoothingStrength }
        set { configLock.lock(); _smoothingStrength = min(max(newValue, 0), 1); configLock.unlock() }
    }

    /// 单点置信度低于该值按缺失处理（dropout → 平滑层保持上一帧）[E]。
    private let pointConfidenceFloor: Float = 0.3

    // MARK: 输出（检测队列回调）

    /// 检测队列回调；无检测价值（无人脸/人体/动物）时也会回调空快照——
    /// 消费方借此得知「目标离开画面」以复位状态。
    var onResult: ((DetectionSnapshot) -> Void)?

    // MARK: 诊断埋点（真机检测耗时入 baselines 的数据源；锁保护）

    private var _totalDetections: UInt64 = 0
    private var _totalFailed: UInt64 = 0
    private var _totalDroppedByRate: UInt64 = 0
    private var _lastDetectionDurationMs: Double?
    private var _lastErrorMessage: String?

    var totalDetections: UInt64 {
        configLock.lock(); defer { configLock.unlock() }
        return _totalDetections
    }
    var totalFailed: UInt64 {
        configLock.lock(); defer { configLock.unlock() }
        return _totalFailed
    }
    var totalDroppedByRate: UInt64 {
        configLock.lock(); defer { configLock.unlock() }
        return _totalDroppedByRate
    }
    /// 最近一次成功检测耗时（毫秒）。nil = 尚未检测。
    var lastDetectionDurationMs: Double? {
        configLock.lock(); defer { configLock.unlock() }
        return _lastDetectionDurationMs
    }
    var lastErrorMessage: String? {
        configLock.lock(); defer { configLock.unlock() }
        return _lastErrorMessage
    }

    // MARK: 状态

    private let queue = DispatchQueue(label: "cq.camera.detection")
    private let stateLock = NSLock()
    private var busy = false                    // stateLock 保护
    private var lastPtsSeconds: Double?         // stateLock 保护（降频闸门）
    // 平滑状态：检测队列独占，无锁
    private var prevFaceFlat: [CGPoint?]?
    private var prevBodyFlat: [CGPoint?]?
    private var prevAnimalPoseFlat: [CGPoint?]?

    // MARK: 帧入口

    /// 采集队列调用（CameraManager.onVideoFrame 的消费口）。非阻塞：
    /// 降频闸门（PTS 间隔 ≥ 1/Hz）+ 忙检查都不过 → 丢弃（latest-wins），
    /// 通过 → 异步转检测队列。buffer 由闭包持有至检测完成，无跨帧缓冲池。
    func offer(_ pixelBuffer: CVImageBuffer, at pts: CMTime) {
        let seconds = pts.seconds
        guard seconds.isFinite else { return }
        let minInterval = 1.0 / detectionHz   // 先取配置，避免双锁嵌套
        stateLock.lock()
        if busy || (lastPtsSeconds.map { seconds - $0 < minInterval } ?? false) {
            _totalDroppedByRate &+= 1
            stateLock.unlock()
            return
        }
        lastPtsSeconds = seconds
        busy = true
        stateLock.unlock()
        // CVImageBuffer 是 CF 类型、不 Sendable。依据：闭包**强捕获**使其引用计数
        // 不归零，采集输出不会把它回收进 pool；detect 全程只读像素内容。
        nonisolated(unsafe) let frame = pixelBuffer
        queue.async { [weak self] in
            self?.detect(frame, ptsSeconds: seconds, pts: pts)
        }
    }

    // MARK: 检测（检测队列）

    private func detect(_ pixelBuffer: CVImageBuffer, ptsSeconds: Double, pts: CMTime) {
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            configLock.lock()
            _lastDetectionDurationMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
            configLock.unlock()
            stateLock.lock()
            busy = false
            stateLock.unlock()
        }

        // 单次 handler 跑全部请求（一次图像分析，Vision 内部共享预处理）。
        // 帧已被 connection 转成竖屏，按 .up 处理（真机冒烟校验项，见任务卡）。
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let faceRequest = VNDetectFaceLandmarksRequest()
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let animalRequest = VNRecognizeAnimalsRequest()
        var requests: [VNRequest] = [faceRequest, bodyRequest, animalRequest]

        // 动物姿态 iOS 17+：可用则加入（门控，不做假能力）。
        // 类型引用一律经基类 VNRequest/VNObservation（iOS 17 专属类型不能出现在
        // 无门控的作用域），具体化在 convertAnimals 的门控分支里做。
        var animalPoseRequestRef: VNRequest?
        if #available(iOS 17.0, *) {
            let poseRequest = VNDetectAnimalBodyPoseRequest()
            requests.append(poseRequest)
            animalPoseRequestRef = poseRequest
        }

        do {
            try handler.perform(requests)
        } catch {
            configLock.lock()
            _totalFailed &+= 1
            _lastErrorMessage = "Vision perform: \(error.localizedDescription)"
            configLock.unlock()
            return
        }

        var face = convertFace(faceRequest.results)
        var body = convertBody(bodyRequest.results)
        var animals = convertAnimals(animalRequest.results,
                                     poseResults: animalPoseRequestRef?.results ?? [])

        // 帧间平滑（SharedUI 纯函数；状态在检测队列独占）。
        let params = KeypointSmoothingParams(strength: smoothingStrength)

        if let currentFace = face {
            let flat = smoothKeypoints(previous: prevFaceFlat,
                                       current: currentFace.flattenedPoints(), params: params)
            prevFaceFlat = flat
            face = currentFace.replacing(flattened: flat)
        } else {
            prevFaceFlat = nil   // 目标离开画面：复位，重现时不带旧历史
        }

        if let currentBody = body {
            let flat = smoothKeypoints(previous: prevBodyFlat,
                                       current: currentBody.flattenedPoints(), params: params)
            prevBodyFlat = flat
            body = currentBody.replacing(flattened: flat)
        } else {
            prevBodyFlat = nil
        }

        // 动物姿态平滑只覆盖首只动物（贴纸锚定目标；多宠物场景待 C 期）。
        if !animals.isEmpty, animals[0].pose != nil {
            let ordered = AnimalJoint.allCases.map { animals[0].pose?[$0] }
            let flat = smoothKeypoints(previous: prevAnimalPoseFlat, current: ordered,
                                       params: params)
            prevAnimalPoseFlat = flat
            var pose: [AnimalJoint: CGPoint] = [:]
            for (index, joint) in AnimalJoint.allCases.enumerated() where index < flat.count {
                if let p = flat[index] {
                    pose[joint] = p
                }
            }
            animals[0].pose = pose
        } else {
            prevAnimalPoseFlat = nil
        }

        let snapshot = DetectionSnapshot(pts: pts, face: face, body: body, animals: animals)
        configLock.lock()
        _totalDetections &+= 1
        configLock.unlock()
        onResult?(snapshot)
    }

    // MARK: Vision → 中性观测转换

    /// 单主脸策略：取框面积最大者。landmarks 缺失（罕见）则整脸跳过——
    /// 无关键点的人脸对 warp/贴纸无消费价值，不伪造空观测。
    private func convertFace(_ observations: [VNFaceObservation]?) -> FaceObservation? {
        guard let main = observations?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height <
            $1.boundingBox.width * $1.boundingBox.height
        }), let landmarks = main.landmarks else {
            return nil
        }
        let box = main.boundingBox   // Vision 归一化（origin 左下）
        func region(_ points: [CGPoint]) -> LandmarkRegion {
            LandmarkRegion(points: points.map { point(inBox: box, visionPoint: $0) })
        }
        return FaceObservation(
            contour: region(landmarks.faceContour?.normalizedPoints ?? []),
            leftEyebrow: region(landmarks.leftEyebrow?.normalizedPoints ?? []),
            rightEyebrow: region(landmarks.rightEyebrow?.normalizedPoints ?? []),
            leftEye: region(landmarks.leftEye?.normalizedPoints ?? []),
            rightEye: region(landmarks.rightEye?.normalizedPoints ?? []),
            nose: region(landmarks.nose?.normalizedPoints ?? []),
            noseCrest: region(landmarks.noseCrest?.normalizedPoints ?? []),
            medianLine: region(landmarks.medianLine?.normalizedPoints ?? []),
            outerLips: region(landmarks.outerLips?.normalizedPoints ?? []),
            innerLips: region(landmarks.innerLips?.normalizedPoints ?? []),
            leftPupil: landmarks.leftPupil?.normalizedPoints.first.map({ point(inBox: box, visionPoint: $0) }),
            rightPupil: landmarks.rightPupil?.normalizedPoints.first.map({ point(inBox: box, visionPoint: $0) }),
            box: visionRectToImageNormalized(box),
            yaw: main.yaw?.doubleValue,
            pitch: main.pitch?.doubleValue,
            roll: main.roll?.doubleValue,
            confidence: Double(main.confidence))
    }

    /// 区域点在 Vision 空间合成到整图归一化（先入框内插值，再统一翻转+夹取）。
    private func point(inBox box: CGRect, visionPoint p: CGPoint) -> CGPoint {
        visionPointToImageNormalized(CGPoint(x: box.minX + p.x * box.width,
                                             y: box.minY + p.y * box.height))
    }

    /// 单主体策略：置信度最高的一组。
    private func convertBody(_ observations: [VNHumanBodyPoseObservation]?) -> BodyPoseObservation? {
        guard let main = observations?.max(by: { $0.confidence < $1.confidence }),
              let recognized = try? main.recognizedPoints(.all) else {
            return nil
        }
        var joints: [BodyJoint: CGPoint] = [:]
        for (name, point) in recognized {
            guard point.confidence >= pointConfidenceFloor,
                  let joint = bodyJoint(name) else { continue }
            joints[joint] = visionPointToImageNormalized(point.location)
        }
        return joints.isEmpty ? nil : BodyPoseObservation(joints: joints)
    }

    private func bodyJoint(_ name: VNHumanBodyPoseObservation.JointName) -> BodyJoint? {
        switch name {
        case .nose: return .nose
        case .leftEye: return .leftEye
        case .rightEye: return .rightEye
        case .leftEar: return .leftEar
        case .rightEar: return .rightEar
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        case .neck: return .neck
        case .root: return .root
        default: return nil
        }
    }

    /// 物种取标签最高分类；只认 Cat/Dog（VNRecognizeAnimalsRequest 识别边界，
    /// RESEARCH-002 §4）。结果类型经 SDK 头文件核实为 VNRecognizedObjectObservation
    /// （带 labels），无 VNAnimalObservation 类。
    private func convertAnimals(_ observations: [VNRecognizedObjectObservation]?,
                                poseResults: [VNObservation]) -> [AnimalObservation] {
        var result: [AnimalObservation] = (observations ?? []).compactMap { observation in
            guard let species = species(observation) else { return nil }
            return AnimalObservation(
                species: species,
                box: visionRectToImageNormalized(observation.boundingBox),
                confidence: Double(observation.confidence),
                pose: nil)
        }
        result.sort { $0.confidence > $1.confidence }

        // 动物姿态（iOS 17+）：类型引用与常量都在门控分支内。
        // 单姿态观测直接锚到首只动物；多姿态匹配（框-姿态配对）待 C 期，本卡不猜。
        if !result.isEmpty, #available(iOS 17.0, *) {
            for observation in poseResults {
                guard let poseObservation = observation as? VNAnimalBodyPoseObservation,
                      let recognized = try? poseObservation.recognizedPoints(.all) else {
                    continue
                }
                var pose: [AnimalJoint: CGPoint] = [:]
                for (name, point) in recognized {
                    guard point.confidence >= pointConfidenceFloor,
                          let joint = animalJoint(name) else { continue }
                    pose[joint] = visionPointToImageNormalized(point.location)
                }
                if !pose.isEmpty {
                    result[0].pose = pose
                    break
                }
            }
        }
        return result
    }

    private func species(_ observation: VNRecognizedObjectObservation) -> AnimalSpecies? {
        for label in observation.labels {
            let identifier = label.identifier.lowercased()
            if identifier.contains("cat") { return .cat }
            if identifier.contains("dog") { return .dog }
        }
        return nil
    }

    @available(iOS 17.0, *)
    private func animalJoint(_ name: VNAnimalBodyPoseObservation.JointName) -> AnimalJoint? {
        switch name {
        case .leftEye: return .leftEye
        case .rightEye: return .rightEye
        case .leftEarTop: return .leftEarTop
        case .rightEarTop: return .rightEarTop
        case .nose: return .nose
        default: return nil   // B 期只取头部 5 关节（见 AnimalJoint 注释）
        }
    }
}
