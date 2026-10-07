// SharedUI — 时间线区容器（UIA-004 宿主；UIA-032 重构）
//
// 自绘本体在 Timeline/EditorTimelineView.swift（单 Canvas，几何在 TimelineLayout）。
//
// UIA-032 变更：
//   * 播放/暂停与撤销/重做入口迁出 —— 播放进 EditorTransportBar（预览正下方），
//     撤销/重做 iOS 进 EditorBottomToolbar、macOS 保留在本区头部（Cmd+Z 快捷键
//     挂在按钮上，进菜单栏归 macOS 惯例化批次——原 UIA-017 建议位已让位）。
//   * `showsHeader` 参数：平台差异经 EditorLayout 的 EditorPlatform 常量决定，
//     业务视图不写条件编译（ui-apple.md 硬约束 #6）。
//   * 快照版本指示（UIA-002 调试残留，RESEARCH-004 §2 点名）移入 #if DEBUG。

import SwiftUI
import ChuanqiCut

struct TimelineZone: View {
    /// macOS = true（头部撤销/重做 + 调试版本号）；iOS = false（底部工具栏接管）。
    let showsHeader: Bool

    @EnvironmentObject private var viewModel: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: Theme.Space.m) {
                    Text("时间线")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)

                    Spacer()

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

                    #if DEBUG
                    // 调试指示（RESEARCH-004 §6.4 点 4：不进正式界面）
                    Text("v\(viewModel.snapshot.version)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.tertiaryText)
                    #endif
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(height: 24)

                Divider()
            }

            EditorTimelineView()
        }
        .background(Theme.timelineBackground)
    }
}
