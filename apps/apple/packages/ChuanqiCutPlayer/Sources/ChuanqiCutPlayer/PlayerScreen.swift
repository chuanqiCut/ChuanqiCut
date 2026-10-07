// SharedUI — 独立播放器入口屏幕（UIA-015/021/022/023/027）
//
// 三层结构：
//   * PlayerScreenBody（internal）：播放页全部内容——PlayerScreen（自管 VM）
//     与 PlayerLauncherScreen 控制器模式（App 级 VM，关窗续播）共用。
//   * PlayerScreen（public）：给定本地视频 URL 的播放页（自管 VM 生命周期，
//     onDisappear 回收）。
//   * PlayerLauncherScreen（public）：首页/窗口入口壳——选文件（可多选入队）/
//     网址/最近播放；controller 模式（UIA-027）下媒体经 PlayerController 的
//     App 级 VM 打开，窗口关闭不中断播放。
//
// 域边界（ADR-0022）说明：本文件**不 import AVFoundation**——surface 分支取
// `engine.avPlayer`、layer 回调 `vm.pip.attach(layer:)` 都以"不点名的
// 不透明值"穿过（Swift 允许传递未在本文件导入的类型值）；类型耦合点收敛
// 在 PlayerScreenBody.surface 计算属性，未来 C++ 引擎自带自绘 sink 时只改这里。

import SwiftUI
// ⚠️ 模块名是 UniformTypeIdentifiers（复数）。写成单数 UniformTypeIdentified 会让
//    swift build 直接 `no such module` —— 2026-10-06 双线合并时门禁在此红掉
//    （apple-sharedui FAIL）。Apple SDK 两侧框架目录名均为 UniformTypeIdentifiers.framework。
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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

// MARK: - 播放页主体（PlayerScreen / Launcher 控制器模式共用）

struct PlayerScreenBody: View {
    @ObservedObject var vm: PlayerViewModel
    /// true = PlayerScreen 自管 VM（onDisappear 回收）；false = App 级 VM（关窗续播）。
    var teardownOnDisappear: Bool

    @State private var showsImporter = false
    @State private var showsQueue = false
    @State private var showsSubtitleImporter = false
    @State private var showsSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            surface
            SubtitleOverlayView(cue: vm.currentExternalSubtitleCue, scale: vm.subtitleScale)
            if vm.isInPip {
                // PiP 占位态（UIA-016）：画面 layer 已被移入系统小窗
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("正在画中画播放")
                            .foregroundStyle(.white)
                        Text("画面已移至系统小窗，返回本界面可恢复")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            PlayerControlsOverlay(vm: vm,
                                  onOpenNewFile: { showsImporter = true },
                                  onShowQueue: { showsQueue = true },
                                  onImportSubtitle: { showsSubtitleImporter = true },
                                  onOpenSettings: { showsSettings = true })
        }
        .onAppear { vm.activate() }
        .onDisappear {
            if teardownOnDisappear {
                vm.deactivate()
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: PlayerLauncherScreen.supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                vm.playStandalone(first)   // 手动换片 = 退出队列模式
            }
        }
        .fileImporter(
            isPresented: $showsSubtitleImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                vm.loadExternalSubtitle(from: first)
            }
        }
        .sheet(isPresented: $showsQueue) {
            queueSheet
        }
        .sheet(isPresented: $showsSettings) {
            PlayerSettingsView(vm: vm)
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
            .scaleEffect(vm.zoomScale)          // 捏合缩放（UIA-017，纯视觉变换）
            .offset(x: vm.zoomOffset.width, y: vm.zoomOffset.height)
            .ignoresSafeArea(edges: vm.isExpanded ? .all : [])
        } else {
            Color.black
        }
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

    #if os(macOS)
    /// 键盘播控（对齐 mpv/IINA 表，RESEARCH-006 §3.3）：
    /// 空格播放暂停；← → ±N 秒；，/. 逐帧；0-9 跳 0-90%；m 静音。
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .space:
            vm.togglePlay()
            return .handled
        case .leftArrow:
            vm.skip(relative: -vm.doubleTapSeconds)
            return .handled
        case .rightArrow:
            vm.skip(relative: vm.doubleTapSeconds)
            return .handled
        default:
            break
        }
        let characters = press.characters
        return Self.characterKeyResult(characters, vm: vm) {
            // 系统窗口全屏切换（macOS 惯例；iOS 全屏走 UIA-015 的 isExpanded 按钮）
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
    }

    /// 字符键播控映射（static 便于单测；全屏动效经闭包注入，测试不碰 NSApp）。
    static func characterKeyResult(_ characters: String,
                                   vm: PlayerViewModel,
                                   toggleFullscreen: () -> Void) -> KeyPress.Result {
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
        case "f", "F":
            toggleFullscreen()
            return .handled
        case "s", "S":
            // 外挂字幕开关：已加载则关闭；未加载走 moreMenu 的加载入口
            if vm.externalSubtitle != nil {
                vm.closeExternalSubtitle()
                return .handled
            }
            return .ignored
        case "a", "A":
            vm.toggleLoop()
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

// MARK: - 播放页（自管 VM）

public struct PlayerScreen: View {
    @StateObject private var vm: PlayerViewModel

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

    public var body: some View {
        PlayerScreenBody(vm: vm, teardownOnDisappear: true)
    }
}

// MARK: - 选择文件入口（首页卡片 / macOS 窗口共用）

public struct PlayerLauncherScreen: View {
    /// 控制器模式（UIA-027，macOS）：媒体经 App 级 VM 打开，关窗续播。
    var controller: PlayerController?

    @State private var urls: [URL] = []
    @State private var showsImporter = false
    @State private var urlString = ""
    @State private var urlError: String?
    @ObservedObject private var recent = PlayerRecentStore.shared

    public init(controller: PlayerController? = nil) {
        self.controller = controller
    }

    public var body: some View {
        Group {
            if let controller = controller {
                if let vm = controller.model {
                    PlayerScreenBody(vm: vm, teardownOnDisappear: false)
                } else {
                    pickerUI(onOpen: { controller.open(urls: $0, startIndex: 0) })
                }
            } else if urls.count == 1, let only = urls.first {
                PlayerScreen(url: only)
            } else if urls.count > 1 {
                PlayerScreen(urls: urls)
            } else {
                pickerUI(onOpen: { urls = $0 })
            }
        }
    }

    private func pickerUI(onOpen: @escaping ([URL]) -> Void) -> some View {
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
                    urlEntry(onOpen: onOpen)
                    if !recent.items.isEmpty {
                        recentList(onOpen: onOpen)
                    }
                }
                .padding(32)
                .frame(maxWidth: 640)
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: Self.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let picked) = result, !picked.isEmpty {
                onOpen(picked)
            }
        }
        // 拖视频文件进窗口直接播（macOS 惯例；iOS 16 / macOS 13 基线内）
        // （`dropDestination(for:action:isTargeted:)` 的三参形态；isTargeted 不可省略）
        .dropDestination(for: URL.self) { dropped, _ in
            guard dropped.first != nil else { return false }
            onOpen(dropped)
            return true
        } isTargeted: { _ in }
    }

    /// 网址入口（UIA-024）：仅 http/https 点播；剪贴板一键粘贴。
    private func urlEntry(onOpen: @escaping ([URL]) -> Void) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("粘贴视频网址（http/https）", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit {
                        openURLString(onOpen: onOpen)
                    }
                Button {
                    openURLString(onOpen: onOpen)
                } label: {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("播放网址")
                Button {
                    urlString = Self.clipboardString() ?? ""
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.footnote)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("从剪贴板粘贴网址")
            }
            if let urlError = urlError {
                Text(urlError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func openURLString(onOpen: @escaping ([URL]) -> Void) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), AVPlayerEngine.isRemoteMediaURL(parsed) else {
            urlError = "请输入 http/https 开头的视频网址"
            return
        }
        urlError = nil
        onOpen([parsed])
    }

    static func clipboardString() -> String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #elseif canImport(AppKit)
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    /// 最近播放（UIA-021）：失效条目点击即剔除。
    private func recentList(onOpen: @escaping ([URL]) -> Void) -> some View {
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
                        onOpen([url])
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
    /// PlayerScreen 换片 fileImporter 共用。
    static let supportedTypes: [UTType] = [.movie, .video]
}
