// ChuanqiCutMacApp — macOS App 入口（UIA-002）
//
// 窗口：默认 1280×720，最小 960×540（Spec §2）。
// ⚠️ 必须在 UI 线程调用 ChuanqiCut.markMainThread()（CORE-008 约束）。

import SwiftUI
import SharedUI
import ChuanqiCut

@main
struct ChuanqiCutMacApp: App {
    @StateObject private var editor: EditorViewModel

    init() {
        ChuanqiCut.markMainThread()
        do {
            // 先创建再包进 StateObject：wrappedValue 是非 throwing 自动闭包，
            // 不能直接写 `StateObject(wrappedValue: try ...)`。
            let viewModel = try EditorViewModel()
            _editor = StateObject(wrappedValue: viewModel)
        } catch {
            // 内核会话创建失败 = 静态库未链接或线程启动失败，启动即失败是诚实的做法
            fatalError("ChuanqiCut 内核会话创建失败：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            EditorView()
                .environmentObject(editor)
                .frame(minWidth: 960, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 720)
    }
}
