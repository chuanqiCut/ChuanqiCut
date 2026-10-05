// SharedUI — 独立播放器内核接缝（UIA-015；ADR-0022）
//
// 架构边界（ADR-0022 决策 2/4）：
//   * 控制层与 ViewModel 只依赖本协议——"换内核不换 UI"的接缝。
//   * MVP 实现 = AVPlayerEngine（过渡实现，非终态）；长期演进 = C++ 播放
//     session（复用 PlayerClock + PreviewPump + PALA-030 音频后端），
//     届时新增 CQPlayerEngine 实现即可，本协议不改。
//   * AVFoundation 只允许出现在 Player 域的引擎/画面/缩略图文件；本协议
//     的方法与属性不泄漏任何 AVFoundation 类型（TimeInterval 秒与 CGSize）。
//
// 线程模型：协议整体 @MainActor（UI 状态机同一隔离域）。实现内部的解码/
// 音频线程属于内核（AVPlayer 自管），实现负责把回调跳回主隔离域
// （手法同 AppEntry：Task { @MainActor }）。
//
// 时间口径：UI 边界一律 TimeInterval 秒。红线 #4 的 RationalTime 属时间线
// 模型；文件播放器无时间线，不引入（SPEC-UIA-020 §4.1）。

import Foundation
import CoreGraphics

// MARK: - 引擎状态

/// 引擎生命周期状态。failed 携带用户可读的中文错误描述（不做错误码翻译，
/// 保留 AVFoundation 原始 description——控制层直接展示）。
/// （App target 不直接消费本类型，故 internal；测试经 @testable 访问。）
enum PlayerEngineState: Equatable {
    case idle            // 未装载
    case loading         // 装载中（时长/轨道元数据异步读取）
    case ready           // 可播放
    case failed(String)  // 打不开 / 解码失败 / 不支持的容器
}

// MARK: - 引擎接缝

@MainActor
protocol PlayerEngine: AnyObject {

    // MARK: 状态查询（只读）

    var state: PlayerEngineState { get }
    /// 总时长（秒）。loading 期间可能是 0，ready 后有效。
    var duration: TimeInterval { get }
    /// 当前播放时刻（秒）。
    var currentTime: TimeInterval { get }
    var isPlaying: Bool { get }
    /// 播放速率（1.0 = 原速）。设置后对后续 play 立即生效。
    var rate: Double { get set }
    /// 播放器音量（0...1，仅影响本播放器，不动系统音量）。
    var volume: Double { get set }
    var isMuted: Bool { get set }
    /// 视频自然尺寸（宽高）。nil = 无视频轨 / 尚未加载。
    var videoSize: CGSize? { get }
    /// 单帧时长（秒），逐帧步进用。未知时回退 1/30。
    var frameDuration: TimeInterval { get }

    // MARK: 回调（主隔离域）

    /// 播放时刻周期回调（约 0.25s 一次；暂停时静默）。
    var onTick: ((TimeInterval) -> Void)? { get set }
    /// 状态变更回调（loading → ready / failed）。
    var onStateChange: ((PlayerEngineState) -> Void)? { get set }
    /// 播放自然结束（播到片尾）回调。
    var onEnded: (() -> Void)? { get set }
    /// 播放/暂停状态变化回调（含耳机拔出、来电中断等引擎自动暂停）。
    var onPlayStateChange: ((Bool) -> Void)? { get set }

    // MARK: 动作

    /// 装载一个本地媒体文件。重复调用 = 换源（先拆旧观察者）。
    func load(url: URL)
    func play()
    func pause()
    /// seek。precise = 零容差（帧精确，慢）；否则吸附关键帧（快进快退用）。
    func seek(to seconds: TimeInterval, precise: Bool)
    /// 拆除全部观察者/回调并停止播放。onDisappear 路径调用。
    func invalidate()
}
