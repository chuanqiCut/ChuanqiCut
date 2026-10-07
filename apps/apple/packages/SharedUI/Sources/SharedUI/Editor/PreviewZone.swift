// SharedUI — 预览区（UIA-003；UIA-032 增强交互）
//
// MTKView 直绘（ARCH-005 §4.3）：画面不经 UI 合成路径，内核渲染的离屏纹理
// 经一次 GPU 拷贝进 drawable。见 MetalPreviewView.swift。
//
// UIA-032：
//   * 点按预览 = 播放/暂停（行业惯例，RESEARCH-004 §6.2 点 4）——走既有
//     togglePlayback（红线 #5：不改模型）；
//   * 空时间线显示引导态（标题 + 主操作），不再是无装饰黑屏。

import SwiftUI
import ChuanqiCut

struct PreviewZone: View {
    let preview: Previewer?
    let pump: PreviewPump?
    let playhead: RationalTime
    /// 连续绘制（播放中）：主线程按 vsync 只做一次拷贝。
    let continuous: Bool
    /// 模型推进代数（UIA-020）：变化即对当前播放头重取帧。
    let renderEpoch: UInt64
    /// 时间线无片段（显示引导态；点按不触发播放）。
    let showsEmptyState: Bool
    /// 点按预览 = 播放/暂停（走既有 togglePlayback）。
    let onTogglePlayback: () -> Void
    /// 引导态主操作（打开媒体抽屉）。
    let onOpenMedia: () -> Void

    var body: some View {
        ZStack {
            if let preview {
                MetalPreviewView(preview: preview, pump: pump, pts: playhead,
                                 continuous: continuous, renderEpoch: renderEpoch)
            } else {
                // 预览后端缺失（如该平台 PAL 未实现预览能力）：如实降级展示，不伪装可用。
                ZStack {
                    Theme.previewBackground

                    VStack(spacing: Theme.Space.s) {
                        Text("预览不可用")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(Theme.secondaryText)

                        Text("当前平台缺少预览后端")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }

            if showsEmptyState {
                emptyStateOverlay
            }

            // 点按 = 播放/暂停。空态时点击交给引导按钮（overlay 在上，收不到）。
            if !showsEmptyState {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTogglePlayback)
            }
        }
    }

    private var emptyStateOverlay: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "film.stack")
                .font(.system(size: 36))
                .foregroundStyle(Theme.tertiaryText)
            Text("导入素材开始创作")
                .font(.headline)
                .foregroundStyle(Theme.secondaryText)
            Button {
                onOpenMedia()
            } label: {
                Label("打开素材库", systemImage: "plus")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(Theme.Space.xl)
        .background(Theme.previewBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.Radius.l))
    }
}
