// SharedUI — 媒体抽屉：素材库面板（UIA-032，自 PropertyPanelZone 迁移）
//
// 素材库两条导入入口，汇入同一 EditorViewModel.importMedia（Spec UIA-011 §2）：
//   * 从文件导入：fileImporter（"文件"App 路径）
//   * 从相册导入：UIA-013 自研相册浏览器（MediaPicker/）——确认后交付文件 URL
//     列表，走与 UIA-012 完全相同的 runBatch 批量汇入链路
// D3 决策不变：MVP 引用 tmp/原路径不拷贝入库；素材库整理是后续任务。
//
// 本视图同时是两个宿主的内容层（ARCH-005「共享状态不共享 UI」的最小实践）：
//   * iOS：EditorBottomToolbar 的 bottom sheet（detents medium/large）
//   * macOS：编辑器右栏（原 PropertyPanelZone 位置，行为等价迁移，macOS 惯例化批次再惯例化——原 UIA-017 建议位已让位）
// 属性参数区不在此（UIA-006 接真实参数时再进面板框架 UIA-019）。

import SwiftUI
import ChuanqiCut
import UniformTypeIdentifiers

/// 素材库内容面板（宿主无关）。
struct MediaLibraryPanel: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    @State private var showImporter = false
    @State private var importError: String?

    // UIA-013：自研相册浏览器（sheet）。批量加载态/错误汇总自持在
    // PhotoLibraryImporter（AppEntry 的 importMedia 及其 importInFlight 零改动）。
    @State private var showAlbumPicker = false
    @StateObject private var photosImporter = PhotoLibraryImporter()

    // UIA-026：素材库 → 播放器联动（值拷贝过接缝，播放器零 Session 依赖）。
    @State private var playerURLs: [URL]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("素材库")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)

            // 导入入口：文件 / 相册（两条路汇入同一 importMedia）
            VStack(spacing: Theme.Space.s) {
                Button {
                    showImporter = true
                } label: {
                    Label("从文件导入", systemImage: "plus.rectangle.on.folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

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
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.s)

            if let importError {
                errorText(importError)
            }
            if let photoError = photosImporter.errorMessage {
                errorText(photoError)
            }

            // 素材列表（失效标记：exists == false）
            if viewModel.mediaLibrary.isEmpty {
                Text("尚未导入素材")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.s)
            } else {
                ForEach(viewModel.mediaLibrary) { asset in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Theme.Space.xs) {
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
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, 6)
                    .contextMenu {
                        if asset.exists {
                            Button {
                                playerURLs = [URL(fileURLWithPath: asset.path)]
                            } label: {
                                Label("用播放器打开", systemImage: "play.rectangle")
                            }
                        } else {
                            Text("文件已失效，无法播放")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    Divider()
                }
            }

            Spacer(minLength: 0)
        }
        .background(Theme.panelBackground)
        // UIA-026：播放器 sheet（单条预览 / 批量连播；关闭即回收，预览用语义）
        .sheet(isPresented: Binding(
            get: { playerURLs != nil },
            set: { if !$0 { playerURLs = nil } }
        )) {
            if let urls = playerURLs {
                if urls.count == 1, let only = urls.first {
                    PlayerScreen(url: only)
                } else {
                    PlayerScreen(urls: urls)
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.movie, .video, .mpeg4Movie]) { result in
            switch result {
            case .success(let url):
                let status = viewModel.importMedia(url: url)
                importError = status.isOK ? nil : "导入失败：\(status.userText)"
            case .failure(let error):
                importError = "选择失败：\(error.localizedDescription)"
            }
        }
        // 自研相册浏览器（UIA-013，剪映式连续导入流）：面板保持打开，单击插入 /
        // 批量添加交付的 URL 列表（顺序 = 选取序号）直接汇入 runBatch。
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerScreen { urls in
                await photosImporter.runBatch(
                    count: urls.count,
                    resolveURL: { urls[$0] },
                    importURL: photosImporter.sequencedImport(into: viewModel))
            }
        }
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.red)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, 6)
    }
}

/// iOS 底部抽屉壳（UIA-032）：半屏 detents + 拖拽指示器；macOS 不用本壳
/// （右栏直嵌 MediaLibraryPanel，无 sheet）。
struct MediaSheet: View {
    var body: some View {
        #if os(iOS)
        MediaLibraryPanel()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
        MediaLibraryPanel()
        #endif
    }
}

// MARK: - 相册导入胶水（UIA-011 单选落地，UIA-012 扩为批量；UIA-032 自
//        PropertyPanelZone 迁移至此 —— 内容随素材库面板走，语义零改动）

/// 相册选取项 → 临时文件 URL → 既有 importMedia 的批量胶水，加载态 / 错误汇总自持。
///
/// resolveURL / importURL 全部注入：loadTransferable 需要真实 PHAsset，
/// XCTest 宿主没有相册数据 —— 注入后批量状态机（loading 翻转、逐条顺序、
/// 部分失败不中断、失败不产生素材）可以脱离相册单测（PhotoImportTests）。
/// 生产接线在 MediaLibraryPanel 的 AlbumPickerScreen 回调。
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
                    failures.append("导入失败：\(status.userText)")
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
