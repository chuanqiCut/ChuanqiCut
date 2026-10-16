// SharedUI — 编辑器布局容器（UIA-002 立骨架；UIA-032 iOS 分支改对标 App 式）
//
// 收敛 `#if os(iOS)` / `#if os(macOS)` 差异到本文件，业务视图不直接写条件编译
// （ui-apple.md 硬约束 #6）。
//
// UIA-032：iOS 竖屏从「桌面三区硬切」改为「单焦点 + 抽屉」（RESEARCH-004 §3.4）：
//   预览弹性占满 → 播放控制条 → 时间线固定条 → 底部工具栏；素材库进底部
//   抽屉（MediaSheet），无常驻属性侧栏。macOS 布局同构保留（惯例化批次原记 UIA-017，已让位，重开取新号）。
//
// 2026-10-15（传哲定「iPad 应该跟 iOS 一致」）：**iOS 不分尺寸类** —— iPhone 与
// iPad、竖屏与横屏，一律走 UIA-034 的 UIKit 三件套容器。原 `regular` 分支（iPad）
// 走的是 macOS 同构布局 + SwiftUI 自绘轨道区，等于 iOS 侧同时存在两套轨道区实现
// （TimelineKit / 自绘）—— 两套交互语义、两套 bug（ADR-0014 同款坑），取消。

import SwiftUI
import SharedUI  // 基座：Theme/注入点（ADR-0031）

// MARK: - 平台差异常量（业务视图经此读取，不写条件编译）

enum EditorPlatform {
    /// 时间线头部（撤销/重做 + 调试版本号）只在 macOS 显示：iOS 的入口在
    /// 底部工具栏。macOS 快捷键挂在头部按钮上（进菜单栏归 macOS 惯例化批次，原 UIA-017 建议位已让位）。
    static var showsTimelineHeader: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

// MARK: - 编辑器布局容器

/// macOS：左侧（Preview + Transport + Timeline 上下排）+ 右侧 MediaLibraryPanel
/// iOS（**不分尺寸类**，含 iPad）：整页交给 UIKit 三件套容器（UIA-034，ADR-0024）
///   —— Preview 弹性 → Transport(44) → TimelineKit 轨道区(140) → BottomToolbar(84)
struct EditorLayoutContainer<Compact: View, Preview: View, Transport: View, Timeline: View,
                              Toolbar: View, Panel: View>: View {
    /// iOS 整页（UIA-034 起 = UIKit 三件套容器，ADR-0024）；macOS 不调用。
    @ViewBuilder let compact: () -> Compact
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let transport: () -> Transport
    @ViewBuilder let timeline: () -> Timeline
    @ViewBuilder let toolbar: () -> Toolbar
    @ViewBuilder let panel: () -> Panel

    var body: some View {
        #if os(macOS)
        macLayout
        #else
        iosLayout
        #endif
    }

    // MARK: - macOS

    #if os(macOS)
    private var macLayout: some View {
        HSplitView {
            // 左侧：Preview + Transport + Timeline 上下排
            VStack(spacing: 0) {
                preview()
                Divider()
                transport()
                    .frame(height: Theme.Size.transportBarHeight)
                timeline()
                    .frame(height: Theme.Size.timelineHeight)
            }

            // 右侧：素材库面板（UIA-032 起与 iOS 抽屉同源）
            panel()
                .frame(minWidth: Theme.Size.panelMinWidth, idealWidth: Theme.Size.panelWidth)
        }
    }
    #endif

    // MARK: - iOS

    #if os(iOS)
    /// iOS（iPhone **与 iPad**、竖屏 **与横屏**）一律同一套：UIKit 三件套容器。
    ///
    /// ⚠️ 2026-10-15 变更（传哲定「iPad 应该跟 iOS 一致」）：此前 `regular` 尺寸类
    /// （iPad 全屏、iPhone Plus/Max 横屏）走 `horizontalLayout` —— 那是 macOS 同构布局，
    /// 轨道区用的是 **SwiftUI 自绘版 `EditorTimelineView`**，与 iPhone 的 TimelineKit
    /// 轨道区是**两套实现**。两套轨道区 = 两套交互语义 + 两套 bug（ADR-0014 同款坑），
    /// 故 iOS 侧直接取消尺寸类分支：只有一条轨道区实现，也就只有一份行为。
    ///
    /// 代价（如实记账）：iPad 不再有常驻右栏 `MediaLibraryPanel` —— 素材库改走
    /// 底栏「媒体」→ MediaSheet 抽屉，与 iPhone 完全同路径。
    private var iosLayout: some View { compact() }
    #endif
}
