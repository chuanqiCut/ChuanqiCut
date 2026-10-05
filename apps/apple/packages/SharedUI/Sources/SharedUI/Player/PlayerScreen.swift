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
    @State private var showsQueue = false

    public init(url: URL) {
        _vm = StateObject(wrappedValue: PlayerViewModel(url: url))
    }

    /// 队列模式入口（Launcher 多选/素材库联动/导出批预览共用，UIA-022/026）。
    public init(urls: [URL], startIndex: Int = 0) {
        let clamped = min(max(startIndex, 0), max(urls.count - 1, 0))
        // 空数组防御：落一个不可播路径 → 引擎 failed → 错误横幅（不 crash）。
        let safe = urls.isEmpty ? [URL(fileURLWithPath: "/dev/null")] : urls
        let model = PlayerViewModel(url: safe[clamped])
        model.setQueue(safe, startIndex: clamped)
        _vm = StateObject(wrappedValue: model)
    }

    /// 测试与未来装配用（引擎注入）。
    init(engine: PlayerEngine, url: URL) {
        _vm = StateObject(wrappedValue: PlayerViewModel(engine: engine, url: url))
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            surface
            PlayerControlsOverlay(vm: vm, onOpenNewFile: { showsImporter = true },
                                  onShowQueue: { showsQueue = true })
        }
        .onAppear { vm.activate() }
        .onDisappear { vm.deactivate() }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: PlayerLauncherScreen.supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                vm.playStandalone(first)   // 手动换片 = 退出队列模式
            }
        }
        .sheet(isPresented: $showsQueue) {
            queueSheet
        }
        #if os(macOS)
        .onKeyPress { press in
            handleKeyPress(press)
        }
        #endif
    }

    /// 播放队列面板（UIA-022）：当前片高亮，点击切换并关闭。
    private var queueSheet: some View {
        NavigationStack {
            List(Array(vm.queue.enumerated()), id: \.offset) { index, url in
                Button {
                    vm.jumpQueue(to: index)
                    showsQueue = false
                } label: {
                    HStack(spacing: 10) {
                        if vm.queueIndex == index {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vm.queueIndex == index
                                    ? "正在播放：\(url.lastPathComponent)"
                                    : "播放：\(url.lastPathComponent)")
            }
            .navigationTitle("播放队列（\(vm.queue.count)）")
            .toolbar {
                Button("清空") {
                    vm.clearQueue()
                    showsQueue = false
                }
            }
        }
        .preferredColorScheme(.dark)
        .playerSheetDetents()
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

// MARK: - sheet 形态（iOS 半屏两档 detents；macOS 窗口形态无需 detents，
// 手法同 AlbumPickerScreen.mediaPickerPanelPresentation）

private extension View {
    @ViewBuilder
    func playerSheetDetents() -> some View {
        #if canImport(UIKit)
        presentationDetents([.medium, .large])
        #else
        self
        #endif
    }
}

// MARK: - 选择文件入口（首页卡片 / macOS 窗口共用）

public struct PlayerLauncherScreen: View {
    @State private var urls: [URL] = []
    @State private var showsImporter = false
    @ObservedObject private var recent = PlayerRecentStore.shared

    public init() {}

    public var body: some View {
        Group {
            if urls.count == 1, let only = urls.first {
                PlayerScreen(url: only)
            } else if urls.count > 1 {
                PlayerScreen(urls: urls)
            } else {
                emptyPrompt
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: Self.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let picked) = result, !picked.isEmpty {
                urls = picked
            }
        }
        // 拖视频文件进窗口直接播（macOS 惯例；iOS 16 / macOS 13 基线内）
        .dropDestination(for: URL.self, isTargeted: nil) { dropped, _ in
            guard let first = dropped.first else { return false }
            urls = dropped
            _ = first
            return true
        }
    }

    private var emptyPrompt: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                    Text("选择本地视频开始播放，可多选连播")
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
                    if !recent.items.isEmpty {
                        recentList
                    }
                }
                .padding(32)
                .frame(maxWidth: 640)
            }
        }
    }

    /// 最近播放（UIA-021）：失效条目点击即剔除。
    private var recentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最近播放")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空") {
                    recent.clear()
                }
                .font(.footnote)
                .accessibilityLabel("清空最近播放")
            }
            .padding(.bottom, 2)
            ForEach(recent.items.prefix(8)) { item in
                Button {
                    if let url = recent.playbackURL(for: item) {
                        urls = [url]
                    } else {
                        recent.remove(item)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.isRemote ? "network" : "doc.text")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(item.name)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        Text(item.addedAt, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// mp4/mov 等（AVPlayer 可播的范围；播不了的文件走播放页错误横幅）。
    /// PlayerScreen 的换片 fileImporter 共用。
    static let supportedTypes: [UTType] = [.movie, .video]
}
