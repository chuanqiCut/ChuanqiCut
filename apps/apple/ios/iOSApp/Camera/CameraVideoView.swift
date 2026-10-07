// CameraVideoView — 相机预览 MTKView（CAM-003）
//
// 与编辑器预览（PreviewMTKView 按需单帧）刻意不同：相机是连续渲染
// （isPaused=false + enableSetNeedsDisplay=false），帧率由 vsync 驱动，
// 内容来自帧槽的最新采集帧（latest-wins，见 CameraRenderer）。

import MetalKit
import SwiftUI
import SharedUI

struct CameraVideoView: UIViewRepresentable {

    let renderer: CameraPreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.commandQueue.device)
        view.delegate = renderer
        view.isPaused = false            // 连续渲染（相机预览语义）
        view.enableSetNeedsDisplay = false
        // drawable 保持 framebufferOnly = true（CAM-016 终态）：
        // 中间纹理 → drawable 走**渲染 pass**（见 CameraRenderer），colorAttachment 是
        // framebufferOnly 纹理唯一合法的写入方式。此前的两条歧路均已被坑登记封死：
        //   - CI 直写 drawable：CIRenderDestination 要求 ShaderWrite usage → 静默黑屏（P60）；
        //   - blit 写 drawable：Metal 规范禁止对 framebufferOnly 纹理 blit，校验层下
        //     每帧 SIGABRT（P65 —— CAM-015 二段曾以 framebufferOnly=false 续命并记
        //     「不是改回 true」，那是 blit 路径的结论；blit 移除后 true 即恢复合法）。
        // 编辑器预览（PreviewFrameRenderer）同形态 + 默认 true，真机已验证。
        view.framebufferOnly = true
        view.backgroundColor = .black
        view.contentScaleFactor = UIScreen.main.scale
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        // 渲染状态全部在 renderer 内；滤镜切换走 renderer.setFilter（主线程）。
    }
}
