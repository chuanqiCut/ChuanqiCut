// ChuanqiCut — Swift 绑定：预览音频门面（AUDIO-002）
//
// 对应内核 cq_audio_preview_*（cq_sdk.h 音频段 + core/cq/audio/cq_sdk_audio.cpp）。
// 本文件是**薄封装**：语义一律以 cq_sdk.h 的注释为准（那份注释是契约，
// 本文件是它的 Swift 投影）。
//
// 职责（与 Previewer 的视频链路对应）：把「时间线该出什么声音」交给内核编排
// —— 平台解码、混音、播放引擎全部在内核；本类只暴露播放头同步与统计。
// 时钟语义（视频为主、音频为从、漂移护栏自动收敛）见 cq_sdk.h 音频段，
// 不在本文件复述。
//
// 线程约定：sync() 在主线程（播放 tick）调用，非阻塞（内核临界区微秒级）。
// ⚠️ 强持有 Session：CQAudioPreview 不拥有 session（cq_sdk.h 生命周期注），
//    对象图保证 session 先活后死（与 Previewer 同型）。

import ChuanqiCutCore
import Foundation

public final class PreviewAudio {

    private var handle: OpaquePointer?
    /// 强持有（见文件头生命周期注）。
    private let session: Session

    /// 创建预览音频编排器。nil = 平台音频后端缺失或引擎启动失败（运行时失败，
    /// 上层据此走「预览无声」降级 —— 不要用编译期宏判断，红线 #3）。
    public init?(session: Session) {
        guard let h = cq_audio_preview_create(session.handle) else {
            return nil
        }
        self.handle = h
        self.session = session
    }

    deinit {
        cq_audio_preview_destroy(handle)
        handle = nil
    }

    /// 播放 tick 同步播放头（每帧调用）。暂停/停止/暂停态拖拽传 `playing: false`
    /// （内核立即静音并丢弃在途缓冲）；恢复播放自动从新播放头重锚。
    @discardableResult
    public func sync(playhead: RationalTime, playing: Bool) -> Status {
        guard let h = handle else { return .invalidArgument }
        return Status(rawValue: cq_audio_preview_sync(
            h, playhead.value, playhead.timescale, playing ? 1 : 0))
    }

    /// 混音统计（监控与验收；语义见 cq_sdk.h cq_audio_preview_stats）。
    public struct Stats: Equatable {
        public let blocksRendered: UInt64
        public let blocksDropped: UInt64
        public let underruns: UInt64
        public let resyncs: UInt64
    }

    public var stats: Stats {
        guard let h = handle else {
            return Stats(blocksRendered: 0, blocksDropped: 0, underruns: 0, resyncs: 0)
        }
        var rendered: UInt64 = 0
        var dropped: UInt64 = 0
        var underruns: UInt64 = 0
        var resyncs: UInt64 = 0
        _ = cq_audio_preview_stats(h, &rendered, &dropped, &underruns, &resyncs)
        return Stats(blocksRendered: rendered, blocksDropped: dropped,
                     underruns: underruns, resyncs: resyncs)
    }
}
