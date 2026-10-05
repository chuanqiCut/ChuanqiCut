// SharedUI — 独立播放器画中画协调器（UIA-015；ADR-0022 域边界文件）
//
// Player 域允许使用 AVKit/AVFoundation 的四个文件之一（引擎、画面 sink、
// 缩略图、本文件）。职责：持有 AVPictureInPictureController 强引用
// （系统要求，否则 PiP 启动即失效）、退后台自动进 PiP、可用性 KVO 上抛。
//
// MVP 只在 iOS 启用按钮（macOS 系统自带窗口级 PiP，控制层不重复提供），
// 但 API 双平台都存在，本类双平台可编译；macOS 上 attach 不会被调用。

import AVFoundation
import AVKit
import Foundation
import os

@MainActor
final class PlayerPipCoordinator {

    /// PiP 是否可能启动（KVO isPictureInPicturePossible 驱动，控制层据此显隐按钮）。
    var onPossibleChange: ((Bool) -> Void)?

    private(set) var isSupported = false
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?

    private let log = Logger(subsystem: "com.chuanqi.cut", category: "PlayerPipCoordinator")

    init() {
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// 画面 layer 就绪时接入（PlayerScreen 调用，重复调用无副作用）。
    /// layer 类型由调用方以不透明值传入（调用文件不 import AVFoundation）。
    func attach(layer: AVPlayerLayer) {
        guard isSupported, controller == nil else { return }
        guard let created = AVPictureInPictureController(playerLayer: layer) else {
            log.error("AVPictureInPictureController 创建失败（layer 非法？）")
            return
        }
        // 退后台自动进 PiP（RESEARCH-006 §3.4 最小接线）。
        created.canStartPictureInPictureAutomaticallyFromInline = true
        controller = created
        possibleObservation = created.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] observed, _ in
            let possible = observed.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.onPossibleChange?(possible) }
        }
    }

    /// 控制层 PiP 按钮动作。不可用时静默（按钮本身已按可用性显隐）。
    func start() {
        guard let controller = controller, controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    func invalidate() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller = nil
    }
}
