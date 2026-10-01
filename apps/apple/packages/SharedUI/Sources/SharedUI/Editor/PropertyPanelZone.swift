// SharedUI — 属性面板桩视图（UIA-002）
//
// ⚠️ 本文件是**桩**：UIA-006 将接入真实参数（变换/调色/滤镜），且参数变更
// 必须走 Command（`viewModel.submit`）—— 本桩不含任何可写状态。

import SwiftUI
import ChuanqiCut

struct PropertyPanelZone: View {
    let snapshot: Snapshot
    var capabilities: [Capability: CapabilityValue] = [:]

    /// 占位分组标题；UIA-006 替换为真实参数模型。
    private let groups = ["变换", "调色", "滤镜"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Properties")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            ForEach(groups, id: \.self) { group in
                HStack {
                    Text(group)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Text("—")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()
            }

            Spacer(minLength: 0)

            // 诊断页脚：快照版本 + 硬解能力（中端机降级提示的挂载点）
            VStack(alignment: .leading, spacing: 2) {
                Text("v\(snapshot.version)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.tertiaryText)
                Text(capabilitySummary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(Theme.panelBackground)
    }

    private var capabilitySummary: String {
        guard capabilities.isEmpty else {
            let hwDecode = capabilities[.hwDecodeH264] ?? .no
            return "hw264: \(hwDecode == .yes ? "yes" : "no")"
        }
        return "caps: pending"
    }
}
