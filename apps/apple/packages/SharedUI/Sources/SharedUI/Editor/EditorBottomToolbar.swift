// SharedUI — 底部工具栏（UIA-015）
//
// 剪映式一级工具位：撤销/重做（左，原 TimelineZone 头部入口迁移）+ 工具组。
// 「媒体」打开媒体抽屉；音频/文字/特效为**置灰占位**——入口形状先立住，
// 能力未就绪不伪装可用（对应各自后续任务，见 TASK-BACKLOG §11）。
// macOS 不挂本条（撤销/重做仍在 TimelineZone 头部吃 Cmd 快捷键，UIA-017 再进菜单栏）。

import SwiftUI
import ChuanqiCut

struct EditorBottomToolbar: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    /// 打开媒体抽屉（开关在 EditorView：预览空态与工具栏共用一个 sheet）。
    let onOpenMedia: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // 撤销 / 重做（UIA-005 入口迁移；macOS 快捷键语义不变）
            toolbarButton(icon: "arrow.uturn.backward", label: "撤销",
                          enabled: viewModel.canUndo) { viewModel.undo() }
            toolbarButton(icon: "arrow.uturn.forward", label: "重做",
                          enabled: viewModel.canRedo) { viewModel.redo() }

            Spacer(minLength: 0)

            // 一级工具位。媒体 = 唯一可用入口；其余占位置灰。
            toolbarButton(icon: "film.stack", label: "媒体", enabled: true, action: onOpenMedia)
            toolbarButton(icon: "music.note", label: "音频", enabled: false, action: {})
            toolbarButton(icon: "textformat", label: "文字", enabled: false, action: {})
            toolbarButton(icon: "sparkles", label: "特效", enabled: false, action: {})
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.toolbarBackground)
    }

    /// 图标 + 文字竖排工具位（行业惯例的单手拇指目标）。
    private func toolbarButton(icon: String, label: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: Theme.Space.xs) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(height: 22)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(enabled ? Theme.primaryText : Theme.tertiaryText)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? label : "\(label)（未就绪）")
    }
}
