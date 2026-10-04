// ChuanqiCut — Swift 绑定：预览门面（BIND-003 子步骤 6）
//
// 命名说明：类型名是 **Previewer** 而非 Preview —— 新 SDK 的 SwiftUI 也导出了
// `Preview` 类型，凡同时 import SwiftUI 与本模块的文件都会类型歧义
// （2026-10-02 SharedUI 实测）。对应 C ABI 的 CQPreview（预览器）语义。
//
// 对应内核 cq_preview_*（cq_sdk.h 预览段 + core/src/preview/cq_sdk_preview.cpp）。
// 本文件仍是**薄封装**：语义一律以 cq_sdk.h 的注释为准（那份注释是契约，
// 本文件是它的 Swift 投影）。
//
// 收口后（UIA-009 子步骤 2，2026-10-03）：CQPreview 不再有本地时间线/素材表
// —— 渲染输入是 Session 发布的不可变模型快照。装配走 Session.registerAsset /
// addTrack / addClip（异步），本类只负责渲染与诊断。**强持有 Session**：
// CQPreview 不拥有 session，对象图保证 session 先活后死。
//
// 线程约定：CQPreview 内部无锁。本类**非 Sendable**，请在单一线程（约定为主
// 线程）使用。MTKView 的 draw 回调默认就在主线程，与此约定吻合。
//
// ⚠️ 纹理句柄是**中性句柄**（Apple 上即 id<MTLTexture>），有效期到下一次
//    renderFrame / resize。Swift 侧 reinterpret 后**立即用于当帧绘制**，
//    不要跨帧持有引用 —— 句柄对象由内核离屏 RT 持有，这里不 retain/release
//    （手动 retain 会与内核「下帧前有效」的约定错位，得到误导性的存活状态）。
//
// ⚠️ 设备一致性（hypothesis，2026-10-02 本机实测为真）：内核设备与 MTKView 的
//    默认设备都来自 MTLCreateSystemDefaultDevice()，进程内缓存为同一实例
//    （Intel 双 GPU 的 MacBook Pro 上亦然）。若未来出现不同实例的场景
//    （如 eGPU 热切换策略变化），需给 C ABI 补设备访问器再对齐。

import CChuanqiCut
import Foundation

public final class Previewer {

    /// internal 而非 private：PreviewPump 要用它构造自己的 CQPreviewPump
    /// （内核侧 CQPreviewPump 持有指向本对象的渲染器）。不对外公开。
    var handle: OpaquePointer?
    /// 强持有：CQPreview 不拥有 session（生命周期由对象图保证，见文件头）。
    private let session: Session

    /// 最近一次 renderFrame 产出的可显示纹理句柄（中性句柄）。
    /// 无帧 / 渲染失败时为 nil。
    public private(set) var textureHandle: UnsafeMutableRawPointer?

    /// 创建预览器（挂到 session 的模型快照上）。width/height 为离屏渲染目标
    /// 像素尺寸；内核后端缺失时返回 nil（运行时失败，上层据此走「预览不可用」
    /// 降级 —— **不要**用编译期宏判断）。
    public init?(session: Session, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        guard let h = cq_preview_create(session.handle, UInt32(width), UInt32(height)) else {
            return nil
        }
        self.handle = h
        self.session = session
    }

    deinit {
        cq_preview_destroy(handle)
        handle = nil
        textureHandle = nil
    }

    // MARK: 渲染

    /// 渲染 pts 处一帧到离屏目标。成功 / 空隙后 `textureHandle` 非空
    /// （空隙返回 `.ioNotFound`，纹理已清屏为黑 —— 上层据此区分「黑帧」与「失败」）。
    @discardableResult
    public func renderFrame(pts: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        var tex: UnsafeMutableRawPointer?
        let code = cq_preview_render_frame(h, pts.value, pts.timescale, &tex)
        textureHandle = tex
        return Status(rawValue: code)
    }

    /// 改变离屏目标尺寸（预览视图尺寸变化时）。此前返回的纹理句柄失效。
    @discardableResult
    public func resize(width: Int, height: Int) -> Status {
        guard let h = handle else { return .invalidArgument }
        guard width > 0, height > 0 else { return .invalidArgument }
        return Status(rawValue: cq_preview_resize(h, UInt32(width), UInt32(height)))
    }

    // MARK: 宽高比适配（UIA-012）

    /// 源帧与画布比例不同时的映射模式（语义以 cq_sdk.h 的 cq_preview_set_fit_mode
    /// 注释为契约）。内部 atomic，可在泵运行期间调用。
    public enum FitMode: Int32, Sendable {
        case stretch = 0  // 拉伸铺满（默认，历史行为）
        case contain = 1  // 内切居中：letterbox/pillarbox，不裁内容
        case cover = 2    // 外接居中：裁剪铺满
    }

    /// 设置宽高比适配模式。非法值由内核拒绝（返回 7000）。
    @discardableResult
    public func setFitMode(_ mode: FitMode) -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_preview_set_fit_mode(h, mode.rawValue))
    }

    // MARK: 诊断量（不是渲染结果；静态素材像素相同，靠它们证明「取对了帧」）

    /// 上一帧是否命中片段。
    public var lastHitClip: Bool {
        guard let h = handle else { return false }
        return cq_preview_last_hit_clip(h) != 0
    }

    /// 上一帧导入是否退化为 CPU 拷贝。稳定态应为 false；持续为 true 说明零拷贝链路断了。
    public var lastCpuFallback: Bool {
        guard let h = handle else { return false }
        return cq_preview_last_cpu_fallback(h) != 0
    }

    /// 内核复用的命令队列的**中性句柄**（Apple 上 reinterpret 为 MTLCommandQueue）。
    ///
    /// UI 侧把离屏 RT 拷进 drawable 时**必须**用这条队列：泵线程写 RT、UI 线程读它，
    /// 而 Metal **只保证同一条队列内**按 commit 顺序执行（跨队列需显式
    /// MTLSharedEvent / MTLFence）。共用一条队列即可由 commit 顺序天然保证先后。
    /// 后端缺失时返回 nil。
    public var sharedQueueHandle: UnsafeMutableRawPointer? {
        guard let h = handle else { return nil }
        return cq_preview_shared_queue(h)
    }

    /// 上一帧各阶段耗时（纳秒）。埋点用途 —— 预览帧率的所有讨论都要有实测数字。
    public struct Timings {
        public let acquireNs: Int64  // 取帧整段（含按需 seek + 解码）
        public let importNs: Int64   // 原生图像 → 纹理
        public let drawNs: Int64     // 离屏绘制 + 等 GPU 完成
        public let totalNs: Int64
    }

    public var lastTimings: Timings {
        guard let h = handle else { return Timings(acquireNs: 0, importNs: 0, drawNs: 0, totalNs: 0) }
        var acq: Int64 = 0
        var imp: Int64 = 0
        var drw: Int64 = 0
        var tot: Int64 = 0
        _ = cq_preview_last_timings(h, &acq, &imp, &drw, &tot)
        return Timings(acquireNs: acq, importNs: imp, drawNs: drw, totalNs: tot)
    }

    /// 上一帧**实际取到的**解码帧 pts。
    /// ⚠️ 内核在尚无取帧记录（如刚创建、或上一帧是空隙）时返回初值
    ///    `RationalTime(value: 0, timescale: 1)`，且查询恒为 kOk ——
    ///    「有没有帧」请用 `lastHitClip` 判断，不要拿本属性与 nil 比较。
    public var lastFramePts: RationalTime {
        guard let h = handle else { return RationalTime(value: 0, timescale: 1) }
        var value: Int64 = 0
        var timescale: Int32 = 0
        let code = cq_preview_last_frame_pts(h, &value, &timescale)
        guard cq_status_is_ok(code) != 0 else {
            return RationalTime(value: 0, timescale: 1)
        }
        return RationalTime(value: value, timescale: timescale)
    }
}

extension Status {
    /// pts 处是空隙（无片段覆盖）—— 不是渲染失败，纹理已清屏为黑。
    /// 数值与内核 StatusCode::kIoNotFound 同构（1001）。
    public static let ioNotFound = Status(rawValue: 1001)
}
