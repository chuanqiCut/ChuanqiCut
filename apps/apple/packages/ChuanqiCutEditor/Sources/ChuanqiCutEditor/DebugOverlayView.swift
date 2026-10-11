// SharedUI — DEBUG 实时诊断浮层（B-02 批，2026-10-11）
//
// 职责：把「预览链路现在健康吗」钉在画面上——帧率（泵/呈现）、音频块流、
// 丢帧/欠载/重锚、tick p95、内存足迹、轨道/片段数。数据全部来自
// EditorDebugSnapshot（EditorViewModel 以 2Hz 采样发布，播放/暂停均可用）。
//
// 可见性：DEBUG 构建才有开关入口（传输条天线按钮 + CQ_DEBUG_OVERLAY=1 默认开）；
// Release 不编译（与 playback-perf 剖面同口径）。后续整体设置模块接管开关
// （传哲 2026-10-11），本视图只吃快照，不感知开关来源。

import SwiftUI

struct DebugOverlayView: View {
    let snapshot: EditorDebugSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header).font(.system(size: 10, weight: .bold).monospaced())
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 10).monospaced())
            }
        }
        .foregroundStyle(.green)
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)   // 纯展示：不吃预览区手势
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
    }

    private var header: String {
        "\(snapshot.isPlaying ? "▶" : "⏸") t=\(String(format: "%.2f", snapshot.playheadSeconds))s"
    }

    private var lines: [String] {
        [
            "pump  req \(fmt(snapshot.pumpReqPerSec))/s  drawn \(fmt(snapshot.pumpRenderedPerSec))/s"
                + "  coalesced \(fmt(snapshot.pumpCoalescedPerSec))/s  nonok \(fmt(snapshot.pumpNonOkPerSec))/s",
            "audio blk \(fmt(snapshot.audioBlocksPerSec))/s  drop \(snapshot.audioDropped)"
                + "  under \(snapshot.audioUnderruns)  resync \(snapshot.audioResyncs)",
            "tick p95 \(snapshot.tickP95Ms)ms  draw \(snapshot.drawPerSec)/s"
                + "  mem \(String(format: "%.0f", snapshot.footprintMB))MB",
            "tracks \(snapshot.trackCount)  clips \(snapshot.clipCount)",
        ]
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.0f", v)
    }
}
