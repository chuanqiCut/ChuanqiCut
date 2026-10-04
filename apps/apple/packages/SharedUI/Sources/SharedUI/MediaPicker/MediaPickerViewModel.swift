// SharedUI — 自研相册浏览器：屏幕状态机（UIA-013）
//
// ViewModel 依赖注入的 AlbumFetching：生产 = PhotoKitAlbumStore，测试 = 夹具
// （AlbumPickerTests）。选取状态机在 SelectionState（纯值类型），本类只做
// 装配与副作用编排：切相簿、选取反馈、确认导出（逐条落 tmp、进度上抛）。
//
// 交互模式（v1.1，对齐剪映素材面板的连续导入流）：
//   * **默认单击即插入**：点击 cell → 落 tmp → 交付 → 导入完成才结束 loading
//     （onConfirm 为 async 回调，VM 会 await 到父层导入链路返回），面板保持
//     打开，用户可连续点选 —— 选择与插入是同一步。
//   * **「多选」显式模式**：序号徽标 + 托盘 + 批量添加；退出多选清空已选。
//     长按 cell 可从单击模式直接进入多选并选中该条。
//
// 失败语义（Spec §3）：部分失败仍交付成功部分（失败的下次再选）；全部失败
// 保持选择器打开并展示错误，不交付 —— 交付后由 UIA-012 的 runBatch 汇入
// importMedia（PropertyPanelZone 接线）。

import Foundation
import SwiftUI

// MARK: - 选取反馈（驱动 cell 动画与提示）

enum SelectionFeedback: Equatable {
    case selected
    case deselected
    case rejectedFull            // 满选再增（ZL/HX 的置灰 + 抖动场景）
    case rejectedDuration(String)
}

/// 单击即插入的结果（驱动 toast 文案；busy = 上一条还在处理）。
enum InsertOutcome: Equatable {
    case delivered
    case busy
    case rejectedDuration(String)
    case failed(String)
}

// MARK: - ViewModel

@MainActor
final class MediaPickerViewModel: ObservableObject {

    @Published private(set) var albums: [AlbumSummary] = []
    @Published private(set) var assets: [AssetDescriptor] = []
    @Published private(set) var currentAlbum: AlbumSummary?
    /// 相簿装载过一次（区分"还没加载"与"加载后为空"两种空态）。
    @Published private(set) var hasLoaded = false

    @Published private(set) var selection: SelectionState

    /// 「多选」显式模式（剪映范式）：默认关闭 = 单击即插入；开启 = 序号
    /// 徽标 + 托盘 + 批量添加。退出时清空已选（可预期语义）。
    @Published private(set) var isMultiSelectMode = false

    /// 单击插入进行中的素材（cell 转圈覆盖层；await 导入完成后移除 ——
    /// loading 覆盖"落 tmp + 进时间线"全程，反馈闭环）。
    @Published private(set) var insertingIDs: Set<String> = []

    /// 已选素材按选取顺序的描述符快照（底部托盘渲染用）—— 切相簿不丢，
    /// 取消选取即移除。
    @Published private(set) var selectedInOrder: [AssetDescriptor] = []

    /// 确认导出进行中（逐条落 tmp / iCloud 下载），完成按钮置灰并显示进度。
    @Published private(set) var isPreparingFiles = false
    @Published private(set) var preparingText: String?
    /// 确认导出阶段的全失败错误（不关闭选择器）；nil = 无。
    @Published private(set) var preparingError: String?

    // 视图层需要读取（cell 请求缩略图 / 网格列宽与时长过滤）
    let fetcher: AlbumFetching
    let configuration: AlbumPickerConfiguration
    /// 交付成功的文件 URL 列表（顺序 = 选取序号顺序）。**async 回调**：
    /// VM await 到父层导入链路完成后才结束 loading —— 单击插入的反馈闭环
    /// 覆盖"落 tmp + 进时间线"全程。
    private let onConfirm: ([URL]) async -> Void

    init(fetcher: AlbumFetching,
         configuration: AlbumPickerConfiguration = .standard,
         onConfirm: @escaping ([URL]) async -> Void = { _ in }) {
        self.fetcher = fetcher
        self.configuration = configuration
        self.selection = SelectionState(maxCount: configuration.maxSelectionCount)
        self.onConfirm = onConfirm
    }

    // MARK: 相簿与素材

    func loadAlbums() {
        albums = fetcher.fetchAlbums()
        hasLoaded = true
        // 首个相簿（最近项目）自动选中；库为空保持 nil → 空态视图
        select(album: albums.first)
    }

    func select(album: AlbumSummary?) {
        guard let album, album != currentAlbum else { return }
        currentAlbum = album
        assets = fetcher.fetchAssets(albumID: album.id)
    }

    var isLibraryEmpty: Bool { currentAlbum != nil && assets.isEmpty }

    // MARK: 交互模式（v1.1 剪映式）

    /// 切换多选模式。退出多选 = 清空已选（避免"托盘消失但状态残留"的歧义）。
    func setMultiSelectMode(_ enabled: Bool) {
        guard isMultiSelectMode != enabled else { return }
        isMultiSelectMode = enabled
        if !enabled { clearSelection() }
    }

    /// 单击即插入：落 tmp → 交付 → await 导入完成。进行中由 isPreparingFiles
    /// 串行化（快速连点不会并发进入 importMedia —— importInFlight 会拒绝重入）。
    /// 时长过滤同样生效（超限直接拒绝，不进入落盘）。
    func insertSingle(_ descriptor: AssetDescriptor) async -> InsertOutcome {
        if let reason = DurationFilter.rejectionReason(
            durationSeconds: descriptor.durationSeconds,
            allowed: configuration.allowedDuration) {
            return .rejectedDuration(reason)
        }
        guard !isPreparingFiles else { return .busy }

        isPreparingFiles = true
        defer { isPreparingFiles = false; preparingText = nil }
        insertingIDs.insert(descriptor.id)
        defer { insertingIDs.remove(descriptor.id) }

        do {
            let url = try await fetcher.resolveFileURL(assetID: descriptor.id, progress: { @Sendable _ in })
            await onConfirm([url])
            return .delivered
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: 选取

    /// toggle 一次选取；反馈枚举供视图驱动动画 / 震动 / 文案。
    func toggleSelect(_ descriptor: AssetDescriptor) -> SelectionFeedback {
        if let reason = DurationFilter.rejectionReason(
            durationSeconds: descriptor.durationSeconds,
            allowed: configuration.allowedDuration) {
            return .rejectedDuration(reason)
        }
        if selection.wouldRejectAdd(descriptor.id) {
            return .rejectedFull
        }
        let id = descriptor.id
        let wasSelected = selection.contains(id)
        selection = selection.toggled(id)
        if wasSelected {
            selectedInOrder.removeAll { $0.id == id }
        } else {
            selectedInOrder.append(descriptor)
        }
        return selection.contains(id) ? .selected : .deselected
    }

    func clearSelection() {
        selection = SelectionState(maxCount: configuration.maxSelectionCount)
        selectedInOrder = []
    }

    // MARK: 确认导出

    /// 批量添加：逐条把选中素材落成我方 tmp 文件 URL（iCloud 素材联网下载，
    /// 进度上抛），全部完成后一次性交付。**顺序 = 选取序号顺序**（时间线追加
    /// 顺序的来源）。交付成功后清空选取/托盘 —— 与剪映一致，可紧接着选下一批。
    func confirm() async {
        guard !selection.isEmpty, !isPreparingFiles else { return }
        isPreparingFiles = true
        preparingError = nil
        defer { isPreparingFiles = false; preparingText = nil }

        let orderedIDs = selection.orderedIDs
        var delivered: [URL] = []
        var failureDetail: String?

        for (index, id) in orderedIDs.enumerated() {
            preparingText = AlbumPickerText.preparingProgress(
                index: index + 1, total: orderedIDs.count)
            do {
                delivered.append(try await fetcher.resolveFileURL(assetID: id) { [weak self] fraction in
                    // 条内粗粒度进度：整批文案 + 百分比（无需逐字节精度）
                    self?.preparingText = AlbumPickerText.preparingProgress(
                        index: index + 1, total: orderedIDs.count)
                        + " \(Int(fraction * 100))%"
                })
            } catch {
                // 单条失败不中断（同 runBatch 语义）；最后一条错误作为详情
                failureDetail = error.localizedDescription
            }
            await Task.yield()   // 条间让出主线程（红线 #8）
        }

        if delivered.isEmpty {
            preparingError = AlbumPickerText.allResolveFailed(
                detail: failureDetail ?? "未知错误")
            return
        }
        await onConfirm(delivered)
        clearSelection()   // 批量添加完成后托盘清空，选取状态归零
    }
}
