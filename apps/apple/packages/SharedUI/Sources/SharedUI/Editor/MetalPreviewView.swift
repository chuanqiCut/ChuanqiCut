// SharedUI — MTKView 预览视图（UIA-003）
//
// 验收对应 TASK-UIA-003：预览画面不经 UI 合成路径 —— MTKView 直接绘制，
// 内核渲染的离屏纹理经一次 GPU 拷贝进 drawable（无 CPU 往返）。
//
// 渲染流程（draw 回调内，全部主线程）：
//   1. cq_preview_render_frame(pts) —— 内核完成 seek + 解码 + 零拷贝导入 + 离屏绘制
//   2. 中性句柄 reinterpret 为 MTLTexture（不 retain，见 Preview.swift 约定）
//   3. PreviewFrameRenderer 把该纹理恒等映射画进 currentDrawable 并 present
//
// ⚠️ 本视图是「单帧按需渲染」（isPaused + enableSetNeedsDisplay）：
//    播放头变化 / 视图尺寸变化才重绘。连续播放（定时推进 pts）必须由后续
//    UIA 任务以异步任务驱动 setPlayhead，**不得**在本视图内加渲染循环。

import SwiftUI
import MetalKit
import ChuanqiCut

// MARK: - MTKView 子类（持有渲染状态，MTKViewDelegate 由自身实现）

/// AppKit/UIKit 的视图类，隐式 @MainActor。满足 @objc 协议 MTKViewDelegate
/// 的要求（ObjC 协议按 @preconcurrency 处理，回调实际发生在主线程）。
final class PreviewMTKView: MTKView {

    private var renderer: PreviewFrameRenderer?

    /// 内核预览门面。nil 时本视图不渲染（保持清屏黑）。
    var preview: Previewer?

    /// 要渲染的时间线时刻。
    var pts: RationalTime = RationalTime(value: 0, timescale: RationalTime.projectTimescale)

    init(preview: Previewer?, pts: RationalTime) {
        // ⚠️ 不显式指定 device：MTKView 内部走 MTLCreateSystemDefaultDevice()，
        //    与内核 gfx_metal.mm 的设备是同一进程内缓存实例（hypothesis，
        //    2026-10-02 本机实测为真；论证见 Preview.swift 头注释）。
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)

        self.preview = preview
        self.pts = pts
        self.renderer = device.flatMap { PreviewFrameRenderer(device: $0) }

        // 按需渲染：只在 setNeedsDisplay() 被调用时绘制一帧。
        isPaused = true
        enableSetNeedsDisplay = true
        // 呈现失败 / 空隙的兜底色：黑（与内核「空隙清屏为黑」语义一致）。
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("PreviewMTKView 只支持代码创建（SwiftUI representable 宿主）")
    }

    /// 跨平台重绘请求：macOS 的 NSView.setNeedsDisplay 要传 rect（整视图失效），
    /// iOS 的 UIView.setNeedsDisplay 无参。enableSetNeedsDisplay=YES 时
    /// MTKView 由此触发一次 draw 回调。
    fileprivate func requestRedraw() {
#if os(macOS)
        needsDisplay = true
#else
        setNeedsDisplay()
#endif
    }

    /// SwiftUI 更新入口：值变化才重绘（didSet 去抖在这里做，因为初始化期
    /// 赋值不触发 didSet，且 SwiftUI 每 body 求值都会调 update*View）。
    func sync(preview: Previewer?, pts: RationalTime) {
        if self.preview !== preview {
            self.preview = preview
            requestRedraw()
        }
        if self.pts != pts {
            self.pts = pts
            requestRedraw()
        }
    }
}

// MARK: - MTKViewDelegate

extension PreviewMTKView: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // drawable 跟随视图尺寸变化 → 离屏 RT 同步重建（当前为拉伸铺满；
        // letterbox/fit 待 UI 需求明确后加，见 preview_renderer.h 的能力声明）。
        preview?.resize(width: max(1, Int(size.width)), height: max(1, Int(size.height)))
        requestRedraw()
    }

    func draw(in view: MTKView) {
        guard let renderer, let preview else { return }

        // 1) 内核渲染 pts 这一帧（同步：seek + 解码 + 导入 + 离屏绘制）。
        //    空隙返回 .ioNotFound 但句柄有效（内核已清黑）—— 照常绘制，画面即黑帧；
        //    句柄为 nil = 渲染失败（解码 / 导入 / 渲染出错）：清黑兜底，不留旧画面误导。
        preview.renderFrame(pts: pts)
        guard let handle = preview.textureHandle else {
            _ = renderer.clearToBlack(to: self)
            return
        }
        let sourceTexture = unsafeBitCast(handle, to: (any MTLTexture).self)

        // 3) 恒等映射 blit 进 drawable 并 present（GPU 拷贝，无 CPU 往返）。
        if !renderer.blit(source: sourceTexture, to: self) {
            _ = renderer.clearToBlack(to: self)
        }
    }
}

// MARK: - SwiftUI 桥接（iOS / macOS 各一套 representable，共享 PreviewMTKView）

#if os(macOS)
struct MetalPreviewView: NSViewRepresentable {
    let preview: Previewer?
    let pts: RationalTime

    func makeNSView(context: Context) -> PreviewMTKView {
        PreviewMTKView(preview: preview, pts: pts)
    }

    func updateNSView(_ view: PreviewMTKView, context: Context) {
        view.sync(preview: preview, pts: pts)
    }
}
#elseif os(iOS)
struct MetalPreviewView: UIViewRepresentable {
    let preview: Previewer?
    let pts: RationalTime

    func makeUIView(context: Context) -> PreviewMTKView {
        PreviewMTKView(preview: preview, pts: pts)
    }

    func updateUIView(_ view: PreviewMTKView, context: Context) {
        view.sync(preview: preview, pts: pts)
    }
}
#endif
