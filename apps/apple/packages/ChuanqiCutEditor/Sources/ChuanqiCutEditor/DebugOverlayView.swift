// SharedUI — DEBUG 实时诊断浮层（B-02 批，2026-10-11；2026-10-15 改竖排/可滑动/可移动/可隐藏）
//
// 职责：把「预览链路现在健康吗」钉在画面上——帧率（泵/呈现）、音频块流、
// 丢帧/欠载/重锚、tick p95、内存足迹、轨道/片段数。数据来自 EditorDebugSnapshot
// （EditorViewModel 以 2Hz 采样发布）。
//
// 交互（传哲 2026-10-15）：竖排展示可滑动（面板更高、内容滚动）；整体可拖动
// （宿主在 UIKit 侧更新约束）；可隐藏（收成小圆钮）/ 可展开。尺寸参照播放按钮区域。
//
// 视觉（传哲 2026-10-15「颜色用之前的字体和颜色」）：沿用 SharedUI DebugPanelView
// 的**绿字等宽**调性（.foregroundStyle(.green) + 10pt monospaced），但尺寸更高、
// 内容可滚动、并显式给出帧率（FPS）行；底部半透明（黑 0.5）让预览透出。

import SwiftUI
import UIKit
import SharedUI

/// 跨 2Hz 快照更新的持久状态：隐藏/展开不随每次刷新重置（iOS 宿主持有同一实例）。
final class DebugOverlayState: ObservableObject {
    @Published var snapshot: EditorDebugSnapshot?
    @Published var hidden = false
}

struct DebugOverlayView: View {
    @ObservedObject var state: DebugOverlayState
    var onDrag: (CGFloat, CGFloat) -> Void = { _, _ in }

    @State private var lastDrag: CGPoint?

    var body: some View {
        Group {
            if state.hidden {
                hiddenButton
            } else {
                expandedPanel
            }
        }
    }

    private var hiddenButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { state.hidden = false }
        } label: {
            Image(systemName: "gauge")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
                .overlay(Circle().stroke(.green.opacity(0.35), lineWidth: 1))
        }
        .simultaneousGesture(dragGesture)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().background(.green.opacity(0.25))
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
            }
            // 传哲 2026-10-16「高度=屏幕 35% / 宽度放宽 / 竖排 key:value」：
            // ScrollView 填剩余高度——行少不滚、行多自滚；绿字等宽竖排保持。
            .frame(maxHeight: .infinity)
        }
        // 整块面板钉死：高=屏高 35%、宽=min(屏宽-16, 380)（比原来的 300 更宽）。
        // 底部半透明（黑 0.5）：预览透出，不挡画面。绿字等宽 = 沿用 DebugPanel 调性。
        .background(Color.black.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.green.opacity(0.3), lineWidth: 1))
        .cornerRadius(10)
        .frame(width: min(UIScreen.main.bounds.width - 16, 380),
               height: UIScreen.main.bounds.height * 0.35)
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.horizontal.3")
                .foregroundStyle(.green.opacity(0.7))
                .font(.system(size: 11, weight: .medium))
            Text(header)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.green)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { state.hidden = true }
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(.green.opacity(0.9))
                    .font(.system(size: 12, weight: .bold))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.28))
        .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if let last = lastDrag {
                    onDrag(value.location.x - last.x, value.location.y - last.y)
                }
                lastDrag = value.location
            }
            .onEnded { _ in lastDrag = nil }
    }

    private var header: String {
        guard let s = state.snapshot else { return "DEBUG" }
        return "\(s.isPlaying ? "▶" : "⏸") t=\(String(format: "%.2f", s.playheadSeconds))s"
    }

    // 传哲 2026-10-15「加上帧率之类的」：把帧率摊在前面——渲染泵吞吐 + 呈现帧率
    // 单独成行，tick p95 / 合并 / 失败 / 音频 / 内存 / 轨道数随后。
    private var lines: [String] {
        guard let s = state.snapshot else { return ["（无数据）"] }
        let fps = String(format: "%.0f", s.pumpRenderedPerSec)
        let draw = String(format: "%d", s.drawPerSec)
        let req = String(format: "%.0f", s.pumpReqPerSec)
        let coalesced = String(format: "%.0f", s.pumpCoalescedPerSec)
        let nonOk = String(format: "%.0f", s.pumpNonOkPerSec)
        let audio = String(format: "%.0f", s.audioBlocksPerSec)
        return [
            "FPS  渲染 \(fps)/s  呈现 \(draw)/s",
            "tick p95 \(s.tickP95Ms)ms  合并 \(coalesced)/s",
            "请求 \(req)/s  失败 \(nonOk)/s",
            "音频 \(audio)/s  丢 \(s.audioDropped)  欠 \(s.audioUnderruns)  重锚 \(s.audioResyncs)",
            "内存 \(String(format: "%.0f", s.footprintMB))MB  轨 \(s.trackCount)  片段 \(s.clipCount)",
        ]
    }
}

extension DebugOverlayView {
    /// SwiftUI 预览槽位（macOS / iPad 横屏）用的便捷入口：每帧重建足矣，无需持久状态。
    init(snapshot: EditorDebugSnapshot) {
        let s = DebugOverlayState()
        s.snapshot = snapshot
        _state = ObservedObject(wrappedValue: s)
    }
}
