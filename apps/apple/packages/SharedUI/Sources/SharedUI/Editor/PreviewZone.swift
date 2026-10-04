// SharedUI — 预览区（UIA-003）
//
// MTKView 直绘（ARCH-005 §4.3）：画面不经 UI 合成路径，内核渲染的离屏纹理
// 经一次 GPU 拷贝进 drawable。见 MetalPreviewView.swift。

import SwiftUI
import ChuanqiCut

struct PreviewZone: View {
    let preview: Previewer?
    let pump: PreviewPump?
    let playhead: RationalTime
    /// 连续绘制（播放中）：主线程按 vsync 只做一次拷贝。
    let continuous: Bool

    var body: some View {
        if let preview {
            MetalPreviewView(preview: preview, pump: pump, pts: playhead,
                             continuous: continuous)
        } else {
            // 预览后端缺失（如该平台 PAL 未实现预览能力）：如实降级展示，不伪装可用。
            ZStack {
                Theme.previewBackground

                VStack(spacing: 8) {
                    Text("预览不可用")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)

                    Text("当前平台缺少预览后端")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }
}
