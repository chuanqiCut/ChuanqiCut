#if os(iOS)
// TimelineKitAdapter — 内核时间线 ⇄ TimelineKit 项目模型适配层
//
// ## 定位（红线 #5 / ADR-0034）
//
// **内核是唯一数据真源**。TimelineKit 的 `TimelineStore` 在本工程里只是一件
// 「渲染外衣」：它由内核快照单向灌出（`makeProject`），交互产生的变更经
// `TimelineCommand → TrackIntent` 写回内核，**写完立刻按内核最新快照重灌**
// （见 `EditorTimelineKitView`）。因此：
//
//   * 本层**不做** TimelineKit 快照 → 内核的持久化（不存在第二条真源）；
//   * 内核没有对应能力的命令（轨道排序 / 静音 / 锁定 / 轨道内重排等）一律
//     **不翻译**，由容器强制重灌回真值 —— 不做「点了有反应、内核不知道」的假功能。
//
// ## 只映射四件事（本轮范围）
//
// 轨道 / 片段 / 媒体（宿主素材路径）/ 帧率。转场、关键帧、画布 item、蒙版
// 内核侧尚无等价命令或尚无 UI 出口，本轮**不映射**（`transitions/keyframes/
// editItems/masks` 恒空），等对应内核能力落地再补 —— 空着比编造强。
//
// ## 为什么 ID 要「稳定互转」而不是 UUID
//
// TimelineKit 的 ID 是 String，内核是 UInt64。若每次灌入都新造 UUID，则
//   * 上一次的选中态 / 缩略图 / 波形缓存全部失效（每次刷新都是全新片段）；
//   * 提交事件回写内核时无法反查内核 id（只能靠位置猜 → 错片）。
// 故这里用**带前缀的十进制字符串**：UInt64 → String 单射，String → UInt64 可判定
// （前缀不匹配即 nil，不会把别处的 id 误认成本域 id）。

import Foundation
import ChuanqiCutEngine
import TimelineKit

// MARK: - ID 互转（UInt64 ⇄ String，稳定且可判定）

/// 内核 id 与 TimelineKit id 的互转。**唯一**的编码方式，全工程不得另造。
enum TimelineKitIDs {

    private static let trackPrefix = "cq-t-"
    private static let clipPrefix = "cq-c-"
    private static let mediaPrefix = "cq-m-"

    static func track(_ id: UInt64) -> String { trackPrefix + String(id) }
    static func clip(_ id: UInt64) -> String { clipPrefix + String(id) }
    static func media(_ id: UInt64) -> String { mediaPrefix + String(id) }

    /// 反解。非本域编码（前缀不符 / 尾段不是 UInt64）一律 nil —— 调用方按
    /// 「不是内核实体」处理，绝不静默吞成 0。
    static func trackID(from text: String) -> UInt64? { numeric(from: text, prefix: trackPrefix) }
    static func clipID(from text: String) -> UInt64? { numeric(from: text, prefix: clipPrefix) }
    static func mediaID(from text: String) -> UInt64? { numeric(from: text, prefix: mediaPrefix) }

    private static func numeric(from text: String, prefix: String) -> UInt64? {
        guard text.hasPrefix(prefix) else { return nil }
        return UInt64(text.dropFirst(prefix.count))
    }
}

// MARK: - 时间互转（有理数，红线 #4）

enum TimelineKitTime {

    /// RationalTime → TimelineTime。两侧都是 {(value, timescale)} 有理数，
    /// 直接搬字段即可（TimelineKit 内部会约分，值不变），**不经过浮点秒**。
    static func time(_ t: RationalTime) -> TimelineTime? {
        try? TimelineTime(value: t.value, timescale: t.timescale)
    }

    /// TimelineTime → RationalTime。同样直搬字段：内核接受任意 timescale，
    /// 不必（也不该）在这里归一化到项目 timescale —— 归一化会引入舍入。
    static func rational(_ t: TimelineTime) -> RationalTime {
        RationalTime(value: t.value, timescale: t.timescale)
    }

    /// 秒 → TimelineTime。**唯一**的浮点入口，只用于「宿主给的秒值」（播放头、
    /// 缩放刻度这类渲染量），提交口径仍是整数（见 `time(_:)`）。
    static func time(seconds: Double, timescale: Int32 = RationalTime.projectTimescale)
        -> TimelineTime? {
        guard seconds.isFinite else { return nil }
        let ticks = Int64((seconds * Double(timescale)).rounded())
        return try? TimelineTime(value: ticks, timescale: timescale)
    }
}

// MARK: - 项目构建（内核快照 → TimelineProject）

/// 一次灌入的全部输入。**值相等即视为同一份内核状态**（容器据此跳过无意义的重建）。
struct TimelineKitSnapshot: Equatable {
    let tracks: [TrackInfo]
    let clips: [ClipInfo]
    /// 素材 id → 宿主素材路径（缩略图/波形的来源；`pathTruncated` 的条目由
    /// EditorViewModel 给出的是**截断串**，不能当路径用 —— 但内核素材表返回的
    /// path 本身即完整路径，截断只在超长时发生，此处照实传给 provider，
    /// 取不到图会经 `.resourceFailed` 如实报出，不静默）。
    let assets: [UInt64: String]

    static let empty = TimelineKitSnapshot(tracks: [], clips: [], assets: [:])
}

enum TimelineKitProjectBuilder {

    /// 项目帧率。**与 `TimelineZoomMath.defaultFrameDuration`（1/30 s）同源**：
    /// 内核目前不透传素材真实帧率（MEDIA 线未落地），全工程渲染刻度一律按 30fps，
    /// 这里必须同值，否则「吸附到的帧」与「标尺画出来的帧」会差一格。
    static let frameRate: TimelineFrameRate = .fps30

    /// 主轨行高（pt）。与 `EditorChrome.timelineHeight`（220）配套：
    /// 标尺 24 + 主轨 68 + 副轨 52 ≈ 一屏三条轨，再多由 TimelineKit 自身纵向滚动。
    /// 2026-10-15 随轨道区 140 → 220 一起放大（传哲：对齐剪映）。
    static let primaryRowHeight: Double = 68
    static let secondaryRowHeight: Double = 52

    /// 内核快照 → TimelineProject。**可能抛错**（模型校验失败）：调用方必须处理，
    /// 不得用 `try!` 把工程炸在启动路径上。
    static func makeProject(_ snapshot: TimelineKitSnapshot) throws -> TimelineProject {
        let mediaAssets = makeMediaAssets(snapshot.assets)
        let assetIDs = Set(mediaAssets.map(\.id))
        var tracks: [TimelineTrack] = []
        var videoTrackCount = 0

        for track in snapshot.tracks {
            let isPrimary = track.isVideo && videoTrackCount == 0
            if track.isVideo { videoTrackCount += 1 }

            let clips = makeClips(for: track,
                                  clips: snapshot.clips,
                                  assets: snapshot.assets,
                                  knownAssetIDs: assetIDs)
            let accepted: Set<TimelineClipKind> = track.isVideo ? [.video, .image] : [.audio]
            let kind: TimelineTrackKind = isPrimary ? .primaryVideo : (track.isVideo ? .video : .audio)

            tracks.append(try TimelineTrack(
                id: TimelineKitIDs.track(track.trackId),
                name: trackName(for: track, videoIndex: videoTrackCount, isPrimary: isPrimary),
                kind: kind,
                role: isPrimary ? .primary : .secondary,
                clips: clips,
                rowHeight: isPrimary ? primaryRowHeight : secondaryRowHeight,
                // 内核同轨不重叠（重叠的 move/add 由 session 线程拒绝）→ 这里同语义，
                // 让拖到重叠位置的手势在**预览阶段**就判红（isValid=false），
                // 而不是提交后被内核拒、再弹回原位。
                overlapPolicy: hasOverlap(clips) ? .allow : .reject,
                acceptedClipKinds: accepted,
                // ⚠️ 只读回显：内核无写 `muted` 的 ABI（池 [19]），见文件头说明。
                isMuted: track.muted,
                isLocked: false,
                isHidden: false))
        }

        return try TimelineProject(
            id: "cq-project",
            tracks: tracks,
            mediaAssets: mediaAssets,
            // 转场 / 关键帧 / 画布 item / 蒙版本轮不映射（见文件头）。
            frameRate: frameRate,
            // 与内核 `session.timelineDuration()` 同语义（最长启用片段的终点）。
            durationPolicy: .longestEnabledClip,
            metadata: ["timescale": String(RationalTime.projectTimescale)])
    }

    // MARK: 片段

    private static func makeClips(for track: TrackInfo, clips: [ClipInfo],
                                  assets: [UInt64: String], knownAssetIDs: Set<String>)
        -> [TimelineClip] {
        var result: [TimelineClip] = []
        for clip in clips where clip.trackId == track.trackId {
            guard let start = TimelineKitTime.time(clip.start),
                  let duration = TimelineKitTime.time(clip.duration) else { continue }
            guard let timelineRange = try? TimelineTimeRange(start: start, duration: duration) else {
                // 非正时长 / 负起点：内核不该产出，出现即如实跳过（不伪造 1 帧）。
                continue
            }
            let sourceRange: TimelineTimeRange?
            if let sourceIn = TimelineKitTime.time(clip.sourceIn),
               let sourceDuration = TimelineKitTime.time(clip.sourceDuration),
               let range = try? TimelineTimeRange(start: sourceIn, duration: sourceDuration) {
                sourceRange = range
            } else {
                sourceRange = nil
            }

            let mediaID = TimelineKitIDs.media(clip.assetId)
            let hasAsset = knownAssetIDs.contains(mediaID)
            let clipKind: TimelineClipKind
            if !track.isVideo {
                clipKind = .audio
            } else if let path = assets[clip.assetId], mediaKind(forPath: path) == .image {
                // 图片素材：TimelineKit 走 ImageIO 静帧通道（`image(at:)`），
                // 不会误走逐帧抽帧（AVAssetImageGenerator 对静态图只会白耗一次解码）。
                clipKind = .image
            } else {
                clipKind = .video
            }

            guard let value = try? TimelineClip(
                id: TimelineKitIDs.clip(clip.clipId),
                // 素材不在宿主素材表里（路径缺失/截断）→ 不带 mediaID：
                // TimelineProject.validate() 要求 mediaID 必须存在于 mediaAssets，
                // 与其伪造一条空 locator，不如不带（该片段无缩略图，如实降级）。
                mediaID: hasAsset ? mediaID : nil,
                kind: clipKind,
                timelineRange: timelineRange,
                sourceRange: sourceRange,
                playbackRate: 1,
                isEnabled: true,
                title: nil) else { continue }
            result.append(value)
        }
        return result
    }

    // MARK: 媒体（宿主素材路径）

    /// 素材表 → TimelineKit 媒体资产。**locator = 宿主素材路径**：
    /// TimelineKit 默认的 assetProvider 对含 scheme 的串按 URL 解析、否则按
    /// `URL(fileURLWithPath:)` 处理 —— 缩略图（AVAssetImageGenerator）与波形
    /// （AVAssetReader）都由此路径取到，宿主不需要另做解码管线。
    private static func makeMediaAssets(_ assets: [UInt64: String]) -> [TimelineMediaAsset] {
        var result: [TimelineMediaAsset] = []
        for (id, path) in assets.sorted(by: { $0.key < $1.key }) {
            guard !path.isEmpty else { continue }
            let kind = mediaKind(forPath: path)
            guard let asset = try? TimelineMediaAsset(
                id: TimelineKitIDs.media(id),
                locator: path,
                kind: kind,
                // 内核素材表不含时长（AssetInfo 只有 id/path/pathTruncated）→ 留空。
                // 留空的代价只是「裁剪上限退化为片段自身源区间」，比编造一个时长诚实。
                duration: nil,
                hasAudio: kind == .audio || kind == .video,
                hasVideo: kind == .video,
                metadata: ["hostAssetID": String(id)]) else { continue }
            result.append(asset)
        }
        return result
    }

    private static func mediaKind(forPath path: String) -> TimelineMediaKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp3", "m4a", "wav", "aac", "caf", "aiff", "flac", "ogg":
            return .audio
        case "png", "jpg", "jpeg", "heic", "heif", "webp", "tiff", "bmp":
            return .image
        case "gif", "apng":
            return .animatedImage
        default:
            // 未知扩展按视频：导入路径当前只接视频/图片，视频是绝大多数情况。
            return .video
        }
    }

    // MARK: 其它

    private static func trackName(for track: TrackInfo, videoIndex: Int, isPrimary: Bool) -> String {
        if isPrimary { return "主视频" }
        return track.isVideo ? "画中画 \(max(1, videoIndex - 1))" : "音频"
    }

    /// 同轨片段是否重叠（决定 overlapPolicy）。
    ///
    /// 内核理论上不会出现重叠（addClip/moveClip 都会被拒），这里仍兜一层：
    /// 万一出现（例如未来引入的插入式编辑），用 `.allow` 让视图能画出来，
    /// 而不是让 `TimelineProject.validate()` 抛错 → 整条时间线空白。
    private static func hasOverlap(_ clips: [TimelineClip]) -> Bool {
        let ordered = clips.sorted { $0.start < $1.start }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.end > pair.1.start {
            return true
        }
        return false
    }
}
#endif
