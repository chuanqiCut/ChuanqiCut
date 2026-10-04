// SharedUI — 右侧面板：素材库（UIA-009 子步骤 3 + UIA-011 相册入口）+ 属性桩（UIA-002/006）
//
// 素材库两条导入入口，汇入同一 EditorViewModel.importMedia（Spec UIA-011 §2）：
//   * 从文件导入：fileImporter（"文件"App 路径）
//   * 从相册导入：PhotosPicker（系统进程外选择器，**无需** NSPhotoLibraryUsageDescription）
// D3 决策不变：MVP 引用原路径不拷贝入库 —— 相册视频由系统落到 tmp 的 URL 在
// App 重启后可能被清理，届时同样显示「已失效」，与文件路径行为一致；
// 素材库整理（拷入沙箱）是后续任务，两条路径届时统一收口。
// 属性区仍是桩：UIA-006 接入真实参数（变更必须走 Command）。

import SwiftUI
import ChuanqiCut
import PhotosUI
import UniformTypeIdentifiers

struct PropertyPanelZone: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    @State private var showImporter = false
    @State private var importError: String?

    // UIA-011：相册导入。selection 清空复用见 onChange 注释；加载态/错误自持在
    // PhotoLibraryImporter（AppEntry 的 importMedia 及其 importInFlight 保持零改动）。
    @State private var photoItem: PhotosPickerItem?
    @StateObject private var photosImporter = PhotoLibraryImporter()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("素材库")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            // 导入入口：文件 / 相册（两条路汇入同一 importMedia）
            VStack(spacing: 8) {
                Button {
                    showImporter = true
                } label: {
                    Label("从文件导入", systemImage: "plus.rectangle.on.folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // 只选视频（与文件入口白名单 movie/video/mpeg4Movie 对齐）、单选。
                PhotosPicker(selection: $photoItem, matching: .videos) {
                    Label(photosImporter.isLoading ? "正在读取相册素材…" : "从相册导入",
                          systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(photosImporter.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let importError {
                Text(importError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            if let photoError = photosImporter.errorMessage {
                Text(photoError)
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
        // 相册选取：item → 系统 tmp 文件 URL → 既有 importMedia（导入链路零分叉）。
        // loadTransferable 挂起等系统出文件（iCloud 素材可能慢），不阻塞主线程。
        .onChange(of: photoItem) { item in
            guard let item else { return }
            // onChange 闭包非 actor 隔离：显式跳 MainActor（同 applySnapshot 手法，
            // Swift 6 并发模型不自动继承），状态变更与 @MainActor 胶水都在主线程。
            Task { @MainActor in
                await photosImporter.run(
                    resolveURL: { try await item.loadTransferable(type: URL.self) },
                    importURL: { viewModel.importMedia(url: $0) })
                // 清空 selection：PhotosPickerItem 按 itemIdentifier 判等，
                // 不清空则"再次选取同一条素材"不会触发 onChange。
                photoItem = nil
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

// MARK: - 相册导入胶水（UIA-011）

/// 相册选取项 → 临时文件 URL → 既有 importMedia 的胶水，加载态 / 错误信息自持。
///
/// resolveURL / importURL 全部注入：loadTransferable 需要真实 PHAsset，
/// XCTest 宿主没有相册数据 —— 注入后状态机（loading 翻转、失败不产生素材）
/// 可以脱离相册单测（PhotoImportTests）。生产接线在 PropertyPanelZone.onChange。
///
/// @MainActor：两个闭包都是主线程语义（importMedia 是"用户动作、低频"的同步
/// 调用，见 AppEntry.importMedia 注释）；错误与 loading 直接驱动 UI。
@MainActor
final class PhotoLibraryImporter: ObservableObject {

    /// 正在把相册素材读成文件（iCloud 下载可能持续数秒）。按钮据此置灰防重复。
    @Published private(set) var isLoading = false

    /// 最近一次相册导入的失败信息；nil = 无失败（含成功清空旧错误的语义）。
    @Published var errorMessage: String?

    /// 执行一次相册导入。resolveURL 产出系统落盘的临时文件 URL；
    /// importURL 把该 URL 汇入既有导入链路（生产 = viewModel.importMedia）。
    /// 任何失败只置 errorMessage，不产生素材 / 片段（干净失败，同 importMedia 语义）。
    func run(resolveURL: () async throws -> URL?, importURL: (URL) -> Status) async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let url = try await resolveURL() else {
                errorMessage = "相册素材无法读取（类型不受支持）"
                return
            }
            let status = importURL(url)
            errorMessage = status.isOK ? nil : "导入失败：\(status.text)"
        } catch {
            errorMessage = "相册读取失败：\(error.localizedDescription)"
        }
    }
}
