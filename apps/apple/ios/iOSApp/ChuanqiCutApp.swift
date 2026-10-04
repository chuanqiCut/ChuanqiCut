// ChuanqiCutApp — iOS App 入口（CAM-004 重构：首页两入口）
//
// ⚠️ 必须在 UI 线程调用 ChuanqiCut.markMainThread()（CORE-008 约束）：
//    漏调不会报错，只会让「主线程零阻塞」守卫静默失效。
//
// 变更（CAM-004）：root 从 EditorView 改为 HomeView；EditorViewModel（含内核
// Session）从 App.init 迁到 SharedUI.EditorScreen 惰性创建 —— 进编辑器才付
// Session 成本（SPEC-CAM-001 v1.1 §7，ADR-0014）。DEBUG 演示片段钩子随迁到
// EditorScreen（无录制产物入口时才装，互斥语义见该文件注释）。

import SwiftUI
import SharedUI
import ChuanqiCut

@main
struct ChuanqiCutApp: App {
    init() {
        ChuanqiCut.markMainThread()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
