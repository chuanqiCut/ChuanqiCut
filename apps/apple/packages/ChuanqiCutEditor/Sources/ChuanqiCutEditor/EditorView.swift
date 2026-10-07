// SharedUI — 编辑器主视图（UIA-032 重构）
//
// 只做三件事（ARCH-005）：呈现状态 / 收集输入 / 发出命令。
//
// 结构（SPEC-UIA-032 §4.2）：布局骨架与平台差异全在 EditorLayoutContainer；
// 本视图负责装配 Zone 与**编辑器级 UI 状态**（媒体抽屉开关 —— UI 状态，
// 不进模型；预览空态与底部工具栏共用同一个入口）。

import SwiftUI
import ChuanqiCutEngine
import SharedUI  // 基座：Theme/注入点（ADR-0031）

#if os(iOS)
/// iOS：UIKit 三件套容器（ADR-0024）。
private typealias CompactEditorHost = EditorCompactEditorView
#else
/// macOS 永不进入 compact 分支（EditorLayoutContainer macOS 布局不调用该槽位）；
/// 占位类型仅为满足泛型实例化。
private struct CompactEditorHost: View {
    init(viewModel: EditorViewModel, onOpenMedia: @escaping () -> Void) {}
    var body: some View { Color.clear }
}
#endif

public struct EditorView: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    /// 媒体抽屉开关（编辑器级：预览空态引导与底部工具栏两个入口）。
    @State private var showMediaSheet = false

    public init() {}

    public var body: some View {
        EditorLayoutContainer(
            compact: {
                CompactEditorHost(viewModel: viewModel,
                                  onOpenMedia: { showMediaSheet = true })
            },
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
