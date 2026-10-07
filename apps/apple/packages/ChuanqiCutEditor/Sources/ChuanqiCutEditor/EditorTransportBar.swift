// SharedUI — 播放控制条（UIA-032）
//
// 预览正下方：播放/暂停（主控）+ 时间码「当前 / 总时长」。
// 剪映式布局里它是预览与时间线之间的一条固定高度横条；macOS 同样挂
// （预览/timeline 之间），播放入口从时间线头部（旧 UIA-010 位置）整体上移。
//
// 红线 #4：时间码换算的唯一位置在 EditorViewModel（有理数 → 字符串），
// 本视图只读展示。播放态切换走既有 togglePlayback（红线 #5：不改模型）。

import SwiftUI
import ChuanqiCut
import SharedUI  // 基座：Theme/注入点（ADR-0031）

struct EditorTransportBar: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 32, height: 32)
                    .background(viewModel.timeline.clips.isEmpty
                                ? Theme.trackFill : Theme.accent,
                                in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.timeline.clips.isEmpty)
            .help(viewModel.isPlaying ? "暂停" : "播放")

            Spacer(minLength: 0)

            Text("\(viewModel.timecodeCurrent) / \(viewModel.timecodeDuration)")
                .font(.caption.monospaced())
                .foregroundStyle(viewModel.timeline.clips.isEmpty
                                  ? Theme.tertiaryText : Theme.secondaryText)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.transportBackground)
    }
}
