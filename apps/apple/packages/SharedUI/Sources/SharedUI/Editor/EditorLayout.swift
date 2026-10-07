// SharedUI — 编辑器布局容器（UIA-002 立骨架；UIA-032 iOS 分支改剪映式）
//
// 收敛 `#if os(iOS)` / `#if os(macOS)` 差异到本文件，业务视图不直接写条件编译
// （ui-apple.md 硬约束 #6）。
//
// UIA-032：iOS 竖屏从「桌面三区硬切」改为「单焦点 + 抽屉」（RESEARCH-004 §3.4）：
//   预览弹性占满 → 播放控制条 → 时间线固定条 → 底部工具栏；素材库进底部
//   抽屉（MediaSheet），无常驻属性侧栏。macOS 布局同构保留（惯例化批次原记 UIA-017，已让位，重开取新号）。

import SwiftUI

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
/// iOS 竖屏（compact）：Preview 弹性 → Transport → Timeline(140) → BottomToolbar
/// iOS 横屏（regular）：与 macOS 同构 + 右栏面板
struct EditorLayoutContainer<Preview: View, Transport: View, Timeline: View,
                              Toolbar: View, Panel: View>: View {
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let transport: () -> Transport
    @ViewBuilder let timeline: () -> Timeline
    @ViewBuilder let toolbar: () -> Toolbar
    @ViewBuilder let panel: () -> Panel

    @Environment(\.horizontalSizeClass) private var hSizeClass

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
    // ⚠️ 必须 @ViewBuilder：if/else 两分支的 opaque 类型不同（vertical vs
    //    horizontal），裸 `some View` 下 Swift 6 报 mismatching types。
    //    该 iOS 分支此前从未被编译过（真机不可用），INFRA-009 首次暴露。
    @ViewBuilder
    private var iosLayout: some View {
        if hSizeClass == .compact {
            // 竖屏（UIA-032 剪映式）：单焦点 + 抽屉
            verticalLayout
        } else {
            // 横屏：与 macOS 同构
            horizontalLayout
        }
    }

    private var verticalLayout: some View {
        VStack(spacing: 0) {
            preview()
                .frame(maxHeight: .infinity)   // 预览最大化：吃掉全部剩余高度

            transport()
                .frame(height: Theme.Size.transportBarHeight)

            Divider()

            timeline()
                .frame(height: Theme.Size.timelineHeightCompact)

            toolbar()
                .frame(height: Theme.Size.bottomToolbarHeight)
        }
    }

    private var horizontalLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                preview()
                Divider()
                transport()
                    .frame(height: Theme.Size.transportBarHeight)
                timeline()
                    .frame(height: Theme.Size.timelineHeight)
            }

            Divider()

            panel()
                .frame(width: Theme.Size.panelWidth)
        }
    }
    #endif
}
