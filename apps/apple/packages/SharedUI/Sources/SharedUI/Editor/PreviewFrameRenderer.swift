// SharedUI — 预览帧 → Metal 目标的拷贝渲染器（UIA-003）
//
// 职责单一：把内核预览导出的纹理（中性句柄 reinterpret 的 MTLTexture）画到
// 目标纹理 —— MTKView 的 drawable（呈现路径）或普通纹理（测试 / 离屏路径）。
//
// ⚠️ 顶点几何与 uv 映射**与 pal/apple/shaders/blit_fullscreen_msl.h 完全一致**
//    （全屏三角形、uv(0,0)=图像左上、屏幕上边→v=0）：源（内核离屏 RT）与目标
//    （drawable）都是 Metal 纹理且同向，恒等映射即保证不上下颠倒。该约定已被
//    PAL 侧像素级断言锁定（test_native_image_importer_apple 的顶/底行断言），
//    两侧必须同步改动，**不得单独修改任一侧**。
//
// 层级说明（红线 #6）：本文件是 Apple 专属 UI 胶水，MSL 内联合法 —— 它与 PAL 的
// blit 同属 Platform-Native 层，是「SPIR-V 链落地前的能力缺失降级」，不是平台
// 特化优化。
//
// 线程：**@MainActor**。呈现路径由 MTKView 的 draw 回调驱动（主线程）；
// 呈现目标 MTKView 的 currentDrawable / currentRenderPassDescriptor 也是
// MainActor 隔离的（Swift 6 强制）。离屏 blitAndWait 供测试使用时，
// 测试同样标 @MainActor 即可（见 MetalPreviewViewTests）。

import Metal
import MetalKit

@MainActor
final class PreviewFrameRenderer {

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private var libraries: [MTLPixelFormat: any MTLRenderPipelineState] = [:]

    /// MSL 与 pal/apple/shaders/blit_fullscreen_msl.h 的几何/uv 逐值一致（见文件头）。
    private static let mslSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut {
            float4 position [[position]];
            float2 uv;
        };
        vertex VOut cq_preview_blit_vertex(uint vid [[vertex_id]]) {
            float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            float2 uv[3]  = { float2(0.0, 1.0),  float2(2.0, 1.0),  float2(0.0, -1.0) };
            VOut o;
            o.position = float4(pos[vid], 0.0, 1.0);
            o.uv = uv[vid];
            return o;
        }
        fragment float4 cq_preview_blit_fragment(VOut in [[stage_in]],
                                                 texture2d<float> tex [[texture(0)]]) {
            constexpr sampler smp(address::clamp_to_edge, filter::linear);
            return tex.sample(smp, in.uv);
        }
        """

    init?(device: any MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
    }

    // MARK: 呈现路径（MTKView）

    /// 画到 MTKView 当前 drawable 并 present（不等待 —— 与呈现路径匹配）。
    func blit(source: any MTLTexture, to view: MTKView) -> Bool {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let buffer = encode(source: source, passDescriptor: pass) else {
            return false
        }
        buffer.present(drawable)
        buffer.commit()
        return true
    }

    /// 清黑当前 drawable（内核渲染失败时的兜底，不留旧画面误导用户）。
    func clearToBlack(to view: MTKView) -> Bool {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer() else {
            return false
        }
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        return true
    }

    // MARK: 离屏路径（测试 / 检查用；同步等待 GPU 完成）

    /// 画到普通纹理并等待完成。目标尺寸可与源不同（线性采样拉伸铺满）。
    func blitAndWait(source: any MTLTexture, to destination: any MTLTexture) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let buffer = encode(source: source, passDescriptor: pass) else {
            return false
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer.error == nil
    }

    // MARK: 内部

    private func encode(source: any MTLTexture,
                        passDescriptor pass: MTLRenderPassDescriptor) -> (any MTLCommandBuffer)? {
        guard let destination = pass.colorAttachments[0].texture,
              let pipeline = pipeline(for: destination.pixelFormat),
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            return nil
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return buffer
    }

    private func pipeline(for destinationFormat: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        if let cached = libraries[destinationFormat] { return cached }
        guard let library = try? device.makeLibrary(source: Self.mslSource, options: nil),
              let vertex = library.makeFunction(name: "cq_preview_blit_vertex"),
              let fragment = library.makeFunction(name: "cq_preview_blit_fragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = destinationFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        libraries[destinationFormat] = pipeline
        return pipeline
    }
}
