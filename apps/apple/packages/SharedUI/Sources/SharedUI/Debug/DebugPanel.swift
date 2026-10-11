// SharedUI — DEBUG 诊断面板（ADR-0040；原 ChuanqiCutDebug 独立 Pod 实验收编）
//
// 职责：跨屏共享的「绿字等宽浮层」渲染 + DEBUG 默认态助手。
// 各屏（编辑器/相机）自产快照结构并喂 `lines`，本文件只管长什么样。
// ⚠️ 本文件不带 #if DEBUG：消费端（编辑器/相机调用点）自行门控；
//    Release 下无人引用，链接期死码剔除，等效零产物。
//    （不带门控的原因见 ADR-0040 附录：独立 DEBUG Pod 的条件编译
//    在 CocoaPods 聚合构建下有符号可见性陷阱。）

import SwiftUI

/// 共享诊断面板：绿字等宽浮层，**拖拽手柄 + 内容滚动**（数据多时滚动查看，
/// 位置偏移经 UserDefaults 持久化——每个 storageKey 一份，跨启动保留）。
/// 锚定 topLeading，offset 从默认位拖走；回到默认 = 双击手柄。
public struct DebugPanelView: View {
    public let title: String
    public let lines: [String]
    /// 行多时内容区滚动（面板高度钳制，拖动手柄独立于内容）。
    public var scrollable: Bool = false
    /// 拖动偏移的持久化键（不同屏/不同面板各自一份）。
    public var storageKey: String = "debug.panel.default"
    /// 面板内容最大高度（scrollable 时）。
    public var contentMaxHeight: CGFloat = 260

    @State private var dragOffset: CGSize = .zero
    @State private var dragging = false
    @State private var storedOffset: CGSize = .zero

    public init(title: String, lines: [String], scrollable: Bool = false,
                storageKey: String = "debug.panel.default",
                contentMaxHeight: CGFloat = 260) {
        self.title = title
        self.lines = lines
        self.scrollable = scrollable
        self.storageKey = storageKey
        self.contentMaxHeight = contentMaxHeight
        _storedOffset = State(initialValue: CGSize(
            width: UserDefaults.standard.double(forKey: storageKey + ".x"),
            height: UserDefaults.standard.double(forKey: storageKey + ".y")))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 拖拽手柄（ grabbing 条：全宽 18pt，双击回默认位）
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 34, height: 4)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .onTapGesture(count: 2) {
                    storedOffset = .zero
                    persist()
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10, weight: .bold).monospaced())
                panelContent
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .foregroundStyle(.green)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 280, alignment: .leading)
        .offset(x: storedOffset.width + dragOffset.width,
                y: storedOffset.height + dragOffset.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
    }

    @ViewBuilder
    private var panelContent: some View {
        if scrollable {
            ScrollView(.vertical) {
                linesView
            }
            .frame(maxHeight: contentMaxHeight)
        } else {
            linesView
        }
    }

    private var linesView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 10).monospaced())
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                dragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                dragging = false
                storedOffset = CGSize(width: storedOffset.width + value.translation.width,
                                      height: storedOffset.height + value.translation.height)
                dragOffset = .zero
                persist()
            }
    }

    private func persist() {
        UserDefaults.standard.set(storedOffset.width, forKey: storageKey + ".x")
        UserDefaults.standard.set(storedOffset.height, forKey: storageKey + ".y")
    }
}
