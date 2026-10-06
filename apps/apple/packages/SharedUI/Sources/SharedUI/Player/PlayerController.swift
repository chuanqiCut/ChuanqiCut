// SharedUI — 播放器公共门面与迷你播控（UIA-027；PLAN-播放器进阶 P2）
//
// PlayerController：App 级持有共享 PlayerViewModel——
//   * 播放器窗口关闭不回收播放（关窗续播）；重开窗口画面恢复当前时刻；
//   * MenuBarExtra 迷你播控与主窗口共享同一实例；
//   * objectWillChange 转发 VM 内部状态（SwiftUI 订阅口单一）。
// PlayerMiniBar：macOS 菜单栏迷你播控（标题/只读进度/播放暂停/上一下一片/
//   打开主窗口）；VM 为 internal，App target 只经本门面消费（域边界）。

import Combine
import Foundation
import SwiftUI

@MainActor
public final class PlayerController: ObservableObject {

    /// 共享 VM（internal：SharedUI 内视图直读；App target 经公开转发消费）。
    private(set) var model: PlayerViewModel? {
        didSet {
            observeModel()
            publisher.send()
        }
    }

    private let publisher = ObservableObjectPublisher()
    private var modelChangeObserver: AnyCancellable?

    /// SwiftUI 订阅口：合并"VM 更换"与"VM 内部状态变化"两类通知。
    public var objectWillChange: ObservableObjectPublisher { publisher }

    public init() {}

    /// 打开（替换）播放队列并起播；首次调用创建共享 VM。
    public func open(urls: [URL], startIndex: Int = 0) {
        guard !urls.isEmpty else { return }
        let clamped = min(max(startIndex, 0), urls.count - 1)
        if let model = model {
            model.setQueue(urls, startIndex: clamped)
            model.jumpQueue(to: clamped)
        } else {
            let created = PlayerViewModel(url: urls[clamped])
            created.setQueue(urls, startIndex: clamped)
            created.activate()
            model = created
        }
    }

    /// 播放单文件（退出队列模式）。
    public func playStandalone(_ url: URL) {
        if let model = model {
            model.playStandalone(url)
        } else {
            open(urls: [url])
        }
    }

    private func observeModel() {
        modelChangeObserver = model?.objectWillChange.sink { [weak self] _ in
            self?.publisher.send()
        }
    }
}

// MARK: - 菜单栏迷你播控（macOS）

public struct PlayerMiniBar: View {
    @ObservedObject var controller: PlayerController

    public init(controller: PlayerController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        #if os(macOS)
        Group {
            if let vm = controller.model {
                miniControls(vm: vm)
            } else {
                Text("尚未播放媒体——在播放器窗口选择视频后可用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(width: 280)
        #else
        EmptyView()
        #endif
    }

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow

    private func miniControls(vm: PlayerViewModel) -> some View {
        VStack(spacing: 12) {
            Text(vm.mediaTitle)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(vm.mediaTitle)
            ProgressView(value: vm.duration > 0 ? vm.displaySeconds / vm.duration : 0)
                .progressViewStyle(.linear)
            HStack(spacing: 20) {
                Button {
                    vm.playPreviousInQueue()
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(!vm.hasPreviousQueueItem)
                .accessibilityLabel("上一片")
                Button {
                    vm.togglePlay()
                } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(vm.isPlaying ? "暂停" : "播放")
                Button {
                    vm.playNextInQueue()
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(!vm.hasNextQueueItem)
                .accessibilityLabel("下一片")
                Button {
                    openWindow(id: "player")
                } label: {
                    Image(systemName: "macwindow")
                }
                .accessibilityLabel("打开主播放器窗口")
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }
    #endif
}
