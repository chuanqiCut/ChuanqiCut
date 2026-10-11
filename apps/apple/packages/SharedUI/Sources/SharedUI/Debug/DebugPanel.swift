// SharedUI — DEBUG 诊断面板（ADR-0040；原 ChuanqiCutDebug 独立 Pod 实验收编）
//
// 职责：跨屏共享的「绿字等宽浮层」渲染 + DEBUG 默认态助手。
// 各屏（编辑器/相机）自产快照结构并喂 `lines`，本文件只管长什么样。
// ⚠️ 本文件不带 #if DEBUG：消费端（编辑器/相机调用点）自行门控；
//    Release 下无人引用，链接期死码剔除，等效零产物。
//    （不带门控的原因见 ADR-0040 附录：独立 DEBUG Pod 的条件编译
//    在 CocoaPods 聚合构建下有符号可见性陷阱。）

import SwiftUI

/// 共享诊断面板：绿字等宽、左上角、不吃手势（叠在预览/相机画面上）。
/// `title` = 状态行（如 ▶ t=1.23s / ⏺ 前摄），`lines` = 数据行（每行一条）。
public struct DebugPanelView: View {
    public let title: String
    public let lines: [String]

    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .bold).monospaced())
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 10).monospaced())
            }
        }
        .foregroundStyle(.green)
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)   // 纯展示：不吃底层手势
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
    }
}

public enum DebugDefaults {
    /// DEBUG 浮层是否默认开：CQ_DEBUG_OVERLAY=1 强制开；探针模式（CQ_CAM_PROBE）
    /// 也默认开。图标正常启动 = 关（顶栏/传输条天线按钮可开）。
    /// 约定：调用方仍以自己的开关属性为准，本值只是**初始态**建议。
    public static var overlayDefaultOn: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CQ_DEBUG_OVERLAY"] == "1" || env["CQ_CAM_PROBE"] != nil
    }
}
