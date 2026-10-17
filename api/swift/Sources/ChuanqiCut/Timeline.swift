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

import ChuanqiCutCore
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

/// 素材库条目（内核素材表快照的投影）。`pathTruncated` 为 true 时路径被截断，
/// 仅可作展示用途，不可当文件路径打开。
public struct AssetInfo: Equatable, Sendable {
    public let assetId: UInt64
    public let path: String
    public let pathTruncated: Bool

    public init(assetId: UInt64, path: String, pathTruncated: Bool) {
        self.assetId = assetId
        self.path = path
        self.pathTruncated = pathTruncated
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

    // MARK: 片段编辑（UIA-005；异步提交，经 CommandHistory 可撤销）

    /// 移动片段起点（同轨）。与同轨片段重叠 → session 线程校验失败
    /// （版本不推进、观察者不回调）。
    @discardableResult
    public func moveClip(clipId: UInt64, start: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        let code = cq_session_move_clip(h, clipId, start.value, start.timescale)
        return Status(rawValue: code)
    }

    /// 裁剪片段占时。**只改 duration，不动 source_in**（内核既定语义）。
    /// duration ≤ 0 或与同轨下一片段重叠 → 校验失败。
    @discardableResult
    public func trimClip(clipId: UInt64, duration: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        let code = cq_session_trim_clip(h, clipId, duration.value, duration.timescale)
        return Status(rawValue: code)
    }

    /// 左缘裁剪（EDIT-008）：右缘（end = start + duration）不动，start /
    /// sourceIn / duration / sourceDuration 四字段由内核联动，调用方只给新起点。
    /// 左缘拖过素材入点（sourceIn < 0）或越过右缘（duration ≤ 0）→ 校验失败。
    @discardableResult
    public func trimClipIn(clipId: UInt64, start: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        let code = cq_session_trim_clip_in(h, clipId, start.value, start.timescale)
        return Status(rawValue: code)
    }

    /// 分割片段（EDIT-007）：在时间线时刻 at 处切成两半。左半保留原 id；
    /// 右半由内核分配新 id —— 经 queryClips 轮询确认（与 addClip 同约定）。
    /// at 必须严格落在片段内部（切在边界 → session 线程校验失败）；
    /// 分割点两侧的转场边界置 none（切线是媒体中段，不是媒体边界）。
    @discardableResult
    public func splitClip(clipId: UInt64, at: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        let code = cq_session_split_clip(h, clipId, at.value, at.timescale)
        return Status(rawValue: code)
    }

    /// 删除片段（EDIT-007）。Undo 以原 id 原位恢复（实体快照）。
    @discardableResult
    public func removeClip(clipId: UInt64) -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_session_remove_clip(h, clipId))
    }

    /// 删除轨道（EDIT-007）：连同轨内全部片段一起删除，Undo 整轨恢复。
    @discardableResult
    public func removeTrack(trackId: UInt64) -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_session_remove_track(h, trackId))
    }

    /// 跨轨移动（UIA-040 多轨操作；异步提交，可撤销）：片段 id 不变，
    /// 落到目标轨道 start 处。目标轨不存在 / 类型不匹配 / 重叠 → 校验失败。
    @discardableResult
    public func moveClipToTrack(clipId: UInt64, trackId: UInt64, start: RationalTime) -> Status {
        guard let h = handle else { return .invalidArgument }
        let code = cq_session_move_clip_to_track(h, clipId, trackId, start.value, start.timescale)
        return Status(rawValue: code)
    }

    /// 当前画布比例（UIA-040；**同步读**已发布快照）。默认 1080×1920（9:16）。
    /// 失败返回 (0, 0)（调用方按默认比例兜底）。
    public func canvasSize() -> (width: Int32, height: Int32) {
        guard let h = handle else { return (0, 0) }
        var w: Int32 = 0
        var height: Int32 = 0
        guard cq_status_is_ok(cq_session_get_canvas(h, &w, &height)) != 0 else { return (0, 0) }
        return (w, height)
    }

    /// 设置画布比例（UIA-040；异步提交，可撤销）。宽高只是比例语义，取值 (0, 8192]。
    @discardableResult
    public func setCanvas(width: Int32, height: Int32) -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_session_set_canvas(h, width, height))
    }

    /// 设置轨道静音（CORE-011；异步提交，可撤销）。轨不存在 → session 线程校验失败
    /// （版本不推进、观察者不回调），调用方经 `tracks()` 确认终态。
    /// 过 C ABI 用 Int32 承载 0/1，与效果启用位同口径。
    @discardableResult
    public func setTrackMuted(trackId: UInt64, muted: Bool) -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_session_set_track_muted(h, trackId, muted ? 1 : 0))
    }

    // MARK: 撤销 / 重做（UIA-005）

    /// 撤销最近一条命令。**异步**：命令历史是 session 线程状态，
    /// 本调用只是入队；空历史在 session 线程返回失败（版本不推进）。
    @discardableResult
    public func undo() -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_session_undo(h))
    }

    @discardableResult
    public func redo() -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_session_redo(h))
    }

    /// 撤销栈是否非空（**同步**读内核原子标志，任意线程）。UI 据此置灰按钮。
    public var canUndo: Bool {
        guard let h = handle else { return false }
        return cq_session_can_undo(h) != 0
    }

    public var canRedo: Bool {
        guard let h = handle else { return false }
        return cq_session_can_redo(h) != 0
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

    // MARK: 素材表查询（UIA-009 子步骤 3）

    public func assetCount() -> Int {
        guard let h = handle else { return 0 }
        var count: Int32 = 0
        guard cq_status_is_ok(cq_session_asset_count(h, &count)) != 0 else { return 0 }
        return Int(count)
    }

    public func queryAssets() -> [AssetInfo] {
        guard let h = handle else { return [] }
        var total: Int32 = 0
        guard cq_status_is_ok(cq_session_query_assets(h, nil, 0, &total)) != 0, total > 0 else {
            return []
        }
        var buffer = [CQAssetInfo](repeating: CQAssetInfo(), count: Int(total))
        var written: Int32 = 0
        guard cq_status_is_ok(cq_session_query_assets(h, &buffer, total, &written)) != 0 else {
            return []
        }
        return (0..<Int(written)).map { i in
            let a = buffer[i]
            // char[512] 导入为 512 元组，无法按数组遍历 —— 用内存布局转 CChar 串
            //（C 侧保证 NUL 结尾，String(cString:) 停在首个 0）。
            let path = withUnsafeBytes(of: a.path) { raw -> String in
                let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: base)
            }
            return AssetInfo(assetId: a.asset_id, path: path, pathTruncated: a.path_truncated != 0)
        }
    }

    /// 媒体时长探测（**同步**：打开容器读时长后立即关闭）。
    /// 导入流程用于确定片段时长；用户动作低频，非逐帧路径。
    /// 失败返回 nil（文件缺失 / 无法解析 —— 上层标记素材不可用）。
    public func probeMediaDuration(path: String) -> RationalTime? {
        // 探测是自由函数（无 session 状态参与），保留在 Session 上只为 API 归类。
        var value: Int64 = 0
        var timescale: Int32 = 0
        let code = path.withCString { cq_media_probe_duration($0, &value, &timescale) }
        guard cq_status_is_ok(code) != 0 else { return nil }
        return RationalTime(value: value, timescale: timescale)
    }

    /// 媒体时长探测（详细版，MEDIA-022）：成功返回时长，失败返回内核**原始状态码**
    /// —— 2001 = 编码格式不支持（HEVC 修复前 iPhone 相册素材曾全落这里）、
    /// 1000 = 文件无法读取、2000 = 解析失败。旧 `probeMediaDuration` 把一切失败
    /// 折叠成 nil，UI 只能统一显示「解码失败」，掩盖真实原因，故保留两者。
    public func probeMediaDurationDetailed(path: String) -> Result<RationalTime, Status> {
        var value: Int64 = 0
        var timescale: Int32 = 0
        let code = path.withCString { cq_media_probe_duration($0, &value, &timescale) }
        if cq_status_is_ok(code) != 0 {
            return .success(RationalTime(value: value, timescale: timescale))
        }
        return .failure(Status(rawValue: code))
    }
}
