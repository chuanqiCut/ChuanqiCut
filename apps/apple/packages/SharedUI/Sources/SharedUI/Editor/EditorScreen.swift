// SharedUI — 编辑器入口屏（CAM-004）
//
// 职责：把 EditorViewModel 的创建从 App.init 迁到「进编辑器」时机（首页形态的前提，
// 见 SPEC-CAM-001 v1.1 §7 / ADR-0014）。构造语义遵循 pitfalls P8：**先建值后包装** ——
// 可抛构造先跑成功，才放进 @State；失败展示错误页，不让 App 启动期 fatalError。
//
// 为什么不用 @StateObject：EditorViewModel.init 会 throw，而
// StateObject(wrappedValue:) 只吃非 throwing 自动闭包；包一层 Optional @State
// + 显式创建点，语义最直白。

import SwiftUI

public struct EditorScreen: View {
    /// 录制产物入口（CAM-005）：非 nil 时进入编辑器即自动导入该视频。
    public let initialMediaURL: URL?

    @State private var model: EditorViewModel?
    @State private var failureText: String?
    @State private var didImportInitialMedia = false

    public init(initialMediaURL: URL? = nil) {
        self.initialMediaURL = initialMediaURL
    }

    public var body: some View {
        Group {
            if let model {
                EditorView().environmentObject(model)
                    .task { importInitialMediaIfNeeded(model) }
            } else if let failureText {
                // iOS 16 兼容：不用 iOS 17 的 ContentUnavailableView。
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("编辑器初始化失败").font(.headline)
                    Text(failureText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                ProgressView("正在初始化编辑器…")
                    .onAppear(perform: createModel)
            }
        }
    }

    private func createModel() {
        guard model == nil else { return }
        do {
            let viewModel = try EditorViewModel()
#if DEBUG
            // UIA-003 启动冒烟钩子：无初始导入时才装演示片段（有录制产物时以产物为准）。
            if initialMediaURL == nil {
                _ = viewModel.installDemoClipFromEnvironment()
            }
#endif
            model = viewModel
        } catch {
            failureText = String(describing: error)
        }
    }

    private func importInitialMediaIfNeeded(_ viewModel: EditorViewModel) {
        guard !didImportInitialMedia, let url = initialMediaURL else { return }
        didImportInitialMedia = true
        // importMedia 是主线程用户动作级操作（同步探测时长 + 提交命令），直接调用。
        // 失败不闪退：素材库会显示失效标记，这里只吞掉状态（诊断进内核日志）。
        _ = viewModel.importMedia(url: url)
    }
}
