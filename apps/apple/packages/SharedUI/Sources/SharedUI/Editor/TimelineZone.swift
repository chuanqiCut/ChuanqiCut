// SharedUI — 时间线区桩视图（UIA-002）
//
// ⚠️ 本文件是**桩**：UIA-004 将用自绘视图（Metal/Canvas）替换 —— 时间线不把每个
// 片段做成 UI 组件（ARCH-005 §5，数百片段会掉帧）。播放头/轨道占位仅示意布局。

import SwiftUI
import ChuanqiCut

struct TimelineZone: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(spacing: 0) {
            // 播放头指示（桩：固定 30% 位置，自绘视图落地后由播放头状态驱动）
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.playhead)
                    .frame(width: 1.5)
                    .offset(x: geo.size.width * 0.3)
            }
            .frame(height: 14)

            Divider()

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
            .frame(height: 28)

            // 占位轨道（UIA-004 替换）
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.trackFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.trackStroke, lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.timelineBackground)
    }
}
