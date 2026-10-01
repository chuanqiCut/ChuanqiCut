// SharedUI — 编辑器三区布局容器（UIA-002）
//
// 收敛 `#if os(iOS)` / `#if os(macOS)` 差异到本文件，业务视图不直接写条件编译。

import SwiftUI

// MARK: - 编辑器布局容器

/// macOS：左侧（Preview+Timeline 上下分）+ 右侧 PropertyPanel
/// iOS 竖屏：Preview / Timeline / PropertyPanel 上中下
/// iOS 横屏：与 macOS 同构
struct EditorLayoutContainer<Preview: View, Timeline: View, Panel: View>: View {
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let timeline: () -> Timeline
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
            // 左侧：Preview 上 + Timeline 下
            VStack(spacing: 0) {
                preview()
                Divider()
                timeline()
                    .frame(height: Theme.Size.timelineHeight)
            }

            // 右侧：PropertyPanel
            panel()
                .frame(minWidth: Theme.Size.panelMinWidth, idealWidth: Theme.Size.panelWidth)
        }
    }
    #endif

    // MARK: - iOS

    #if os(iOS)
    private var iosLayout: some View {
        if hSizeClass == .compact {
            // 竖屏：上中下
            verticalLayout
        } else {
            // 横屏：与 macOS 同构
            horizontalLayout
        }
    }

    private var verticalLayout: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                preview()
                    .frame(height: geo.size.height * 0.60)

                Divider()

                timeline()
                    .frame(height: geo.size.height * 0.25)

                Divider()

                panel()
                    .frame(minHeight: geo.size.height * 0.15)
            }
        }
    }

    private var horizontalLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                preview()
                Divider()
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
