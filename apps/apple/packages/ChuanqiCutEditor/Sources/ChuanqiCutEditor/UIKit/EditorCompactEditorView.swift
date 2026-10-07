#if os(iOS)
// EditorCompactEditorView — SwiftUI 壳 ↔ UIKit 编辑页桥（UIA-034，ADR-0024）
//
// iOS 竖屏（compact）整页交给 EditorViewController；媒体抽屉（MediaSheet sheet）
// 仍由 SwiftUI 壳持有（ADR-0024 决定 2：外层保持 SwiftUI）——工具栏「媒体」
// 经 onOpenMedia 回调触发。

import SwiftUI
import SharedUI  // 基座：Theme（ADR-0031）

struct EditorCompactEditorView: UIViewControllerRepresentable {
    let viewModel: EditorViewModel
    let onOpenMedia: () -> Void

    func makeUIViewController(context: Context) -> EditorViewController {
        EditorViewController(viewModel: viewModel, onOpenMedia: onOpenMedia)
    }

    func updateUIViewController(_ controller: EditorViewController, context: Context) {
        controller.setOnOpenMedia(onOpenMedia)
    }
}
#endif
