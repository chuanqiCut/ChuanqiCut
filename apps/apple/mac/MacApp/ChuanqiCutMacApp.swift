// ChuanqiCutMacApp — macOS App 入口（UIA-002）
//
// 窗口：默认 1280×720，最小 960×540（Spec §2）。
// ⚠️ 必须在 UI 线程调用 ChuanqiCut.markMainThread()（CORE-008 约束）。

import SwiftUI
import SharedUI
import ChuanqiCut
import ChuanqiCutPlayer  // 播放器域 Pod（ADR-0031 阶段 1）：Launcher/MiniBar/注入装配
import ChuanqiCutImport  // 导入域 Pod：装配 MediaLibraryInjector（相册浏览器）
import ChuanqiCutEditor  // 编辑器域 Pod（ADR-0031 阶段 5）：EditorView/EditorViewModel

@main
struct ChuanqiCutMacApp: App {
    @StateObject private var editor: EditorViewModel
    /// 播放器 App 级门面（UIA-027）：窗口关闭不回收播放，MiniBar 共享。
    @StateObject private var playerController = PlayerController()

    init() {
        ChuanqiCut.markMainThread()
        // ADR-0031：播放器联动装配 —— MediaSheet（编辑器域）经基座注入器弹播放器，
        // 功能 Pod 横向零依赖；PlayerScreen 双 init 语义在此对齐。
        PlayerPreviewInjector.makePlayerPreview = { urls in
            urls.count == 1 ? AnyView(PlayerScreen(url: urls[0]))
                            : AnyView(PlayerScreen(urls: urls))
        }
        // ADR-0031：编辑器 → 相册浏览器装配（MediaSheet 弹导入面板，UIA-013）。
        MediaLibraryInjector.makeAlbumPicker = { onDeliver in
            AnyView(AlbumPickerScreen(onDeliver: onDeliver))
        }
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
                .frame(minWidth: 960, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 720)
        // 独立播放器窗口（UIA-015；控制器模式 = App 级 VM，关窗续播 UIA-027）：
        // macOS 菜单 文件 → 新建视频播放器窗口 打开。
        Window("视频播放器", id: "player") {
            PlayerLauncherScreen(controller: playerController)
                .frame(minWidth: 960, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 720)
        // 菜单栏迷你播控（UIA-027）：标题/进度/播控/打开主窗口
        MenuBarExtra("ChuanqiCut 播放器", systemImage: "play.circle") {
            PlayerMiniBar(controller: playerController)
        }
        .menuBarExtraStyle(.window)
    }
}
