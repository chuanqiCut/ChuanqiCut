// SharedUI — 编辑器主视图（UIA-032 重构）
//
// 只做三件事（ARCH-005）：呈现状态 / 收集输入 / 发出命令。
//
// 结构（SPEC-UIA-032 §4.2）：布局骨架与平台差异全在 EditorLayoutContainer；
// 本视图负责装配 Zone 与**编辑器级 UI 状态**（媒体抽屉开关 —— UI 状态，
// 不进模型；预览空态与底部工具栏共用同一个入口）。

import SwiftUI
import ChuanqiCut
import SharedUI  // 基座：Theme/注入点（ADR-0031）

public struct EditorView: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    /// 媒体抽屉开关（编辑器级：预览空态引导与底部工具栏两个入口）。
    @State private var showMediaSheet = false

    public init() {}

    public var body: some View {
        EditorLayoutContainer(
            preview: {
                PreviewZone(preview: viewModel.preview,
                            pump: viewModel.previewPump,
                            playhead: viewModel.playhead,
                            continuous: viewModel.isPlaying,
                            renderEpoch: viewModel.renderEpoch,
                            showsEmptyState: viewModel.timeline.clips.isEmpty,
                            onTogglePlayback: { viewModel.togglePlayback() },
                            onOpenMedia: { showMediaSheet = true })
            },
            transport: {
                EditorTransportBar()
            },
            timeline: {
                TimelineZone(showsHeader: EditorPlatform.showsTimelineHeader)
            },
            toolbar: {
                EditorBottomToolbar(onOpenMedia: { showMediaSheet = true })
            },
            panel: {
                // macOS 右栏：与 iOS 抽屉同源（行为等价迁移自 PropertyPanelZone）
                MediaLibraryPanel()
            }
        )
        .background(Theme.editorBackground)
        .sheet(isPresented: $showMediaSheet) {
            MediaSheet().environmentObject(viewModel)
        }
    }
}
