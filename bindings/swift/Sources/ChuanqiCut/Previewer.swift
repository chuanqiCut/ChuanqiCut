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

    private var handle: OpaquePointer?

    /// 最近一次 renderFrame 产出的可显示纹理句柄（中性句柄）。
    /// 无帧 / 渲染失败时为 nil。
    public private(set) var textureHandle: UnsafeMutableRawPointer?

    /// 创建预览器。width/height 为离屏渲染目标像素尺寸；内核后端缺失时返回 nil
    /// （运行时失败，上层据此走「预览不可用」降级 —— **不要**用编译期宏判断）。
    public init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        guard let h = cq_preview_create(UInt32(width), UInt32(height)) else {
            return nil
        }
        handle = h
    }

    deinit {
        cq_preview_destroy(handle)
        handle = nil
        textureHandle = nil
    }

    // MARK: 时间线装配（预览本地的装配视图，非 Session 模型）

    /// 注册素材（asset_id → 文件路径）。内核会拷贝路径。重复注册同一 id 整体替换。
    @discardableResult
    public func registerAsset(id: UInt64, path: String) -> Status {
        guard let h = handle else { return .invalidArgument }
        let code = path.withCString { cq_preview_register_asset(h, id, $0) }
        return Status(rawValue: code)
    }

    /// 添加视频片段。轨道不存在时自动创建（实际 track id 以内核分配为准）。
    /// 同轨重叠返回 `.invalidArgument`。
    ///
    /// ⚠️ 本期只渲染第一条命中的视频轨（多轨合成等 RENDER-001）。
    @discardableResult
    public func addClip(trackId: UInt64, assetId: UInt64,
                        start: RationalTime, duration: RationalTime,
                        sourceIn: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        let code = cq_preview_add_clip(h, trackId, assetId,
                                       start.value, start.timescale,
                                       duration.value, duration.timescale,
                                       sourceIn.value, sourceIn.timescale)
        return Status(rawValue: code)
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
