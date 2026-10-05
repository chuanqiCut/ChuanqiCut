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
        // framebufferOnly 必须 = false（P64 校验层实证，2026-10-05 对 CAM-014/015 翻案）：
        // Metal 规范**禁止对 framebufferOnly 纹理做 blit**（源/目标都禁；这种纹理只允许
        // 当 render pass 的 colorAttachment）。此前注释写「blit 写入合法（本机实测无 error）」
        // 是被无校验运行骗了 —— 无校验层时属未定义行为，DEBUG scheme 的 Metal API
        // Validation / GPU 抓帧强制校验下是硬断言 SIGABRT，每帧必炸。
        // 代价 = 失去 CoreAnimation 显示优化；真机帧率不达标时的出路是「blit 换
        // render pass」，**不是改回 true**（那条路已被规范封死）。
        view.framebufferOnly = false
        view.backgroundColor = .black
        view.contentScaleFactor = UIScreen.main.scale
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        // 渲染状态全部在 renderer 内；滤镜切换走 renderer.setFilter（主线程）。
    }
}
