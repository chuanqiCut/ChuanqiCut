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
import ChuanqiCutEngine
import ChuanqiCutPlayer  // 播放器域 Pod（ADR-0031）；装配 PlayerPreviewInjector
import ChuanqiCutImport  // 导入域 Pod：装配 MediaLibraryInjector（相册浏览器）
import ChuanqiCutEditor  // 编辑器域 Pod：EditorScreen/HomeView 播放入口

@main
struct ChuanqiCutApp: App {
    /// DEBUG 冒烟/截图辅助（UIA-032）：`CQ_AUTO_ROUTE=editor` 直进编辑器，
    /// 绕过首页 —— 与 CQ_DEMO_VIDEO 同模式的启动钩子（模拟器无法脚本点按时
    /// 的自动化入口；真机走查与正式路径不依赖本方法）。
    #if DEBUG
    private let autoEnterEditor =
        ProcessInfo.processInfo.environment["CQ_AUTO_ROUTE"] == "editor"
    #endif

    init() {
        ChuanqiCut.markMainThread()
        // ADR-0031：播放器联动装配 —— MediaSheet（编辑器域）经基座注入器弹播放器，
        // 功能 Pod 横向零依赖；PlayerScreen 双 init 语义在此对齐。
        PlayerPreviewInjector.makePlayerPreview = { urls in
            urls.count == 1 ? AnyView(PlayerScreen(url: urls[0]))
                            : AnyView(PlayerScreen(urls: urls))
        }
        // ADR-0031：相机 → 编辑器装配 —— 录制产物进编辑器（CameraView 消费注入点）。
        EditorEntryInjector.makeEditor = { url in
            AnyView(EditorScreen(initialMediaURL: url))
        }
        // ADR-0031：编辑器 → 相册浏览器装配（MediaSheet 弹导入面板，UIA-013）。
        MediaLibraryInjector.makeAlbumPicker = { onDeliver in
            AnyView(AlbumPickerScreen(onDeliver: onDeliver))
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if autoEnterEditor {
                EditorScreen()
            } else {
                HomeView()
            }
            #else
            HomeView()
            #endif
        }
    }
}
