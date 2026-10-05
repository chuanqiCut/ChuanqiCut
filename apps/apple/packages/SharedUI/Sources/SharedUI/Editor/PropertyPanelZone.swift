// SharedUI — 右侧面板：素材库（UIA-009 子步骤 3 + UIA-011/012 相册入口 + UIA-013 自研相册浏览器）+ 属性桩（UIA-002/006）
//
// 素材库两条导入入口，汇入同一 EditorViewModel.importMedia（Spec UIA-011 §2）：
//   * 从文件导入：fileImporter（"文件"App 路径）
//   * 从相册导入：UIA-013 起为自研相册浏览器（MediaPicker/，Spec UIA-013）——
//     网格/相簿/多选序号/时长过滤/iCloud 拉取/受限模式；确认后交付文件 URL
//     列表，走与 UIA-012 完全相同的 runBatch 批量汇入链路。UIA-011/012 的系统
//     PhotosPicker 被替换（ADR-0015 决策 3），挂载点（按钮 + 胶水）形态不变。
// D3 决策不变：MVP 引用 tmp/原路径不拷贝入库 —— 相册视频落盘的 URL 在 App
// 重启后可能被清理，届时同样显示「已失效」，与文件路径行为一致；素材库整理
// （拷入沙箱）是后续任务，两条路径届时统一收口。
// 属性区仍是桩：UIA-006 接入真实参数（变更必须走 Command）。

import SwiftUI
import ChuanqiCut
import UniformTypeIdentifiers

struct PropertyPanelZone: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    @State private var showImporter = false
    @State private var importError: String?

    // UIA-013：自研相册浏览器（sheet）。批量加载态/错误汇总自持在
    // PhotoLibraryImporter（AppEntry 的 importMedia 及其 importInFlight 零改动）。
    @State private var showAlbumPicker = false
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

                // 从相册导入：自研浏览器（UIA-013）。只选视频、多选上限 20，
                // 时长过滤等配置在 AlbumPickerConfiguration.standard。
                Button {
                    showAlbumPicker = true
                } label: {
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

            Text("属性")
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
        // 自研相册浏览器（UIA-013，剪映式连续导入流）：**面板保持打开**，
        // 单击插入 / 批量添加交付的 URL 列表（顺序 = 选取序号）直接汇入
        // UIA-012 的 runBatch 批量链路 —— resolveURL 直接命中已落盘的 tmp
        // 文件（浏览器确认阶段已完成 PHAssetResource 落盘 / iCloud 拉取）。
        // async 回调：runBatch 返回后浏览器才解除 cell loading。
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerScreen { urls in
                await photosImporter.runBatch(
                    count: urls.count,
                    resolveURL: { urls[$0] },
                    importURL: photosImporter.sequencedImport(into: viewModel))
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

// MARK: - 相册导入胶水（UIA-011 单选落地，UIA-012 扩为批量）

/// 相册选取项 → 临时文件 URL → 既有 importMedia 的批量胶水，加载态 / 错误汇总自持。
///
/// resolveURL / importURL 全部注入：loadTransferable 需要真实 PHAsset，
/// XCTest 宿主没有相册数据 —— 注入后批量状态机（loading 翻转、逐条顺序、
/// 部分失败不中断、失败不产生素材）可以脱离相册单测（PhotoImportTests）。
/// 生产接线在 PropertyPanelZone.onChange。
///
/// @MainActor：两个闭包都是主线程语义（importMedia 是"用户动作、低频"的同步
/// 调用，见 AppEntry.importMedia 注释）；错误与 loading 直接驱动 UI。
@MainActor
final class PhotoLibraryImporter: ObservableObject {

    /// 正在把相册素材读成文件（iCloud 下载可能持续数秒；批量整体一个加载态）。
    /// 按钮据此置灰防重复。
    @Published private(set) var isLoading = false

    /// 最近一次批量导入的失败汇总；nil = 无失败（全部成功同样清空旧错误）。
    /// 全失败 = 最后一条失败详情（文案前缀与单条路径一致）；部分失败 =
    /// 「成功 M 条，失败 K 条（最后一条详情）」。
    @Published var errorMessage: String?

    /// 批量导入：按序号逐条 resolve → import，条间 Task.yield 让出主线程
    /// （红线 #8；importMedia 本体是同步调用，不 yield 整批会长时间独占）。
    /// 部分失败不中断：失败条不产生素材，继续其余；有失败才汇总进
    /// errorMessage，全部成功保持 nil（素材入表即反馈）。
    /// - Parameters:
    ///   - count: 选取条数（系统 sheet 的选取上限由调用方 maxSelectionCount 约束）。
    ///   - resolveURL: 按序号产出系统落盘的临时文件 URL（nil = 类型不受支持）。
    ///   - importURL: 把 URL 汇入既有导入链路（生产 = `sequencedImport(into:)` 产出）。
    func runBatch(count: Int,
                  resolveURL: (Int) async throws -> URL?,
                  importURL: (URL) async -> Status) async {
        isLoading = true
        defer { isLoading = false }

        var importedCount = 0
        var failures: [String] = []
        for index in 0..<max(count, 0) {
            do {
                guard let url = try await resolveURL(index) else {
                    failures.append("相册素材无法读取（类型不受支持）")
                    continue
                }
                let status = await importURL(url)
                if status.isOK {
                    importedCount += 1
                } else {
                    failures.append("导入失败：\(status.text)")
                }
            } catch {
                failures.append("相册读取失败：\(error.localizedDescription)")
            }
            await Task.yield()   // 条间让出主线程：整批不长时间独占（红线 #8）
        }

        if let lastFailure = failures.last {
            errorMessage = importedCount == 0
                ? lastFailure
                : "成功 \(importedCount) 条，失败 \(failures.count) 条（\(lastFailure)）"
        } else {
            errorMessage = nil
        }
    }

    /// 生产接线的导入闭包：importMedia 成功后**等本条片段在快照可见**再返回
    /// —— 批量的追加顺序保证。下一条的追加起点取自快照里该轨末尾
    /// （AppEntry.importMedia §4），不等落库就会用同一个 end 提交、被内核按
    /// 重叠拒绝（单选无此问题）。等"clips 计数增加"而非"版本推进"：建轨
    /// 也 bump 版本，只等版本会在片段未落库时提前放行。泵手法与 AppEntry
    /// 建轨等待、golden 测试一致；5s 兜底，超时不失败（最坏由下一条的
    /// 重叠拒绝兜住并计入失败汇总）。
    func sequencedImport(into viewModel: EditorViewModel) -> (URL) async -> Status {
        { url in
            let clipsAtStart = viewModel.timeline.clips.count
            let status = viewModel.importMedia(url: url)
            guard status.isOK else { return status }
            let deadline = Date().addingTimeInterval(5)
            while viewModel.timeline.clips.count <= clipsAtStart && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return status
        }
    }
}
