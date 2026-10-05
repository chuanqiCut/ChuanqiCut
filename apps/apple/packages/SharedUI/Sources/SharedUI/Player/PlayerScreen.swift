// SharedUI — 独立播放器入口屏幕（UIA-015；SPEC-UIA-020 §4.3）
//
// PlayerScreen：给定本地视频 URL 的播放页（唯一 public 播放入口）。
// PlayerLauncherScreen：首页/窗口用的"先选文件再播"壳（fileImporter）。
//
// 域边界（ADR-0022）说明：本文件**不 import AVFoundation**——surface 分支
// 取 `engine.avPlayer`、layer 回调 `vm.pip.attach(layer:)` 都以"不点名的
// 不透明值"穿过（Swift 允许传递未在本文件导入的类型值）；类型耦合点收敛
// 在下面的 surface 计算属性，未来 C++ 引擎自带自绘 sink 时只改这里。

import SwiftUI
import UniformTypeIdentified

// MARK: - 播放页

public struct PlayerScreen: View {
    @StateObject private var vm: PlayerViewModel
    @State private var showsImporter = false

    public init(url: URL) {
        _vm = StateObject(wrappedValue: PlayerViewModel(url: url))
    }

    /// 测试与未来装配用（引擎注入）。
    init(engine: PlayerEngine, url: URL) {
        _vm = StateObject(wrappedValue: PlayerViewModel(engine: engine, url: url))
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            surface
            PlayerControlsOverlay(vm: vm, onOpenNewFile: { showsImporter = true })
        }
        .onAppear { vm.activate() }
        .onDisappear { vm.deactivate() }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: PlayerLauncherScreen.supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                vm.swapMedia(to: first)
            }
        }
        #if os(macOS)
        .onKeyPress { press in
            handleKeyPress(press)
        }
        #endif
    }

    /// 画面 sink。AVPlayer 之外（未来 C++ 引擎）先落黑底占位。
    @ViewBuilder
    private var surface: some View {
        if let avEngine = vm.engine as? AVPlayerEngine {
            PlayerSurface(
                player: avEngine.avPlayer,
                gravity: vm.isAspectFill ? .fill : .fit,
                onLayerReady: { layer in
                    vm.pip.attach(layer: layer)
                }
            )
            .ignoresSafeArea(edges: vm.isExpanded ? .all : [])
        } else {
            Color.black
        }
    }

    #if os(macOS)
    /// 键盘播控（对齐 mpv/IINA 表，RESEARCH-006 §3.3）：
    /// 空格播放暂停；← → ±5s；，/. 逐帧；0-9 跳 0-90%；m 静音。
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .space:
            vm.togglePlay()
            return .handled
        case .leftArrow:
            vm.skip(relative: -5)
            return .handled
        case .rightArrow:
            vm.skip(relative: 5)
            return .handled
        default:
            break
        }
        let characters = press.characters
        switch characters {
        case ",":
            vm.stepFrames(-1)
            return .handled
        case ".":
            vm.stepFrames(1)
            return .handled
        case "m", "M":
            vm.toggleMute()
            return .handled
        default:
            if let digit = characters.first?.wholeNumberValue, (0...9).contains(digit) {
                vm.jump(toFraction: Double(digit) / 10)
                return .handled
            }
            return .ignored
        }
    }
    #endif
}

// MARK: - 选择文件入口（首页卡片 / macOS 窗口共用）

public struct PlayerLauncherScreen: View {
    @State private var url: URL?
    @State private var showsImporter = false

    public init() {}

    public var body: some View {
        Group {
            if let url = url {
                PlayerScreen(url: url)
            } else {
                emptyPrompt
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: Self.supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                url = first
            }
        }
        // 拖视频文件进窗口直接播（macOS 惯例；iOS 16 / macOS 13 基线内）
        .dropDestination(for: URL.self, isTargeted: nil) { urls, _ in
            guard let first = urls.first else { return false }
            url = first
            return true
        }
    }

    private var emptyPrompt: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("选择一个本地视频开始播放")
                    .foregroundStyle(.secondary)
                Button {
                    showsImporter = true
                } label: {
                    Label("选择视频文件", systemImage: "folder")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(32)
        }
    }

    /// mp4/mov 等（AVPlayer 可播的范围；播不了的文件走播放页错误横幅）。
    /// PlayerScreen 的换片 fileImporter 共用。
    static let supportedTypes: [UTType] = [.movie, .video]
}
