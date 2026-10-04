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
        view.framebufferOnly = true      // drawable 只作渲染目标（CI 直写）
        view.backgroundColor = .black
        view.contentScaleFactor = UIScreen.main.scale
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        // 渲染状态全部在 renderer 内；滤镜切换走 renderer.setFilter（主线程）。
    }
}
