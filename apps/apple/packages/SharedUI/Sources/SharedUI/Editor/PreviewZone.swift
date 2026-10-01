// SharedUI — 预览区桩视图（UIA-002）
//
// ⚠️ 本文件是**桩**：UIA-003 将用 MTKView 直接嵌入替换（预览画面不经 UI 合成路径，
// 见 ARCH-005 §4.3）。布局尺寸即未来 MTKView 的宿主区域。

import SwiftUI
import ChuanqiCut

struct PreviewZone: View {
    let snapshot: Snapshot

    var body: some View {
        ZStack {
            Theme.previewBackground

            VStack(spacing: 8) {
                Text("Preview")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)

                Text("快照 v\(snapshot.version)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}
