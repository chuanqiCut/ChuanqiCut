// SharedUI — 时间线区（UIA-004）：宿主 Canvas 自绘视图 + 撤销/重做入口（UIA-005）
//
// 自绘本体在 Timeline/EditorTimelineView.swift（单 Canvas，几何在 TimelineLayout）。
// 头部保留快照版本指示（与 UIA-002 桩的行为连续，便于肉眼确认刷新）。

import SwiftUI
import ChuanqiCut

struct TimelineZone: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("时间线")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)

                Spacer()

                // 播放 / 暂停（UIA-010）。无片段时不可播（播空时间线没意义）。
                Button {
                    viewModel.togglePlayback()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.timeline.clips.isEmpty)
                .foregroundStyle(viewModel.timeline.clips.isEmpty
                                  ? Theme.tertiaryText : Theme.primaryText)
                .help(viewModel.isPlaying ? "暂停" : "播放")

                // 撤销 / 重做入口（UIA-008 的一部分随 UIA-005 落地）。
                // 按钮形态两端通用；macOS 额外吃 Cmd+Z / Cmd+Shift+Z。
                // ⚠️ **iOS 摇一摇撤销本期未实现**（要靠 UIViewController 代表层，
                //    SharedUI 是纯 SwiftUI）—— 写死在注释里，不假装支持。
                Button {
                    viewModel.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canUndo)
                .foregroundStyle(viewModel.canUndo ? Theme.primaryText : Theme.tertiaryText)
                .keyboardShortcut("z", modifiers: .command)
                .help("撤销（Cmd+Z）")

                Button {
                    viewModel.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canRedo)
                .foregroundStyle(viewModel.canRedo ? Theme.primaryText : Theme.tertiaryText)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("重做（Cmd+Shift+Z）")

                Text("v\(viewModel.snapshot.version)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 24)

            Divider()

            EditorTimelineView()
        }
        .background(Theme.timelineBackground)
    }
}
