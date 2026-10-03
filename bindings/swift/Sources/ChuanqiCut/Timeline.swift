// ChuanqiCut — Swift 绑定：会话级时间线（UIA-009 子步骤 1 / UIA-004 读路径）
//
// 对应内核 cq_session_{register_asset,add_track,add_clip,track_count,
// query_tracks,query_clips}（cq_sdk.h 会话级模型段）。
//
// ⚠️ 两种线程语义（与 C 契约一致，这里再强调一次）：
//    * 提交（registerAsset/addTrack/addClip）**异步**：Ok 只代表入队，
//      校验失败表现为版本不推进 + 观察者不回调。UI 侧的刷新模式是
//      「提交 → 快照 observer 回调 → 重新查询」，不要假设提交后立即生效。
//    * 查询（trackCount/queryTracks/queryClips）**同步读已发布快照**：
//      任意线程、不阻塞（内核侧锁持有时间为纳秒级指针拷贝）。
//
// 时间一律 RationalTime（红线 #4）。

import CChuanqiCut
import Foundation

// MARK: - 值类型（查询结果的 Swift 投影）

public struct TrackInfo: Equatable, Sendable {
    public let trackId: UInt64
    /// 0 = 视频，1 = 音频（与 C ABI 的 int32 编码一致）。
    public let kind: Int32
    public let enabled: Bool
    public let muted: Bool

    public var isVideo: Bool { kind == 0 }

    /// 显式 public 成员构造（public struct 的成员逐项构造器是 internal，跨模块不可见）。
    public init(trackId: UInt64, kind: Int32, enabled: Bool, muted: Bool) {
        self.trackId = trackId
        self.kind = kind
        self.enabled = enabled
        self.muted = muted
    }
}

public struct ClipInfo: Equatable, Sendable {
    public let trackId: UInt64
    public let clipId: UInt64
    public let assetId: UInt64
    public let start: RationalTime
    public let duration: RationalTime
    public let sourceIn: RationalTime
    public let sourceDuration: RationalTime
    public let inTransition: Int32
    public let outTransition: Int32
    public let transitionDuration: RationalTime

    /// 显式 public 成员构造（同 TrackInfo）。
    public init(trackId: UInt64, clipId: UInt64, assetId: UInt64,
                start: RationalTime, duration: RationalTime,
                sourceIn: RationalTime, sourceDuration: RationalTime,
                inTransition: Int32, outTransition: Int32,
                transitionDuration: RationalTime) {
        self.trackId = trackId
        self.clipId = clipId
        self.assetId = assetId
        self.start = start
        self.duration = duration
        self.sourceIn = sourceIn
        self.sourceDuration = sourceDuration
        self.inTransition = inTransition
        self.outTransition = outTransition
        self.transitionDuration = transitionDuration
    }
}

// MARK: - Session 扩展

extension Session {

    // MARK: 提交（异步）

    /// 注册素材到会话级素材表。重复注册同一 id 整体替换。
    /// 素材不参与 Undo（资料库语义，非时间线编辑）。
    @discardableResult
    public func registerAsset(id: UInt64, path: String) -> Status {
        guard let h = handle else { return .invalidArgument }
        let code = path.withCString { cq_session_register_asset(h, id, $0) }
        return Status(rawValue: code)
    }

    /// 新增轨道。kind: 0 = 视频，1 = 音频。
    @discardableResult
    public func addTrack(kind: Int32) -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_session_add_track(h, kind))
    }

    /// 新增视频片段（可撤销 —— 内核走 CommandHistory）。
    /// 校验（轨道存在 / 时长正 / 同轨不重叠）在 session 线程执行。
    @discardableResult
    public func addClip(trackId: UInt64, assetId: UInt64,
                        start: RationalTime, duration: RationalTime,
                        sourceIn: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        let code = cq_session_add_clip(h, trackId, assetId,
                                       start.value, start.timescale,
                                       duration.value, duration.timescale,
                                       sourceIn.value, sourceIn.timescale)
        return Status(rawValue: code)
    }

    // MARK: 查询（同步读快照，任意线程）

    public func trackCount() -> Int {
        guard let h = handle else { return 0 }
        var count: Int32 = 0
        guard cq_status_is_ok(cq_session_track_count(h, &count)) != 0 else { return 0 }
        return Int(count)
    }

    public func queryTracks() -> [TrackInfo] {
        guard let h = handle else { return [] }
        var total: Int32 = 0
        guard cq_status_is_ok(cq_session_query_tracks(h, nil, 0, &total)) != 0, total > 0 else {
            return []
        }
        var buffer = [CQTrackInfo](repeating: CQTrackInfo(), count: Int(total))
        var written: Int32 = 0
        guard cq_status_is_ok(cq_session_query_tracks(h, &buffer, total, &written)) != 0 else {
            return []
        }
        return (0..<Int(written)).map { i in
            TrackInfo(trackId: buffer[i].track_id,
                      kind: buffer[i].kind,
                      enabled: buffer[i].enabled != 0,
                      muted: buffer[i].muted != 0)
        }
    }

    /// 查询片段。`trackId == nil` 返回全部轨道（轨内按 start 升序）。
    public func queryClips(trackId: UInt64? = nil) -> [ClipInfo] {
        guard let h = handle else { return [] }
        var total: Int32 = 0
        guard cq_status_is_ok(cq_session_query_clips(h, trackId ?? 0, nil, 0, &total)) != 0,
              total > 0 else {
            return []
        }
        var buffer = [CQClipInfo](repeating: CQClipInfo(), count: Int(total))
        var written: Int32 = 0
        guard cq_status_is_ok(cq_session_query_clips(h, trackId ?? 0, &buffer, total, &written)) != 0 else {
            return []
        }
        return (0..<Int(written)).map { i in
            let c = buffer[i]
            return ClipInfo(
                trackId: c.track_id,
                clipId: c.clip_id,
                assetId: c.asset_id,
                start: RationalTime(value: c.start_value, timescale: c.start_timescale),
                duration: RationalTime(value: c.duration_value, timescale: c.duration_timescale),
                sourceIn: RationalTime(value: c.source_in_value, timescale: c.source_in_timescale),
                sourceDuration: RationalTime(
                    value: c.source_duration_value, timescale: c.source_duration_timescale),
                inTransition: c.in_transition,
                outTransition: c.out_transition,
                transitionDuration: RationalTime(
                    value: c.transition_duration_value, timescale: c.transition_duration_timescale))
        }
    }
}
