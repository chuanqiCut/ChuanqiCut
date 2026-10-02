// ChuanqiCutApp — iOS App 入口（UIA-002）
//
// ⚠️ 必须在 UI 线程调用 ChuanqiCut.markMainThread()（CORE-008 约束）：
//    漏调不会报错，只会让「主线程零阻塞」守卫静默失效。

import SwiftUI
import SharedUI
import ChuanqiCut

@main
struct ChuanqiCutApp: App {
    @StateObject private var editor: EditorViewModel

    init() {
        ChuanqiCut.markMainThread()
        do {
            // 先创建再包进 StateObject：wrappedValue 是非 throwing 自动闭包，
            // 不能直接写 `StateObject(wrappedValue: try ...)`。
            let viewModel = try EditorViewModel()
            // UIA-003 启动冒烟钩子（DEBUG）：CQ_DEMO_VIDEO 指向存在的视频时，
            // 载入演示片段并播到 0.5s；否则无操作，预览黑屏等 UIA-005 导入流程。
#if DEBUG
            viewModel.installDemoClipFromEnvironment()
#endif
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
        }
    }
}
