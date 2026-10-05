// CameraRenderer — 相机帧槽 + Core Image 预览渲染（CAM-003，ADR-0014）
//
// 链路：CVPixelBuffer → CIImage → 美颜/滤镜 → CI 渲进**自建中间纹理** → 显式 UV
// 渲染 pass（行序补偿 + aspect-fill）→ drawable → present。全程 GPU（CIContext
// 默认 Metal 后端），无 CPU 读回（RESEARCH-002 §5 红线）。
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
import SharedUI
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
    let commandQueue: MTLCommandQueue

    private let ciContext: CIContext
    private let presetLock = NSLock()
    private var preset: CameraFilterPreset = .none
    private let beautyLock = NSLock()
    private var beauty: CameraBeautyParams = .off

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
        // ShaderWrite 是 CI 写入的硬要求；ShaderRead 是随后渲染 pass 采样所需。
        descriptor.usage = [.shaderWrite, .shaderRead]
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

    /// 统一处理链（预览/拍照共用语义）：美颜 → 滤镜。录制侧在 Recorder 内保持同序。
    func process(_ image: CIImage) -> CIImage {
        var result = currentBeauty().apply(to: image)
        if let filtered = currentFilter().apply(to: result) {
            result = filtered
        }
        return result
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 无需重建任何资源：中间纹理按**帧尺寸**分配（与视图尺寸无关），
        // 采样窗逐帧按帧/ drawable 实际尺寸重算（CAM-016，aspect-fill 旋转/转屏零成本）。
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let buffer = frameSlot.latest() else {
            return  // 尚无帧 / 无 drawable：跳过本拍，不报错（启动初期常态）
        }

        var image = CIImage(cvPixelBuffer: buffer)
        image = process(image)

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
        ciContext.render(image, to: scratch, commandBuffer: commandBuffer,
                         bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())

        // 2) 采样中间纹理渲进 drawable（CAM-016 渲染 pass，取代被 P65 封死的 blit）：
        //    - colorAttachment 是 framebufferOnly 纹理唯一合法写法；
        //    - v 轴符号 = 行序补偿（真机颠倒修正），u/v 比例 = aspect-fill 铺满；
        //    - clamp_to_edge：采样窗浮点误差不露边。
        let drawableWidth = drawable.texture.width
        let drawableHeight = drawable.texture.height
        guard drawableWidth > 0, drawableHeight > 0,
              let renderPass = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass),
              let pipeline = obtainPipeline(pixelFormat: drawable.texture.pixelFormat) else {
            return
        }
        let coverScale = max(Float(drawableWidth) / Float(width),
                             Float(drawableHeight) / Float(height))
        var uniforms = FillUniforms(
            uScale: Float(drawableWidth) / (coverScale * Float(width)),
            vScale: (FillShader.ciWritesBottomUp ? 1.0 : -1.0)
                * Float(drawableHeight) / (coverScale * Float(height)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(scratch, index: 0)
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
