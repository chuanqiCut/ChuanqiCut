// ChuanqiCut — Swift 绑定：播放时钟（UIA-010）
//
// 对应内核 CQPlayer（cq_sdk.h 播放段 + core/src/preview/player_clock.h）。
//
// ⚠️ 本类**只算时间，不取帧不渲染**。取帧与渲染走 Previewer：调用方把
//    `currentTime` 喂给 `Previewer.renderFrame(pts:)`。刻意分开 —— 时钟是
//    纯计算（无平台后端依赖），渲染需要后端（可能缺失）。
//
// 时刻 = **墙钟的函数**（不是帧数累加）：无论调用多频繁、暂停多久，
// 时刻都跟真实时间一致，且恒为整帧。上层只需按帧调用 `tick()` 推进边界 ——
// 时钟自己不跑线程（线程决策归上层）。
//
// 语义（与内核一致，定死便于断言）：停止态（含播完自然结束）时刻**恒为 0**。

import CChuanqiCut
import Foundation

public final class Player {

    private var handle: OpaquePointer?

    /// 创建播放时钟。
    /// - Parameter frameDuration: 一帧时长（29.97fps = 1001/30000）。
    ///   参数非法时内核回落到 1001/30000，不返回 nil（纯计算对象）。
    public init?(frameDuration: RationalTime = RationalTime(value: 1001, timescale: 30000)) {
        guard let h = cq_player_create(frameDuration.value, frameDuration.timescale) else {
            return nil
        }
        handle = h
    }

    deinit {
        cq_player_destroy(handle)
        handle = nil
    }

    // MARK: 状态

    public var isPlaying: Bool {
        guard let h = handle else { return false }
        return cq_player_is_playing(h) != 0
    }

    /// 当前播放时刻（帧网格量化）。停止态恒为 0。
    public var currentTime: RationalTime {
        guard let h = handle else { return RationalTime(value: 0, timescale: 1) }
        var value: Int64 = 0
        var timescale: Int32 = 0
        guard cq_status_is_ok(cq_player_current_time(h, &value, &timescale)) != 0 else {
            return RationalTime(value: 0, timescale: 1)
        }
        return RationalTime(value: value, timescale: timescale)
    }

    // MARK: 控制

    /// 播放边界（时间线总时长）。不设置 = 无边界（一直播）。
    /// 用 `Session.timelineDuration()` 取 —— 边界由内核算，UI 不要自己算。
    @discardableResult
    public func setDuration(_ duration: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_player_set_duration(h, duration.value, duration.timescale))
    }

    public func setLoop(_ on: Bool) {
        guard let h = handle else { return }
        cq_player_set_loop(h, on ? 1 : 0)
    }

    /// 开始 / 继续播放（从当前时刻起；停止态即从 0 起）。
    @discardableResult
    public func play() -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_player_play(h))
    }

    /// 暂停（冻结在当前时刻）。
    public func pause() {
        guard let h = handle else { return }
        cq_player_pause(h)
    }

    /// 停止并回到 0。
    public func stop() {
        guard let h = handle else { return }
        cq_player_stop(h)
    }

    /// 定位（量化到整帧，向下）。
    @discardableResult
    public func seek(to time: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_player_seek(h, time.value, time.timescale))
    }

    /// 边界推进：到末尾 → loop 开则回绕，否则停止。未播放 = no-op。
    /// **由调用方按帧调用**（时钟不跑线程）。
    @discardableResult
    public func tick() -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_player_tick(h))
    }
}

extension Session {
    /// 时间线总时长（末片段结束 + 出转场）。空时间线为 0。
    ///
    /// 播放边界的**唯一真源** —— 由内核时间线算出，UI 不要自己累加片段。
    /// 读的是已发布快照（同步、任意线程）。
    public func timelineDuration() -> RationalTime? {
        guard let h = handle else { return nil }
        var value: Int64 = 0
        var timescale: Int32 = 0
        guard cq_status_is_ok(cq_session_timeline_duration(h, &value, &timescale)) != 0 else {
            return nil
        }
        return RationalTime(value: value, timescale: timescale)
    }
}
