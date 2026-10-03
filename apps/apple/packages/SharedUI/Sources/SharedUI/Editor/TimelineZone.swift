// SharedUI — 时间线区（UIA-004）：宿主 Canvas 自绘视图
//
// 自绘本体在 Timeline/EditorTimelineView.swift（单 Canvas，几何在 TimelineLayout）。
// 头部保留快照版本指示（与 UIA-002 桩的行为连续，便于肉眼确认刷新）。

import SwiftUI
import ChuanqiCut

struct TimelineZone: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Timeline")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("v\(snapshot.version)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 24)

            Divider()

            EditorTimelineView()
        }
        .background(Theme.timelineBackground)
    }
}
