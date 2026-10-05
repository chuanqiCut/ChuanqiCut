// SharedUI — 独立播放器控制层（UIA-015；SPEC-UIA-020 §3）
//
// 全部交互手势挂在最外层 ZStack（子按钮命中优先，天然分层）：
//   单击 = 显隐控制层（与双击做 220ms 仲裁）、双击 = 左右半屏 ±10s、
//   上下滑（iOS）= 左半屏亮度 / 右半屏音量。
// 控制层不 import AVFoundation（ADR-0022 域边界）：填充模式用
// PlayerSurfaceGravity，PiP 经 vm.pip 协调器。
//
// 可见性：播放中 4s 无交互自动隐藏（VM 的 hideTask），暂停时常显；
// 失败横幅独立于显隐（挂在外层，恒可见）。

import CoreGraphics
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - 覆盖层

struct PlayerControlsOverlay: View {
    @ObservedObject var vm: PlayerViewModel

    @State private var singleTapTask: Task<Void, Never>?
    @State private var panMode: PanMode?
    @State private var panBaseBrightness: Double = 0.5
    @State private var panBaseVolume: Double = 1.0
    @State private var panFeedback: String?
    @State private var panFeedbackTask: Task<Void, Never>?

    private enum PanMode {
        case brightness
        case volume
        case ignored   // 横向拖动（留给进度条/系统手势）
    }

    var body: some View {
        GeometryReader { geo in
            content(size: geo.size)
        }
    }

    // MARK: 内容

    private func content(size: CGSize) -> some View {
        ZStack {
            controlsStack(size: size)
                .opacity(vm.showsControls ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: vm.showsControls)
            if case .failed(let message) = vm.state {
                failureView(message: message)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, coordinateSpace: .local) { location in
            singleTapTask?.cancel()
            vm.skip(relative: location.x < size.width / 2 ? -10 : 10)
        }
        .onTapGesture(count: 1) {
            // 双击仲裁：SwiftUI 本身会消歧，这里再兜一层（先等 220ms，
            // 期间发生双击则取消单击动作）。
            singleTapTask?.cancel()
            singleTapTask = Task {
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                vm.toggleControls()
            }
        }
        .gesture(panGesture(size: size))
    }

    private func controlsStack(size: CGSize) -> some View {
        ZStack {
            VStack {
                topGradient
                Spacer()
                bottomGradient
            }
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                if !vm.isExpanded {
                    topBar
                }
                Spacer()
                bottomBar
            }
            centerBubble
            if case .loading = vm.state {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("加载中")
            }
        }
    }

    private var topGradient: some View {
        LinearGradient(colors: [.black.opacity(0.65), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 96)
    }

    private var bottomGradient: some View {
        LinearGradient(colors: [.clear, .black.opacity(0.65)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 132)
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 16) {
            Text(vm.mediaTitle)
                .font(.footnote)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("正在播放：\(vm.mediaTitle)")
            Spacer()
            Button {
                vm.toggleMute()
            } label: {
                Image(systemName: vm.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(vm.isMuted ? "取消静音" : "静音")
            #if os(iOS)
            if vm.isPipPossible {
                Button {
                    vm.pip.start()
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("画中画")
            }
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: 底栏

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(PlayerTimeFormat.clock(vm.displaySeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .accessibilityLabel("当前时间")
                PlayerScrubber(vm: vm)
                Text(PlayerTimeFormat.clock(vm.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityLabel("总时长")
            }
            controlsRow
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var controlsRow: some View {
        HStack(spacing: 22) {
            Button {
                vm.togglePlay()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 32)
            }
            .accessibilityLabel(vm.isPlaying ? "暂停" : "播放")
            Button {
                vm.skip(relative: -10)
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("快退 10 秒")
            Button {
                vm.skip(relative: 10)
            } label: {
                Image(systemName: "goforward.10")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("快进 10 秒")
            rateMenu
            Spacer()
            aspectButton
            #if os(iOS)
            expandButton
            #endif
        }
    }

    private var rateMenu: some View {
        Menu {
            ForEach(Self.rateOptions, id: \.self) { option in
                Button {
                    vm.rate = option
                } label: {
                    if option == vm.rate {
                        Label(Self.rateLabel(option), systemImage: "checkmark")
                    } else {
                        Text(Self.rateLabel(option))
                    }
                }
            }
        } label: {
            Text(Self.rateLabel(vm.rate))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
        }
        .accessibilityLabel("播放速度")
    }

    private var aspectButton: some View {
        Button {
            vm.setAspectFill(!vm.isAspectFill)
        } label: {
            Text(vm.isAspectFill ? "填充" : "适合")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
        }
        .accessibilityLabel(vm.isAspectFill ? "切换为适合画面" : "切换为填充画面")
    }

    #if os(iOS)
    private var expandButton: some View {
        Button {
            vm.setExpanded(!vm.isExpanded)
        } label: {
            Image(systemName: vm.isExpanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .foregroundStyle(.white)
        }
        .accessibilityLabel(vm.isExpanded ? "退出全屏" : "全屏")
    }
    #endif

    // MARK: 中央气泡 / 失败横幅

    @ViewBuilder
    private var centerBubble: some View {
        if let text = panFeedback ?? vm.feedback {
            Text(text)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule())
                .allowsHitTesting(false)
        }
    }

    private func failureView(message: String) -> some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text("无法播放该视频")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    vm.retry()
                } label: {
                    Text("重试")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(32)
        }
    }

    // MARK: 上下滑（亮度 / 音量，仅 iOS）

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                vm.keepControlsVisible()
                #if os(iOS)
                if panMode == nil {
                    let horizontalDominant = abs(value.translation.width) > abs(value.translation.height)
                    if horizontalDominant {
                        panMode = .ignored
                    } else if value.startLocation.x < size.width / 2 {
                        panMode = .brightness
                        panBaseBrightness = Double(activeScreen?.brightness ?? 0.5)
                    } else {
                        panMode = .volume
                        panBaseVolume = vm.volume
                    }
                }
                let delta = -value.translation.height / 400
                switch panMode {
                case .brightness:
                    let newBrightness = min(max(panBaseBrightness + delta, 0.05), 1)
                    activeScreen?.brightness = CGFloat(newBrightness)
                    showPanFeedback("亮度 \(Int(newBrightness * 100))%")
                case .volume:
                    let newVolume = min(max(panBaseVolume + delta, 0), 1)
                    vm.setVolume(newVolume)
                    showPanFeedback("音量 \(Int(newVolume * 100))%")
                case .ignored, nil:
                    break
                }
                #else
                // macOS 无触屏亮度/音量范式：音量走键盘与静音键。
                _ = value
                #endif
            }
            .onEnded { _ in
                panMode = nil
            }
    }

    private func showPanFeedback(_ text: String) {
        panFeedback = text
        panFeedbackTask?.cancel()
        panFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            panFeedback = nil
        }
    }

    #if os(iOS)
    /// 键窗口所在屏幕（亮度调节目标；UIScreen.main 已弃用，不走它）。
    private var activeScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .windowScene?.screen
    }
    #endif

    // MARK: 速率选项

    static let rateOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    static func rateLabel(_ rate: Double) -> String {
        String(format: "%gx", rate)
    }
}

// MARK: - 自绘进度条

/// 拖动只更新 UI（VM.scrubPosition），松手零容差 seek（VM.endScrub）。
/// 无障碍：VoiceOver 上下扫动 = ±10s（SPEC-UIA-020 §3）。
struct PlayerScrubber: View {
    @ObservedObject var vm: PlayerViewModel

    private static let bubbleWidth: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            trackStack(width: geo.size.width)
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .gesture(scrubGesture)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(PlayerTimeFormat.clock(vm.displaySeconds))，共 \(PlayerTimeFormat.clock(vm.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                vm.skip(relative: 10)
            case .decrement:
                vm.skip(relative: -10)
            @unknown default:
                break
            }
        }
    }

    private var fraction: Double {
        guard vm.duration > 0 else { return 0 }
        return min(max(vm.displaySeconds / vm.duration, 0), 1)
    }

    private func trackStack(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(height: 4)
            Capsule()
                .fill(.white)
                .frame(width: max(0, min(width, fraction * width)), height: 4)
            Circle()
                .fill(.white)
                .frame(width: vm.isScrubbing ? 14 : 10, height: vm.isScrubbing ? 14 : 10)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .offset(x: max(0, min(width - 12, fraction * width - 6)))
            if vm.isScrubbing {
                scrubBubble
                    .offset(x: bubbleOffsetX(width: width), y: -64)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// 拖动气泡：缩略图（可选，生成失败降级为纯时间）+ 时间。
    private var scrubBubble: some View {
        VStack(spacing: 6) {
            if let image = vm.scrubThumbnail {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.bubbleWidth, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.3), lineWidth: 1)
                    )
            }
            Text(PlayerTimeFormat.clock(vm.scrubPosition))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.7), in: Capsule())
        }
        .allowsHitTesting(false)
    }

    private func bubbleOffsetX(width: CGFloat) -> CGFloat {
        guard width > Self.bubbleWidth else { return 0 }
        return min(max(fraction * width - Self.bubbleWidth / 2, 0), width - Self.bubbleWidth)
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !vm.isScrubbing {
                    vm.beginScrub()
                }
                vm.updateScrub(toFraction: fractionFor(locationX: value.location.x, width: width))
            }
            .onEnded { value in
                guard vm.isScrubbing else { return }
                vm.updateScrub(toFraction: fractionFor(locationX: value.location.x, width: width))
                vm.endScrub()
            }
    }

    private func fractionFor(locationX: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return locationX / width
    }
}
