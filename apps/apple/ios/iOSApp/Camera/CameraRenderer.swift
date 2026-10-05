// CameraRenderer — 相机帧槽 + Core Image 预览渲染（CAM-003，ADR-0014）
//
// 链路：CVPixelBuffer → CIImage → 滤镜 → CI 渲进**自建中间纹理** → blit 进
// drawable → present。全程 GPU（CIContext 默认 Metal 后端），无 CPU 读回
// （RESEARCH-002 §5 红线）。
//
// ⚠️ 为什么多了「中间纹理」这一跳（2026-10-05 真机/模拟器日志实证，CAM-014）：
//    `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` 内部要构造
//    `CIRenderDestination(mtlTexture:commandBuffer:)`，而它**要求目标纹理 usage
//    含 MTLTextureUsageShaderWrite**。`MTKView.framebufferOnly = true`（默认）时
//    drawable 纹理只有 `renderTarget`（本机实测 usage=0x04），于是 init 返回 nil，
//    控制台每帧打
//      `... texture usage must include MTLTextureUsageShaderWrite.`
//      `... _startTaskToRender:toDestination:... The destination is nil.`
//    —— 而 `render(...)` 非 throws，失败**不落到 commandBuffer.error**，
//    表现为「黑屏 + 帧计数照涨」的伪绿。
//    当时两条修法：(A) `framebufferOnly = false`；(B) 渲到自建中间纹理（usage 含
//    ShaderWrite）再 blit 进 drawable。CAM-014/015 选 B，理由记的是「drawable 保持
//    framebufferOnly，blit 写入合法（本机实测无 error）」。
//    ⚠️ 翻案（2026-10-05 校验层实证，pitfalls P64）：那句「实测无 error」不算证据 ——
//    Metal 规范**禁止对 framebufferOnly 纹理做 blit**（它只允许当 render pass 的
//    colorAttachment），无校验层时是未定义行为、驱动放行；DEBUG scheme 的 Metal API
//    Validation / GPU 抓帧下是硬断言 SIGABRT（下方 blit 处每帧必炸）。
//    终态：中间纹理**保留**（CI 落脚点职责不变）+ `framebufferOnly = false`
//    （CameraVideoView，blit 合法化）。代价 = 失去 CoreAnimation 显示优化
//    （Apple 文档 "at a cost to performance"）；真机帧率不达标时的替代方案是
//    「blit 换 render pass（全屏 quad 采样中间纹理）」，不要凭直觉优化。
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
        // ShaderWrite 是 CI 写入的硬要求；ShaderRead 是随后 blit 读取所需。
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
        // 视图尺寸变化无需处理：中间纹理按**帧尺寸**分配（不是 drawable 尺寸），
        // 写入 drawable 时再按 drawable 实际尺寸截断（保持既有「1:1 不缩放」语义，
        // 不做 letterbox/fit —— 那属于 UI 需求，改之前先问）。
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
        //    P48）：CI 内部的失败不抛到此层，成败只能看下面 blit 后的完成状态。
        ciContext.render(image, to: scratch, commandBuffer: commandBuffer,
                         bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())

        // 2) GPU 拷贝进 drawable。**目标纹理必须非 framebufferOnly**（Metal 规范禁止
        //    对 framebufferOnly 纹理 blit，校验层下硬断言 SIGABRT —— P64），
        //    已由 CameraVideoView 关掉 framebufferOnly（翻案记录见文件头）。
        //    尺寸按 drawable 截断，与改动前 CI 直写 drawable 的裁剪行为一致。
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else { return }
        let copyWidth = min(width, drawable.texture.width)
        let copyHeight = min(height, drawable.texture.height)
        encoder.copy(from: scratch,
                     sourceSlice: 0, sourceLevel: 0,
                     sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                     to: drawable.texture,
                     destinationSlice: 0, destinationLevel: 0,
                     destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
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
