// SharedUI — MTKView 预览视图（UIA-003；UIA-010 子步骤 5 改为「主线程只 blit」）
//
// 渲染流程（分工见下，两步发生在**不同线程**）：
//   泵线程（内核）  —— seek + 解码 + 零拷贝导入 + 离屏绘制（耗时的大头）
//   主线程（本文件）—— 把泵已完成的帧 reinterpret 成 MTLTexture，一次 GPU 拷贝
//                      进 currentDrawable 并 present
//
// ⚠️ 主线程**不再**调用 preview.renderFrame：那会把整条取帧链路堵在主线程上。
//    渲染一律经 `PreviewPump.request(pts:)`，尺寸变化经 `PreviewPump.requestResize`
//    （离屏 RT 只能由持有它的线程销毁）。
//
// ⚠️ 命令队列必须用内核共享的那条（`Previewer.sharedQueueHandle`）：跨队列时
//    Metal 不保证「泵写完 → 主线程读」的先后。见 PreviewFrameRenderer 文件头。
//
// 两种绘制节奏：
//   * 连续（播放中）—— MTKView 自己按 vsync 画，主线程每帧只做一次拷贝（亚毫秒）
//   * 按需（暂停 / 拖拽）—— setNeedsDisplay 触发一次；因为泵是异步的，请求发出后
//     画面要等一帧才到，故有「自驱重绘」：画完发现请求的那帧还没发布，就再请求
//     重绘一次，直到追上或有上限（防止渲染一直失败时无限转）。收敛判定见
//     PreviewSettleRule（UIA-020：seq 比较，pts 比较在「同 pts 重渲染」下永不收敛）。

import SwiftUI
import MetalKit
import ChuanqiCut

// MARK: - 追帧收敛判定（UIA-020，纯函数可测）

/// 按需模式追帧的收敛判定。
///
/// 装载追帧时记录泵内**最新帧的 seq**（可能为 0 = 尚无任何帧）；此后任一次绘制
/// 看到的 seq **前进过**（> seqAtArm）即说明装载的那次请求已发布 —— 成功帧 /
/// 空隙黑帧 / 失败 nil 纹理帧都会发布并推 seq（泵的发布语义，见 PreviewPump.Frame.seq）。
/// seq 未前进 = 看到的还是装载前的旧帧，继续追（上限由调用方持有，防空转）。
///
/// 旧实现比较 `frame.pts != pts`：同 pts 重渲染（模型变了、播放头没动 —— 导入/
/// 撤销/移动/裁剪落地）时旧帧与新帧 pts 相同，判定永不成立，预览停在旧画面。
enum PreviewSettleRule {
    static func shouldKeepDriving(seqAtArm: UInt64, currentSeq: UInt64) -> Bool {
        currentSeq <= seqAtArm
    }
}

// MARK: - MTKView 子类（持有渲染状态，MTKViewDelegate 由自身实现）

/// AppKit/UIKit 的视图类，隐式 @MainActor。满足 @objc 协议 MTKViewDelegate
/// 的要求（ObjC 协议按 @preconcurrency 处理，回调实际发生在主线程）。
final class PreviewMTKView: MTKView {

    private var renderer: PreviewFrameRenderer?
    /// 创建 renderer 时用的队列句柄。内核换设备/换预览器时要重建 renderer。
    private var rendererQueueHandle: UnsafeMutableRawPointer?
    private var deviceRef: (any MTLDevice)?

    /// 内核预览门面。nil 时本视图不渲染（保持清屏黑）。
    var preview: Previewer?

    /// 取帧泵。**渲染入口**：有它才走「主线程只 blit」路径。
    var pump: PreviewPump?

    /// 要显示的时间线时刻（泵据此取帧）。
    var pts: RationalTime = RationalTime(value: 0, timescale: RationalTime.projectTimescale)

    /// 自驱重绘的剩余次数上限（防止渲染持续失败时以 vsync 频率空转）。
    private static let selfDriveLimit = 90

    private var selfDriveLeft = 0

    /// 装载追帧时的渲染代数（UIA-020）。nil = 从未装载过；ViewModel 每次
    /// 模型推进 bump 一次 renderEpoch，据此触发「同 pts 重渲染」。
    private var lastArmEpoch: UInt64?

    /// 装载追帧时泵内最新帧的 seq（PreviewSettleRule 的收敛基准）。
    private var seqAtArm: UInt64 = 0

    /// 连续绘制（播放中）。false = 按需（setNeedsDisplay）。
    var continuous: Bool = false {
        didSet {
            if oldValue != continuous {
                isPaused = !continuous
                if !continuous { selfDriveLeft = Self.selfDriveLimit }
            }
        }
    }

    init(preview: Previewer?, pump: PreviewPump?, pts: RationalTime) {
        // ⚠️ 不显式指定 device：MTKView 内部走 MTLCreateSystemDefaultDevice()，
        //    与内核 gfx_metal.mm 的设备是同一进程内缓存实例（hypothesis，
        //    2026-10-02 本机实测为真；论证见 Preview.swift 头注释）。
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)

        self.preview = preview
        self.pump = pump
        self.pts = pts
        // renderer 在 ensureRenderer() 里创建：它必须绑到**内核共享队列**上，
        // 而拿到队列要先有 preview。preview 为 nil（后端缺失）时 renderer 保持 nil，
        // draw 回调随之不画（视图保持清屏黑）—— 与"预览不可用"的降级语义一致。
        self.deviceRef = device

        isPaused = true
        enableSetNeedsDisplay = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        delegate = self
        ensureRenderer()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("PreviewMTKView 只支持代码创建（SwiftUI representable 宿主）")
    }

    /// renderer 必须绑到**内核共享队列**上。预览器替换 / 首次拿到预览器时重建。
    private func ensureRenderer() {
        guard let device = deviceRef, let preview else { return }
        let handle = preview.sharedQueueHandle
        if handle == rendererQueueHandle && renderer != nil { return }
        rendererQueueHandle = handle
        let queue = handle.map { unsafeBitCast($0, to: (any MTLCommandQueue).self) }
        renderer = PreviewFrameRenderer(device: device, queue: queue)
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

    /// SwiftUI 更新入口。值变化才重绘（didSet 去抖在这里做，因为初始化期
    /// 赋值不触发 didSet，且 SwiftUI 每 body 求值都会调 update*View）。
    ///
    /// 触发重渲染的两条路（UIA-020）：
    ///   * pts 变化 —— 播放头动了（拖拽 / 播放推进 / 停止归零）；
    ///   * renderEpoch 变化 —— 模型推进（导入 / 命令落地 / 撤销），同 pts 也要重取。
    func sync(preview: Previewer?, pump: PreviewPump?, pts: RationalTime,
              continuous: Bool, renderEpoch: UInt64) {
        if self.preview !== preview {
            self.preview = preview
            ensureRenderer()
        }
        if self.pump !== pump {
            self.pump = pump
        }
        if self.pts != pts {
            self.pts = pts
            armRerender(pts: pts, epoch: renderEpoch)
        } else if lastArmEpoch != renderEpoch {
            armRerender(pts: pts, epoch: renderEpoch)
        }
        if self.continuous != continuous {
            self.continuous = continuous
        }
        if !self.continuous { requestRedraw() }
    }

    /// 装载一次追帧：记录装载时刻的最新帧 seq → 发请求 → 武装自驱。
    /// ⚠️ seq 必须在 request **之前**读：请求发布后 seq 会前进，先请求再读
    ///    会把「新帧已就绪」误判成「未就绪」（反而多追一轮，语义照样对，但白画）。
    private func armRerender(pts: RationalTime, epoch: UInt64) {
        seqAtArm = pump?.withLatestFrame { $0.seq } ?? 0
        pump?.request(pts: pts)
        selfDriveLeft = Self.selfDriveLimit
        lastArmEpoch = epoch
    }
}

// MARK: - MTKViewDelegate

extension PreviewMTKView: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // drawable 跟随视图尺寸变化 → 离屏 RT 同步重建（FitMode 见 preview_renderer
        // 的能力声明）。⚠️ 走泵：RT 的销毁必须发生在持有它的那条线程（泵线程）。
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        if let pump {
            _ = pump.requestResize(width: w, height: h)
        } else {
            preview?.resize(width: w, height: h)
        }
        // 尺寸变了通常也就该重取一帧（RT 已被清空为 nil 句柄）；同走装载追帧
        // （resize 会发布 nil 纹理帧推 seq，不装载的话下一次绘制可能立即"收敛"）。
        armRerender(pts: pts, epoch: lastArmEpoch ?? 0)
        if !continuous {
            requestRedraw()
        }
    }

    func draw(in view: MTKView) {
        guard let renderer else {
            return
        }
        // 1) 从泵取「已完成的帧」（持锁期间泵不会发布新帧 / 不会 resize）。
        //    泵为空（旧路径 / 无预览后端）时退回清黑，绝不在这里同步取帧。
        guard let pump else {
            _ = renderer.clearToBlack(to: self)
            return
        }
        let frame = pump.withLatestFrame { $0 }
        guard let frame, let handle = frame.texture else {
            // 尚无帧 / 该帧渲染失败 / 刚 resize 过 —— 清黑兜底，不留旧画面误导。
            _ = renderer.clearToBlack(to: self)
            return
        }

        // 2) 中性句柄 reinterpret 为 MTLTexture（不 retain，见 Previewer.swift 约定）。
        let sourceTexture = unsafeBitCast(handle, to: (any MTLTexture).self)

        // 3) 恒等映射 blit 进 drawable 并 present（GPU 拷贝，无 CPU 往返）。
        if !renderer.blit(source: sourceTexture, to: self) {
            _ = renderer.clearToBlack(to: self)
        }

        // 4) 按需模式下自驱追帧：请求的那帧还没发布就再画一次（有上限，判定纯函数化）。
        if !continuous && selfDriveLeft > 0
            && PreviewSettleRule.shouldKeepDriving(seqAtArm: seqAtArm, currentSeq: frame.seq) {
            selfDriveLeft -= 1
            requestRedraw()
        } else {
            selfDriveLeft = 0
        }
    }
}

// MARK: - SwiftUI 桥接（iOS / macOS 各一套 representable，共享 PreviewMTKView）

#if os(macOS)
struct MetalPreviewView: NSViewRepresentable {
    let preview: Previewer?
    let pump: PreviewPump?
    let pts: RationalTime
    let continuous: Bool
    /// 模型推进代数（UIA-020）：变化即对当前 pts 重取帧。
    let renderEpoch: UInt64

    func makeNSView(context: Context) -> PreviewMTKView {
        PreviewMTKView(preview: preview, pump: pump, pts: pts)
    }

    func updateNSView(_ view: PreviewMTKView, context: Context) {
        view.sync(preview: preview, pump: pump, pts: pts, continuous: continuous,
                  renderEpoch: renderEpoch)
    }
}
#elseif os(iOS)
struct MetalPreviewView: UIViewRepresentable {
    let preview: Previewer?
    let pump: PreviewPump?
    let pts: RationalTime
    let continuous: Bool
    /// 模型推进代数（UIA-020）：变化即对当前 pts 重取帧。
    let renderEpoch: UInt64

    func makeUIView(context: Context) -> PreviewMTKView {
        PreviewMTKView(preview: preview, pump: pump, pts: pts)
    }

    func updateUIView(_ view: PreviewMTKView, context: Context) {
        view.sync(preview: preview, pump: pump, pts: pts, continuous: continuous,
                  renderEpoch: renderEpoch)
    }
}
#endif
