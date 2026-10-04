// CameraRenderer — 相机帧槽 + Core Image 预览渲染（CAM-003，ADR-0014）
//
// 链路：CVPixelBuffer → CIImage → 滤镜 → CIRenderDestination(MTKView drawable)。
// 全程 GPU（CIContext 默认 Metal 后端），无 CPU 读回（RESEARCH-002 §5 红线）。
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

// MARK: - 预览渲染器

final class CameraPreviewRenderer: NSObject, MTKViewDelegate {

    let frameSlot = CameraFrameSlot()
    let commandQueue: MTLCommandQueue

    private let ciContext: CIContext
    private let presetLock = NSLock()
    private var preset: CameraFilterPreset = .none
    private let beautyLock = NSLock()
    private var beauty: CameraBeautyParams = .off
    /// 渲染帧计数（诊断/埋点：真机帧率验证归 SPEC-CAM-001 A5）。
    private(set) var renderedFrameCount: UInt64 = 0

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
        // 视图尺寸变化无需处理：CI 渲染按 drawable 尺寸出图。
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let buffer = frameSlot.latest() else {
            return  // 尚无帧 / 无 drawable：跳过本拍，不报错（启动初期常态）
        }

        var image = CIImage(cvPixelBuffer: buffer)
        image = process(image)

        // render(toMTLTexture:) 非 throws（iOS 17.2 SDK 无同步 render(toDestination:)，
        // P48）：失败经 commandBuffer.error 暴露 → 表现为帧计数停滞，与既有口径一致。
        ciContext.render(image, to: drawable.texture, commandBuffer: commandBuffer,
                         bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())

        commandBuffer.present(drawable)
        commandBuffer.commit()
        renderedFrameCount &+= 1
    }
}
