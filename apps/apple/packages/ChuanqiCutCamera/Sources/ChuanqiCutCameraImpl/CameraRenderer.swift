// CameraRenderer — 相机帧槽 + Core Image 预览渲染（CAM-003，ADR-0014）
//
// 链路：CVPixelBuffer → CIImage → 美颜 → 美型 warp → 滤镜 → 贴纸 → CI 渲进
// **自建中间纹理** → 显式 UV 渲染 pass（行序补偿 + aspect-fill）→ drawable → present。
// 全程 GPU（CIContext 默认 Metal 后端），无 CPU 读回（RESEARCH-002 §5 红线）。
//
// ⚠️ 为什么需要「中间纹理」（P60，CAM-014/015）：CI 直写 drawable 时内部构造
//    CIRenderDestination 要求 usage 含 ShaderWrite，而 framebufferOnly drawable 只有
//    renderTarget → destination nil → **静默黑屏 + 帧计数假绿**（render 非 throws）。
//
// ⚠️ 为什么中间纹理 → drawable 是「渲染 pass」而不是 blit（P65 翻案 + CAM-016）：
//    1) P65（2026-10-05 真机校验层实证）：Metal 规范**禁止对 framebufferOnly 纹理
//       blit**（源/目标都禁；该纹理只允许当 render pass 的 colorAttachment）。
//       P60 时期记的「blit 写入合法（实测无 error）」是无校验层运行的未定义行为放行，
//       DEBUG Metal API Validation / GPU 抓帧下第一帧 SIGABRT。当时临时用
//       framebufferOnly = false 续命（CAM-015 二段，已翻案登记）。
//    2) CAM-016（本卡）：blit 没有 UV 可言 —— 既做不了行序补偿（传哲真机实证预览
//       **上下颠倒**），也做不了横竖屏 aspect-fill（SPEC-CAM-001 v1.2 目标5）。
//       换显式 UV 渲染 pass：屏幕上边采样哪个 v 由**带符号 vScale** 一个数决定，
//       行序补偿与铺满一并解决；drawable 恢复 framebufferOnly = true（colorAttachment
//       正是它唯一合法的用法；编辑器预览 PreviewFrameRenderer 同形态，真机已验证）。
//    ⚠️ 行序常数 `ciWritesBottomUp` 是由真机现象反推的假设（macOS 探针不等价，
//       CI 的 iOS 行序未直接实证），真机一验若反向，改这一个值即可。
//
// 线程模型：
//   - CameraFrameSlot：采集队列写 / MTKView 渲染线程读，锁保护，latest-wins
//     （不排队、不丢「最新」语义，渲染慢时自然重复渲染同帧）。
//   - 滤镜切换：主线程写 / 渲染线程读，锁保护。
//   - CIContext 线程安全，可被预览渲染线程与录制队列共享。

import CoreImage
import Foundation
import Metal
import MetalKit
import os

// MARK: - 帧槽（latest-wins）

final class CameraFrameSlot {

    private let lock = NSLock()
    private var latestBuffer: CVImageBuffer?

    /// 采集队列调用。保留最新帧（不取走 —— 渲染线程可能以低于采集的频率消费）。
    func push(_ buffer: CVImageBuffer) {
        lock.lock()
        latestBuffer = buffer
        lock.unlock()
    }

    /// 渲染线程调用。返回当前最新帧（可为 nil = 尚无帧）。
    func latest() -> CVImageBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestBuffer
    }

    /// 停止采集时清引用，避免持有最后一帧的缓冲。
    func clear() {
        lock.lock()
        latestBuffer = nil
        lock.unlock()
    }
}

// MARK: - 人脸框槽（CAM-019）

/// 检测队列写 / 渲染与录制线程读，锁保护，latest-wins（同 CameraFrameSlot 纪律）。
/// 语义对齐 CameraBeauty.apply 契约：nil = 尚无检测数据（直通，无算法即无效果）；
/// [] = 检测过但无脸（直通）；非空 = 平滑后的图像归一化人脸框（origin 左上）。
final class FaceBoxStore {

    private let lock = NSLock()
    private var latest: [CGRect]?
    /// 美型/贴纸锚点（CAM-013/014）：与框同帧快照，检测队列写 / 渲染与录制读。
    /// 关键点已在检测器侧平滑（CAM-011），此处不做二次平滑。
    private var latestAnchors: CameraReshapeAnchors?
    /// 宠物双眼锚点（CAM-024）：检出动物（有姿态）时写入；与人脸锚点互斥消费
    /// （有脸优先人脸），优先级在消费侧（renderer/Recorder）而非存储层。
    private var latestAnimalEyes: StickerEyeAnchor?
    /// 美体锚点（CAM-025）：人体四关节（双肩/双髋）齐全时写入，缺任一 = nil
    /// （该帧美体跳过；半身几何不可信，不做部分形变）。
    private var latestBodyAnchors: BodyReshapeAnchors?
    /// 美妆锚点（CAM-026）：区域关键点集合（唇/眉/眼/瞳），无脸 = nil（美妆直通）。
    private var latestMakeupAnchors: MakeupAnchors?
    /// 框帧间平滑状态：只在检测队列触碰（VisionDetector.onResult 串行回调），无锁。
    private var previousMain: CGRect?

    /// 检测队列调用。box 为图像归一化坐标（CAM-011 契约）；nil = 本帧无脸
    /// （同时清锚点：无脸帧美颜直通、美型/贴纸跳过，三路语义一致）。
    func update(with normalizedBox: CGRect?) {
        lock.lock()
        defer { lock.unlock() }
        guard let box = normalizedBox else {
            latest = []
            latestAnchors = nil
            previousMain = nil   // 目标离开画面：复位，重现时不带旧历史
            return
        }
        // 框平滑：检测 15Hz 降频 + 跳帧场景下抑制蒙版抖动（羽化兜底，参数 [E]）。
        let smoothed = FaceMask.smoothedBox(previous: previousMain, current: box,
                                            params: KeypointSmoothingParams(strength: 0.5))
        previousMain = smoothed
        latest = [smoothed]
    }

    /// 检测队列调用：与 update(with:) 同帧成对写入（CAM-013/014 锚点）。
    func updateAnchors(_ anchors: CameraReshapeAnchors?) {
        lock.lock()
        defer { lock.unlock() }
        latestAnchors = anchors
    }

    /// 检测队列调用：宠物双眼锚点（CAM-024；姿态缺失传 nil = 该帧跳过宠物贴纸）。
    func updateAnimalEyes(_ eyes: StickerEyeAnchor?) {
        lock.lock()
        defer { lock.unlock() }
        latestAnimalEyes = eyes
    }

    /// 检测队列调用：美体锚点（CAM-025；四关节齐全才非 nil）。
    func updateBodyAnchors(_ anchors: BodyReshapeAnchors?) {
        lock.lock()
        defer { lock.unlock() }
        latestBodyAnchors = anchors
    }

    /// 检测队列调用：美妆锚点（CAM-026；无脸传 nil）。
    func updateMakeupAnchors(_ anchors: MakeupAnchors?) {
        lock.lock()
        defer { lock.unlock() }
        latestMakeupAnchors = anchors
    }

    /// 渲染/录制线程调用。
    func current() -> [CGRect]? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// 渲染/录制线程调用（CAM-013/014）。
    func currentAnchors() -> CameraReshapeAnchors? {
        lock.lock()
        defer { lock.unlock() }
        return latestAnchors
    }

    /// 渲染/录制线程调用（CAM-024）。
    func currentAnimalEyes() -> StickerEyeAnchor? {
        lock.lock()
        defer { lock.unlock() }
        return latestAnimalEyes
    }

    /// 渲染/录制线程调用（CAM-025）。
    func currentBodyAnchors() -> BodyReshapeAnchors? {
        lock.lock()
        defer { lock.unlock() }
        return latestBodyAnchors
    }

    /// 渲染/录制线程调用（CAM-026）。
    func currentMakeupAnchors() -> MakeupAnchors? {
        lock.lock()
        defer { lock.unlock() }
        return latestMakeupAnchors
    }

    /// 前后摄切换等场景清状态：旧摄人脸框不污染新画面（清后 nil=直通）。
    func reset() {
        lock.lock()
        latest = nil
        latestAnchors = nil
        latestAnimalEyes = nil
        latestBodyAnchors = nil
        latestMakeupAnchors = nil
        previousMain = nil
        lock.unlock()
    }
}

/// 帧统计（`@unchecked Sendable`：跨 Metal 完成线程读写，内部锁保护）。
///
/// 单独成类是为了让 `@Sendable` 的完成回调**捕获它而不是捕获 renderer**（P49 同族），
/// 否则 Swift 6 严格并发会告警（"capture of 'self' with non-Sendable type"）。
private final class FrameStats: @unchecked Sendable {

    private let lock = NSLock()
    private var succeededValue: UInt64 = 0
    private var failedValue: UInt64 = 0

    /// 记录一帧结果，返回累加后的快照（避免回调后续再取一次、读到被其他帧推进的值）。
    func record(success: Bool) -> (succeeded: UInt64, failed: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if success {
            succeededValue &+= 1
        } else {
            failedValue &+= 1
        }
        return (succeededValue, failedValue)
    }

    var succeeded: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return succeededValue
    }

    var failed: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return failedValue
    }
}

// MARK: - aspect-fill 渲染 pass（CAM-016）

/// 采样窗参数（逐帧 CPU 计算，`setVertexBytes` 注入）。
/// u/vScale = 可见源窗口的半宽/半高归一值，**v 带符号**：负号 = v 轴翻转
/// （CI 行序 top-down 时的补偿）；正号 = CI bottom-up（图像底行在纹理 row0）。
/// 布局必须与下方 MSL 的 `FillUniforms` 逐字节一致。
private struct FillUniforms {
    var uScale: Float
    var vScale: Float
}

/// 顶点几何与 uv 映射**与 SharedUI PreviewFrameRenderer 同约定**（全屏大三角形、
/// 屏幕可见区恰好 t∈[0,1]²），差异仅在：uv 经 uniforms 缩放（aspect-fill 采样窗）
/// 并带 v 轴符号（行序补偿）。两侧不得单方面改约定。
private enum FillShader {

    /// true = 假设 CI 渲进 Metal 纹理是 bottom-up（图像底行 → 纹理 row0）。
    /// 依据：CAM-015 时期「blit 行序直拷 + drawable row0=屏幕顶（编辑器链路已证）」
    /// 下真机预览上下颠倒 ⇒ 反推 CI 写入行序与呈现相反。真机一验若反向改 false。
    static let ciWritesBottomUp = true

    static let mslSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct FillUniforms { float uScale; float vScale; };
        struct VOut {
            float4 position [[position]];
            float2 uv;
        };
        vertex VOut cq_camera_fill_vertex(uint vid [[vertex_id]],
                                          constant FillUniforms &u [[buffer(0)]]) {
            float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            float2 t[3]   = { float2(0.0, 0.0), float2(2.0, 0.0), float2(0.0, 2.0) };
            VOut o;
            o.position = float4(pos[vid], 0.0, 1.0);
            o.uv = float2(0.5 + (t[vid].x - 0.5) * u.uScale,
                          0.5 + (t[vid].y - 0.5) * u.vScale);
            return o;
        }
        fragment float4 cq_camera_fill_fragment(VOut in [[stage_in]],
                                                texture2d<float> tex [[texture(0)]]) {
            constexpr sampler smp(address::clamp_to_edge, filter::linear);
            return tex.sample(smp, in.uv);
        }
        """
}

// MARK: - 预览渲染器

final class CameraPreviewRenderer: NSObject, MTKViewDelegate {

    private static let logger = Logger(subsystem: "com.chuanqi.cut", category: "camera.preview")

    let frameSlot = CameraFrameSlot()
    let faceBoxes = FaceBoxStore()
    /// 前摄帧槽/锚点仓（CAM-021 双摄；单一真源纪律同 faceBoxes，VM 前检测桥写入）。
    let frontFrameSlot = CameraFrameSlot()
    let frontFaceBoxes = FaceBoxStore()
    let commandQueue: MTLCommandQueue

    private let ciContext: CIContext
    private let presetLock = NSLock()
    private var preset: CameraFilterPreset = .none
    private let beautyLock = NSLock()
    private var beauty: CameraBeautyParams = .off
    private let reshapeLock = NSLock()
    private var reshape: CameraReshapeParams = .off
    private let bodyReshapeLock = NSLock()
    private var bodyReshape: BodyReshapeParams = .off
    private let makeupLock = NSLock()
    private var makeup: MakeupParams = .off
    private let stickerLock = NSLock()
    private var sticker: StickerAsset?
    private let fxLock = NSLock()
    private var fxUpscaleEnabled = false
    /// 双摄/PiP 状态（CAM-021；主线程写 / 渲染线程读，锁保护）。
    private let pipLock = NSLock()
    private var dualMode = false
    private var pipShowsFront = true
    /// CAM-018：预览输出色彩空间，与录制侧显式对齐（sRGB，替代语义含糊的 DeviceRGB）。
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    // MARK: 诊断计数（真机帧率验收口径 = SPEC-CAM-001 A5）
    //
    // ⚠️ 语义：**计数必须绑定「真的出了画」**。此前在 draw 末尾无条件 ++，
    //    而 CI 渲进 drawable 是静默失败（destination nil，不进 commandBuffer.error），
    //    结果黑屏也能报满帧率。现在由 commandBuffer 完成回调按成功/失败分流。
    private let frameStats = FrameStats()

    /// 已完成且无错的呈现帧数（单调递增，多线程安全读）。
    var renderedFrameCount: UInt64 { frameStats.succeeded }
    /// 已完成但有错的帧数。**非 0 即异常**，排查时先看它（伪绿嗅探针）。
    var renderFailureCount: UInt64 { frameStats.failed }

    // MARK: 中间纹理（CI 出图的落脚点，见文件头 CAM-014）

    private let scratchLock = NSLock()
    private var scratch: (any MTLTexture)?

    // MARK: MetalFX 空间升采样（CAM-022，C 期）

    /// FX 输出纹理按（帧尺寸, 输出尺寸, 像素格式）缓存；转屏/换档位重建。
    private struct FXEntry {
        let scaler: MetalFXScaler
        let texture: any MTLTexture
    }

    private var fxEntry: FXEntry?
    private var fxKey: (Int, Int, Int, Int, UInt)?

    /// 开启且屏分辨率大于帧分辨率时，把 CI 出图升采样到「drawable 分辨率、帧宽比」
    /// 的纹理（aspect-fill 溢出边 Included），供呈现 pass 采样——与关闭态取景完全一致，
    /// 只是采样自更高分辨率的纹理。返回 nil（不支持/尺寸不适用）= 跳过 FX 走原链路。
    private func runFXUpscale(commandBuffer: any MTLCommandBuffer, input: any MTLTexture,
                              frameWidth: Int, frameHeight: Int,
                              drawableWidth: Int, drawableHeight: Int,
                              pixelFormat: MTLPixelFormat) -> (any MTLTexture)? {
        let cover = max(Float(drawableWidth) / Float(frameWidth),
                        Float(drawableHeight) / Float(frameHeight))
        guard cover > 1.15 else { return nil }   // 无升采样收益（阈值 [E] 防 1.0x 抖动）
        // 输出 = 帧宽比 × drawable 级别尺寸（偶数对齐），呈现 pass 仍做中心裁切。
        var outW = Int((Float(frameWidth) * cover).rounded() / 2) * 2
        var outH = Int((Float(frameHeight) * cover).rounded() / 2) * 2
        outW = max(outW, drawableWidth)
        outH = max(outH, drawableHeight)

        fxLock.lock()
        defer { fxLock.unlock() }
        let key = (frameWidth, frameHeight, outW, outH, pixelFormat.rawValue)
        let entry: FXEntry
        if fxKey == key, let existing = fxEntry {
            entry = existing
        } else {
            guard MetalFX.isSupported(on: commandQueue.device),
                  let scaler = MetalFXScaler(device: commandQueue.device,
                                             inputWidth: frameWidth, inputHeight: frameHeight,
                                             outputWidth: outW, outputHeight: outH,
                                             pixelFormat: pixelFormat) else {
                fxEntry = nil
                fxKey = nil
                return nil
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: outW, height: outH, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .private
            guard let texture = commandQueue.device.makeTexture(descriptor: descriptor) else {
                fxEntry = nil
                fxKey = nil
                return nil
            }
            entry = FXEntry(scaler: scaler, texture: texture)
            fxEntry = entry
            fxKey = key
        }
        entry.scaler.encode(commandBuffer: commandBuffer, input: input, output: entry.texture)
        return entry.texture
    }

    // MARK: 呈现管线（aspect-fill 渲染 pass，CAM-016）

    private let pipelineLock = NSLock()
    private var pipelines: [MTLPixelFormat: Result<any MTLRenderPipelineState, NSError>] = [:]

    /// 取（并缓存）指定像素格式的呈现管线。失败按格式记忆并打一条 error ——
    /// 管线建不出来意味着黑屏，**必须留痕**（P60 教训：静默失败不能复现）。
    private func obtainPipeline(pixelFormat: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let cached = pipelines[pixelFormat] {
            return try? cached.get()
        }
        do {
            let device = commandQueue.device
            // makeLibrary(source:) 在当前 SDK 是 throws 非 optional（P48 同族口径），
            // 失败路径只有函数缺失与 pipeline 构建两处。
            let library = try device.makeLibrary(source: FillShader.mslSource, options: nil)
            guard let vertex = library.makeFunction(name: "cq_camera_fill_vertex"),
                  let fragment = library.makeFunction(name: "cq_camera_fill_fragment") else {
                throw NSError(domain: "cq.camera.render", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "填充管线 shader 函数缺失"])
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[pixelFormat] = .success(pipeline)
            return pipeline
        } catch {
            Self.logger.error("预览呈现管线创建失败（\(pixelFormat.rawValue, privacy: .public)）：\((error as NSError).localizedDescription, privacy: .public)")
            pipelines[pixelFormat] = .failure(error as NSError)
            return nil
        }
    }

    /// 取与 `size` / `pixelFormat` 匹配的中间纹理；不匹配就重建（旋转/分辨率变化走这里）。
    /// 只在 draw 这条串行路径调用，仍加锁：MTKView 不保证每次 draw 同一条线程。
    private func obtainScratch(width: Int, height: Int,
                               pixelFormat: MTLPixelFormat) -> (any MTLTexture)? {
        scratchLock.lock()
        defer { scratchLock.unlock() }
        if let existing = scratch,
           existing.width == width, existing.height == height,
           existing.pixelFormat == pixelFormat {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        // ShaderWrite 是 CI 写入的硬要求；ShaderRead 是随后渲染 pass 采样所需；
        // renderTarget 是 MetalFX 输入纹理要求（CAM-022，FX 关闭时无害）。
        descriptor.usage = [.shaderWrite, .shaderRead, .renderTarget]
        descriptor.storageMode = .private  // GPU 专用，无 CPU 访问路径
        // MTLCommandQueue.device 在当前 SDK 为非可选（P48 同族存量修复，2026-10-05
        // 集成机构建门禁暴露：optional chaining 于非可选值是编译错误）。
        guard let created = commandQueue.device.makeTexture(descriptor: descriptor) else {
            scratch = nil
            return nil
        }
        scratch = created
        return created
    }

    /// ciContext 与 commandQueue 必须同属一个 MTLDevice（由 CameraViewModel 统一
    /// 创建后注入；MTLCreateSystemDefaultDevice 进程内缓存，同机不会出现两块卡）。
    init(ciContext: CIContext, commandQueue: MTLCommandQueue) {
        self.ciContext = ciContext
        self.commandQueue = commandQueue
        super.init()
    }

    /// 主线程调用（滤镜条点击）。
    func setFilter(_ newPreset: CameraFilterPreset) {
        presetLock.lock()
        preset = newPreset
        presetLock.unlock()
    }

    /// 主线程调用（美颜面板滑杆）。
    func setBeauty(_ newBeauty: CameraBeautyParams) {
        beautyLock.lock()
        beauty = newBeauty
        beautyLock.unlock()
    }

    /// 主线程调用（美颜面板美型滑杆，CAM-013）。
    func setReshape(_ newReshape: CameraReshapeParams) {
        reshapeLock.lock()
        reshape = newReshape
        reshapeLock.unlock()
    }

    /// 主线程调用（美体滑杆，CAM-025）。
    func setBodyReshape(_ newBodyReshape: BodyReshapeParams) {
        bodyReshapeLock.lock()
        bodyReshape = newBodyReshape
        bodyReshapeLock.unlock()
    }

    /// 主线程调用（美妆面板，CAM-026）。
    func setMakeup(_ newMakeup: MakeupParams) {
        makeupLock.lock()
        makeup = newMakeup
        makeupLock.unlock()
    }

    /// 主线程调用（设置面板 FX 开关，CAM-022）。默认关 = 与原链路逐位等价。
    func setFXUpscaleEnabled(_ enabled: Bool) {
        fxLock.lock()
        fxUpscaleEnabled = enabled
        fxLock.unlock()
    }

    /// 主线程调用（贴纸选择条，CAM-014）；nil = 无贴纸。
    func setSticker(_ newSticker: StickerAsset?) {
        stickerLock.lock()
        sticker = newSticker
        stickerLock.unlock()
    }

    private func currentFilter() -> CameraFilterPreset {
        presetLock.lock()
        defer { presetLock.unlock() }
        return preset
    }

    private func currentBeauty() -> CameraBeautyParams {
        beautyLock.lock()
        defer { beautyLock.unlock() }
        return beauty
    }

    private func currentReshape() -> CameraReshapeParams {
        reshapeLock.lock()
        defer { reshapeLock.unlock() }
        return reshape
    }

    private func currentBodyReshape() -> BodyReshapeParams {
        bodyReshapeLock.lock()
        defer { bodyReshapeLock.unlock() }
        return bodyReshape
    }

    private func currentMakeup() -> MakeupParams {
        makeupLock.lock()
        defer { makeupLock.unlock() }
        return makeup
    }

    private func currentFXUpscaleEnabled() -> Bool {
        fxLock.lock()
        defer { fxLock.unlock() }
        return fxUpscaleEnabled
    }

    /// 双摄模式开关（主线程调用，VM 在会话重配成功后同步）。
    func setDualMode(_ enabled: Bool) {
        pipLock.lock()
        dualMode = enabled
        if !enabled { pipShowsFront = true }   // 回单摄：主画面归位后摄（单摄不变量）
        pipLock.unlock()
    }

    /// PiP 画面选择（主线程调用；true = PiP 显示前摄、主画面为后摄）。
    func setPiPShowsFront(_ front: Bool) {
        pipLock.lock()
        pipShowsFront = front
        pipLock.unlock()
    }

    private func currentDualMode() -> Bool {
        pipLock.lock()
        defer { pipLock.unlock() }
        return dualMode
    }

    private func currentPiPShowsFront() -> Bool {
        pipLock.lock()
        defer { pipLock.unlock() }
        return pipShowsFront
    }

    private func currentSticker() -> StickerAsset? {
        stickerLock.lock()
        defer { stickerLock.unlock() }
        return sticker
    }

    /// 统一处理链（预览/拍照共用语义）：**美颜 → 美型 warp → 美体 warp → 滤镜 → 贴纸**。
    /// 顺序锁定（TASK-CAM-013/014/025：贴纸必须贴在 warp 后画面上），变更须同步
    /// CameraRecorder.appendVideo 的同名段。
    /// faces 语义见 CameraBeauty.apply（nil=直通 / []=直通 / 非空=区域化；
    /// 2026-10-07 定则：一切人像能力算法驱动，无算法即无效果，不退化为全画面滤镜）。
    /// anchors 缺失 = 无脸或引擎降级 → 美型/人脸贴纸该帧跳过（诚实降级，不做假效果）。
    /// animalEyes = 宠物双眼（CAM-024）：无人脸锚点且有宠物时贴纸锚宠物（有脸优先）。
    /// bodyAnchors = 人体四关节（CAM-025）：齐全才做美体（半身几何不可信）。
    func process(_ image: CIImage, faces: [CGRect]? = nil,
                 anchors: CameraReshapeAnchors? = nil,
                 animalEyes: StickerEyeAnchor? = nil,
                 bodyAnchors: BodyReshapeAnchors? = nil,
                 makeupAnchors: MakeupAnchors? = nil) -> CIImage {
        // ⚠️ CAM-027 语义蒙版接线于 2026-10-08 **回退**（HANDOFF-017 / 池[9]）：
        // 当时此处写成 `beauty.apply(to:image, faces:faces, skinMask:
        // PortraitSemantics.skinMask(for: image))`，但 PortraitSemantics 从未实现、
        // CameraBeauty 也没有 skinMask 重载 → ChuanqiCutCamera Pod 整包编不过。
        // CAM-027 卡要求「API 形状保持 `apply(to:faces:)` 不变、调用方零改动」——
        // 正确做法是改 CameraBeauty **内部**取语义蒙版，而不是给调用方加参数。
        var result = currentBeauty().apply(to: image, faces: faces)
        if let warp = FaceWarp.shared {
            if let anchors {
                result = warp.apply(to: result, anchors: anchors, params: currentReshape())
            }
            if let bodyAnchors {
                result = warp.apply(to: result,
                                    controls: BodyWarpGeometry.controls(from: bodyAnchors,
                                                                        params: currentBodyReshape()))
            }
        }
        if let makeupAnchors {
            result = MakeupRenderer.apply(to: result, anchors: makeupAnchors,
                                          params: currentMakeup())
        }
        if let filtered = currentFilter().apply(to: result) {
            result = filtered
        }
        if let sticker = currentSticker() {
            if let anchors {
                result = StickerOverlay.composite(sticker, over: result, anchors: anchors)
            } else if let animalEyes {
                result = StickerOverlay.composite(sticker, over: result, eyeAnchor: animalEyes)
            }
        }
        return result
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 无需重建任何资源：中间纹理按**帧尺寸**分配（与视图尺寸无关），
        // 采样窗逐帧按帧/ drawable 实际尺寸重算（CAM-016，aspect-fill 旋转/转屏零成本）。
    }

    /// 画中画合成（CAM-021，右上角白描边；系数 [E] 真机定案）。
    static let pipSizeRatio: CGFloat = 0.28
    static let pipMarginRatio: CGFloat = 0.035
    static let pipBorderRatio: CGFloat = 0.004
    static func compositePiP(_ pip: CIImage, over main: CIImage) -> CIImage {
        let mainExtent = main.extent
        let pipExtent = pip.extent
        guard mainExtent.width > 0, mainExtent.height > 0,
              pipExtent.width > 0, pipExtent.height > 0 else { return main }
        let pipWidth = mainExtent.width * pipSizeRatio
        let scale = pipWidth / pipExtent.width
        let pipHeight = pipExtent.height * scale
        let margin = mainExtent.width * pipMarginRatio
        let border = mainExtent.width * pipBorderRatio
        let origin = CGPoint(x: mainExtent.maxX - pipWidth - margin,
                             y: mainExtent.maxY - pipHeight - margin)
        // 先缩放、再平移到右上角（t = T ∘ S）
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        transform = transform.translatedBy(x: origin.x, y: origin.y)
        let borderRect = CGRect(x: origin.x - border, y: origin.y - border,
                                width: pipWidth + border * 2, height: pipHeight + border * 2)
        let borderImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: borderRect)
        return pip.transformed(by: transform)
            .composited(over: borderImage)
            .composited(over: main)
    }

    /// 双摄录制合成（CAM-021）：与 draw 同链同序（WYSIWYG）。主画面按 pipShowsFront
    /// 选择（swap 后主画面 = 前摄最新帧，录制时间轴仍由后摄回调 PTS 驱动）；PiP 帧
    /// 缺失时该帧只出主画面（latest-wins 诚实语义，不重放旧帧）。
    func composeRecordingFrame(back: CVImageBuffer, at time: CMTime) -> CIImage {
        let mainIsBack = currentPiPShowsFront()
        let mainBuffer = mainIsBack ? back : (frontFrameSlot.latest() ?? back)
        let pipBuffer: CVImageBuffer? = mainIsBack ? frontFrameSlot.latest() : back
        let mainStore = mainIsBack ? faceBoxes : frontFaceBoxes

        var image = CIImage(cvPixelBuffer: mainBuffer)
        image = process(image, faces: mainStore.current(),
                        anchors: mainStore.currentAnchors(),
                        animalEyes: mainIsBack ? faceBoxes.currentAnimalEyes() : nil,
                        bodyAnchors: mainIsBack ? faceBoxes.currentBodyAnchors() : nil,
                        makeupAnchors: mainIsBack ? faceBoxes.currentMakeupAnchors() : nil)
        if currentDualMode(), let pipBuffer, pipBuffer !== mainBuffer {
            let pipStore = mainIsBack ? frontFaceBoxes : faceBoxes
            var pipImage = CIImage(cvPixelBuffer: pipBuffer)
            pipImage = process(pipImage, faces: pipStore.current(),
                               anchors: pipStore.currentAnchors())
            image = Self.compositePiP(pipImage, over: image)
        }
        return image
    }

    func draw(in view: MTKView) {
        // 主/PiP 画面选择（CAM-021）：默认主=后、PiP=前；swap 互换。单摄模式下
        // pipShowsFront 恒 true（setDualMode(false) 归位）→ 主画面恒 = 后摄帧槽。
        let mainIsBack = currentPiPShowsFront()
        let mainSlot = mainIsBack ? frameSlot : frontFrameSlot
        let pipSlot = mainIsBack ? frontFrameSlot : frameSlot
        let mainStore = mainIsBack ? faceBoxes : frontFaceBoxes
        let pipStore = mainIsBack ? frontFaceBoxes : faceBoxes

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let buffer = mainSlot.latest() else {
            return  // 尚无帧 / 无 drawable：跳过本拍，不报错（启动初期常态）
        }

        var image = CIImage(cvPixelBuffer: buffer)
        // 动物/美体锚点仅由后摄检测桥供给（前摄只做人脸链）——v1 口径。
        image = process(image, faces: mainStore.current(),
                        anchors: mainStore.currentAnchors(),
                        animalEyes: mainIsBack ? faceBoxes.currentAnimalEyes() : nil,
                        bodyAnchors: mainIsBack ? faceBoxes.currentBodyAnchors() : nil,
                        makeupAnchors: mainIsBack ? faceBoxes.currentMakeupAnchors() : nil)
        // PiP（双摄）：第二路同样过完整处理链（WYSIWYG，验收 A8）；帧缺失该拍只出主画面。
        if currentDualMode(), let pipBuffer = pipSlot.latest() {
            var pipImage = CIImage(cvPixelBuffer: pipBuffer)
            pipImage = process(pipImage, faces: pipStore.current(),
                               anchors: pipStore.currentAnchors())
            image = Self.compositePiP(pipImage, over: image)
        }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0,
              let scratch = obtainScratch(width: width, height: height,
                                          pixelFormat: drawable.texture.pixelFormat) else {
            return
        }

        // 1) CI 渲进中间纹理（这里 requirement 是 usage 含 ShaderWrite，配 bgra 目标）。
        //    render(toMTLTexture:) 非 throws（iOS 17.2 SDK 无同步 render(toDestination:)，
        //    P48）：CI 内部的失败不抛到此层，成败只能看下面渲染完成后的完成状态。
        //    CAM-018：显式 sRGB 输出（与录制侧同一色彩空间，替代语义含糊的 DeviceRGB）。
        ciContext.render(image, to: scratch, commandBuffer: commandBuffer,
                         bounds: extent, colorSpace: Self.outputColorSpace)

        // 1.5) MetalFX 空间升采样（CAM-022）：开关开启且屏 > 帧时把 CI 出图升到
        //      屏幕级别（帧宽比，取景不变）。关闭或不适用 = presentTexture 仍为
        //      scratch，与原链路逐位等价。
        var presentTexture: any MTLTexture = scratch
        var presentWidth = width
        var presentHeight = height
        if currentFXUpscaleEnabled() {
            if let upscaled = runFXUpscale(commandBuffer: commandBuffer, input: scratch,
                                           frameWidth: width, frameHeight: height,
                                           drawableWidth: drawable.texture.width,
                                           drawableHeight: drawable.texture.height,
                                           pixelFormat: drawable.texture.pixelFormat) {
                presentTexture = upscaled
                presentWidth = upscaled.width
                presentHeight = upscaled.height
            }
        }

        // 2) 采样中间纹理渲进 drawable（CAM-016 渲染 pass，取代被 P65 封死的 blit）：
        //    - colorAttachment 是 framebufferOnly 纹理唯一合法写法；
        //    - v 轴符号 = 行序补偿（真机颠倒修正），u/v 比例 = aspect-fill 铺满；
        //    - clamp_to_edge：采样窗浮点误差不露边。
        let drawableW = drawable.texture.width
        let drawableH = drawable.texture.height
        guard drawableW > 0, drawableH > 0,
              let renderPass = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass),
              let pipeline = obtainPipeline(pixelFormat: drawable.texture.pixelFormat) else {
            return
        }
        let coverScale = max(Float(drawableW) / Float(presentWidth),
                             Float(drawableH) / Float(presentHeight))
        var uniforms = FillUniforms(
            uScale: Float(drawableW) / (coverScale * Float(presentWidth)),
            vScale: (FillShader.ciWritesBottomUp ? 1.0 : -1.0)
                * Float(drawableH) / (coverScale * Float(presentHeight)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(presentTexture, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FillUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // 3) 计数只认「完成且无错」。回调在 Metal 自己的线程：这里**捕获 stats 不捕获 self**
        //    （`@Sendable` 闭包捕获非 Sendable 的 self 会告警，P49 同族 —— 见 CameraViewModel
        //    的 RecorderBox 写法）。埋点口径（真机验证归传哲，日志先行）：每 120 帧一条摘要，
        //    失败按 30 次节流打 error —— 失败数非 0 就是链路没真的出画。
        let stats = frameStats
        commandBuffer.addCompletedHandler { completed in
            let (ok, bad) = stats.record(success: completed.error == nil)
            if let error = completed.error, bad % 30 == 1 {
                Self.logger.error("预览帧渲染失败 #\(bad, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            } else if (ok + bad) % 120 == 0 {
                Self.logger.info("预览帧 成功=\(ok, privacy: .public) 失败=\(bad, privacy: .public)")
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
