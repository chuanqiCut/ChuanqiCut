// SharedUI — 编辑器主视图：三区布局入口（UIA-002）
//
// 只做三件事（ARCH-005）：呈现状态 / 收集输入 / 发出命令。
// 本视图只呈现 —— 输入与命令由后续任务（UIA-005 拖拽、UIA-006 参数）接入。

import SwiftUI
import ChuanqiCut

public struct EditorView: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    public init() {}

    public var body: some View {
        EditorLayoutContainer(
            preview: {
                PreviewZone(snapshot: viewModel.snapshot)
            },
            timeline: {
                TimelineZone(snapshot: viewModel.snapshot)
            },
            panel: {
                PropertyPanelZone(
                    snapshot: viewModel.snapshot,
                    capabilities: viewModel.capabilities
                )
            }
        )
        .background(Theme.editorBackground)
    }
}
