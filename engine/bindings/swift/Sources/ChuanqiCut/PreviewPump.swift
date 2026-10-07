// ChuanqiCut — Swift 绑定：预览取帧泵（UIA-010 子步骤 5）
//
// 对应内核 cq_preview_pump_*（cq_sdk.h 预览泵段 + core/src/preview/cq_sdk_preview.cpp）。
// 契约以 cq_sdk.h 的注释为准，本文件是它的 Swift 投影。
//
// 一句话：把「seek + 解码 + 导入 + 离屏绘制」搬到泵自己的线程，调用方（UI 主线程）
// 只做两件事 —— `request(pts)` 和「把已完成的帧 blit 进 drawable 并 present」。
//
// ⚠️ 它**不提高帧率**：帧率上限仍是 1/单帧取帧耗时（实测见 .ai/memory/baselines.md）。
//    它做的是把这份耗时从主线程挪走。要提帧率得解决取帧策略本身（顺序播放时
//    每帧都精确 seek = 每帧重解一个 GOP），那是另一件事。
//
// ⚠️ 挂上泵之后**禁止**再从任何线程调 `Previewer.renderFrame` / `resize`：
//    渲染器内部触碰解码会话与原生纹理缓存，不可并发访问。渲染走 `request`，
//    改尺寸走 `requestResize`。
//
// 线程安全：`request` / `requestResize` / `stats` 可任意线程调用；
// `withLatestFrame` 是消费端入口（内部成对 lock/unlock）。

import CChuanqiCut
import Foundation

public final class PreviewPump {

    /// 已完成的渲染结果。
    public struct Frame {
        /// 中性纹理句柄（Apple 上 reinterpret 为 MTLTexture）。nil = 该帧渲染失败
        /// 或刚 resize 过（旧句柄已作废）。
        public let texture: UnsafeMutableRawPointer?
        public let pts: RationalTime
        /// 单调递增；0 = 还没有任何帧。前进即代表此前的句柄作废。
        public let seq: UInt64
    }

    public struct Stats {
        public let requested: UInt64
        public let rendered: UInt64
        /// 被后续请求覆盖、从未进入渲染的请求数（请求快于渲染时的应有行为）。
        public let coalesced: UInt64
        /// 非 Ok 返回的渲染次数（含空隙 ioNotFound）。
        public let nonOk: UInt64
    }

    private var handle: OpaquePointer?
    /// 强持有：CQPreviewPump 持有指向渲染器的非拥有指针，必须**先于** Previewer 销毁。
    private let preview: Previewer

    /// 创建并启动。内核后端缺失 / 线程起不来时返回 nil。
    public init?(preview: Previewer) {
        guard let h = cq_preview_pump_create(preview.handle) else { return nil }
        self.handle = h
        self.preview = preview
    }

    deinit {
        cq_preview_pump_destroy(handle)
        handle = nil
    }

    // MARK: 请求

    /// 请求渲染 pts 处一帧。不阻塞（只入队 + 通知泵线程）。
    /// 未取走的请求会被后续请求覆盖 —— 时刻由墙钟算，丢帧只让画面少几张。
    @discardableResult
    public func request(pts: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_preview_pump_request(h, pts.value, pts.timescale))
    }

    /// 请求改变离屏目标尺寸。**在泵线程执行**（RT 只能由持有它的线程销毁）。
    @discardableResult
    public func requestResize(width: Int, height: Int) -> Status {
        guard let h = handle else { return .invalidArgument }
        guard width > 0, height > 0 else { return .invalidArgument }
        return Status(rawValue: cq_preview_pump_request_resize(h, UInt32(width), UInt32(height)))
    }

    // MARK: 消费（主线程：blit + present）

    /// 取最新已完成帧并**持锁**执行 body，返回后自动解锁。
    ///
    /// ⚠️ body 内只做「编码一次 blit」—— 不要 waitUntilCompleted（会把泵一起堵住），
    ///    也不要在 body 里调 `request`（两者抢同一把锁 → 死锁）。
    ///
    /// - Returns: body 的返回值；尚无帧 / 句柄无效时为 nil。
    public func withLatestFrame<R>(_ body: (Frame) -> R) -> R? {
        guard let h = handle else { return nil }
        var tex: UnsafeMutableRawPointer?
        var value: Int64 = 0
        var timescale: Int32 = 0
        var seq: UInt64 = 0
        let code = cq_preview_pump_lock(h, &tex, &value, &timescale, &seq)
        guard cq_status_is_ok(code) != 0 else { return nil }
        defer { _ = cq_preview_pump_unlock(h) }
        return body(Frame(texture: tex,
                          pts: RationalTime(value: value, timescale: timescale),
                          seq: seq))
    }

    // MARK: 生命周期与统计

    /// 停止泵线程（可再 start 重启）。停止后的 request 仍会入队，重启后渲染最新的。
    @discardableResult
    public func stop() -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_preview_pump_stop(h))
    }

    @discardableResult
    public func start() -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_preview_pump_start(h))
    }

    public var stats: Stats {
        guard let h = handle else {
            return Stats(requested: 0, rendered: 0, coalesced: 0, nonOk: 0)
        }
        var req: UInt64 = 0
        var ren: UInt64 = 0
        var coa: UInt64 = 0
        var nok: UInt64 = 0
        _ = cq_preview_pump_stats(h, &req, &ren, &coa, &nok)
        return Stats(requested: req, rendered: ren, coalesced: coa, nonOk: nok)
    }
}
