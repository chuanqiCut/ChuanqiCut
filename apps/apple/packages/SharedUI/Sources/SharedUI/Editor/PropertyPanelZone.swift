// SharedUI — 右侧面板：素材库（UIA-009 子步骤 3）+ 属性桩（UIA-002/006）
//
// 素材库：导入按钮（fileImporter）+ 已注册素材列表（含失效标记）。
//   D3 决策：MVP **引用原路径**不拷贝入库 —— 文件移走后 `exists == false`
//   标记失效，渲染侧以 kInvalidArgument 暴露。素材库整理（拷入沙箱）后续任务。
// 属性区仍是桩：UIA-006 接入真实参数（变更必须走 Command）。

import SwiftUI
import ChuanqiCut
import UniformTypeIdentifiers

struct PropertyPanelZone: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("素材库")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            // 导入按钮
            Button {
                showImporter = true
            } label: {
                Label("导入素材", systemImage: "plus.rectangle.on.folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let importError {
                Text(importError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            // 素材列表（失效标记：exists == false）
            if viewModel.mediaLibrary.isEmpty {
                Text("尚未导入素材")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            } else {
                ForEach(viewModel.mediaLibrary) { asset in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: asset.exists ? "film" : "film.fill.slash")
                                .foregroundStyle(asset.exists ? Theme.secondaryText : .red)
                            Text("素材 \(asset.id)")
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.primaryText)
                            if asset.pathTruncated {
                                Text("路径超长")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(asset.exists ? asset.path : "⚠ 文件不在原路径（已失效）")
                            .font(.caption2.monospaced())
                            .foregroundStyle(asset.exists ? Theme.tertiaryText : .red)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    Divider()
                }
            }

            Divider()

            Text("Properties")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            // 占位分组；UIA-006 替换为真实参数模型。
            ForEach(["变换", "调色", "滤镜"], id: \.self) { group in
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
                Text("v\(viewModel.snapshot.version)")
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
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.movie, .video, .mpeg4Movie]) { result in
            switch result {
            case .success(let url):
                let status = viewModel.importMedia(url: url)
                if !status.isOK {
                    importError = "导入失败：\(status.text)"
                } else {
                    importError = nil
                }
            case .failure(let error):
                importError = "选择失败：\(error.localizedDescription)"
            }
        }
    }

    private var capabilitySummary: String {
        let caps = viewModel.capabilities
        guard !caps.isEmpty else { return "caps: pending" }
        let hwDecode = caps[.hwDecodeH264] ?? .no
        return "hw264: \(hwDecode == .yes ? "yes" : "no")"
    }
}
