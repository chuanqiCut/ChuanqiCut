// SharedUI — 独立播放器画面承载（UIA-015；ADR-0022 域边界文件）
//
// AVPlayerLayer 的 SwiftUI 桥接：iOS = UIView(layerClass) /
// macOS = NSView(makeBackingLayer)。本文件是 Player 域允许使用
// AVFoundation 的四个文件之一。
//
// gravity 用自有枚举（PlayerSurfaceGravity）而非 AVLayerVideoGravity——
// 消费方（PlayerScreen/控制层）不点名任何 AVFoundation 类型。
//
// onLayerReady 在视图首次挂到窗口后回调一次，供 PiP 协调器接入 layer
// （layer 参数同样是"不点名的不透明值"穿过调用方）。

import AVFoundation
import AVKit
import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - 填充模式（跨平台自有枚举，隔离 AVLayerVideoGravity）

enum PlayerSurfaceGravity: Equatable {
    case fit    // aspect：完整显示，黑边
    case fill   // aspectFill：铺满裁切
}

// MARK: - 平台宿主视图

#if os(iOS)
final class PlayerLayerHostView: UIView {

    var onLayerReady: ((AVPlayerLayer) -> Void)?
    private var announcedLayer = false

    var player: AVPlayer? {
        didSet { if let layer = self.layer as? AVPlayerLayer { layer.player = player } }
    }

    var gravity: AVLayerVideoGravity = .resizeAspect {
        didSet { if let layer = self.layer as? AVPlayerLayer { layer.videoGravity = gravity } }
    }

    override static var layerClass: AnyClass { AVPlayerLayer.self }

    override func layoutSubviews() {
        super.layoutSubviews()
        announceOnce()
    }

    private func announceOnce() {
        guard !announcedLayer, let layer = self.layer as? AVPlayerLayer else { return }
        announcedLayer = true
        onLayerReady?(layer)
    }
}
#elseif os(macOS)
final class PlayerLayerHostNSView: NSView {

    var onLayerReady: ((AVPlayerLayer) -> Void)?
    private var announcedLayer = false

    var player: AVPlayer? {
        didSet { if let layer = self.layer as? AVPlayerLayer { layer.player = player } }
    }

    var gravity: AVLayerVideoGravity = .resizeAspect {
        didSet { if let layer = self.layer as? AVPlayerLayer { layer.videoGravity = gravity } }
    }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

    override func layout() {
        super.layout()
        guard !announcedLayer, let layer = self.layer as? AVPlayerLayer else { return }
        announcedLayer = true
        onLayerReady?(layer)
    }
}
#endif

// MARK: - AirPlay 路由选择器（AVRoutePickerView 桥接，UIA-016）

#if os(iOS)
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        // ⚠️ `prioritizesVideoDevices` 是 iOS 专属 —— macOS 分支写上会直接编译失败
        // （上一次只用 `swiftc -parse` 验收，语法检查放过了平台可用性）。
        view.tintColor = .white
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#elseif os(macOS)
struct AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        // macOS 无 `prioritizesVideoDevices`（iOS 专属），也无 tintColor。
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
#endif

// MARK: - SwiftUI 桥接

#if os(iOS)
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let gravity: PlayerSurfaceGravity
    let onLayerReady: ((AVPlayerLayer) -> Void)?

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView(frame: .zero)
        view.player = player
        view.gravity = mapGravity(gravity)
        view.onLayerReady = onLayerReady
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        if view.player !== player { view.player = player }
        let mapped = mapGravity(gravity)
        if view.gravity != mapped { view.gravity = mapped }
        view.onLayerReady = onLayerReady
    }

    private func mapGravity(_ gravity: PlayerSurfaceGravity) -> AVLayerVideoGravity {
        gravity == .fill ? .resizeAspectFill : .resizeAspect
    }
}
#elseif os(macOS)
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let gravity: PlayerSurfaceGravity
    let onLayerReady: ((AVPlayerLayer) -> Void)?

    func makeNSView(context: Context) -> PlayerLayerHostNSView {
        let view = PlayerLayerHostNSView(frame: .zero)
        view.player = player
        view.gravity = mapGravity(gravity)
        view.onLayerReady = onLayerReady
        return view
    }

    func updateNSView(_ view: PlayerLayerHostNSView, context: Context) {
        if view.player !== player { view.player = player }
        let mapped = mapGravity(gravity)
        if view.gravity != mapped { view.gravity = mapped }
        view.onLayerReady = onLayerReady
    }

    private func mapGravity(_ gravity: PlayerSurfaceGravity) -> AVLayerVideoGravity {
        gravity == .fill ? .resizeAspectFill : .resizeAspect
    }
}
#endif
