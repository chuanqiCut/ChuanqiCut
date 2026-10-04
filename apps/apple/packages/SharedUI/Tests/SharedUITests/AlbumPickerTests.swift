// SharedUI — 自研相册浏览器验收（UIA-013）
//
// 无相册数据的环境（XCTest 宿主）里，靠两个 seam 测到核心逻辑：
//   * 纯逻辑直测：SelectionState 状态机 / DurationFilter / 权限映射 /
//     角标文案（AlbumPickerModels + AlbumPermissionModel）
//   * AlbumFetching 注入夹具：ViewModel 的装载 / 选取反馈 / 确认导出顺序、
//     部分失败交付、全失败不交付（PhotoKit 全部挡在 PhotoKitAlbumStore，
//     本文件不 import Photos 的运行时行为）
// 视图（网格 / 托盘 / 手势）与真实相册行为靠 App 冒烟 + 真机人工验证
// （同 UIA-005/011 既定手法）。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import XCTest
import Photos
@testable import SharedUI

@MainActor
final class AlbumPickerTests: XCTestCase {

    // MARK: 夹具取数器

    private final class FixtureFetcher: AlbumFetching {
        let albums: [AlbumSummary]
        let assetsByAlbum: [String: [AssetDescriptor]]
        var resolveURLs: [String: URL] = [:]
        var resolveErrors: [String: Error] = [:]
        private(set) var resolveOrder: [String] = []

        init(albums: [AlbumSummary] = [], assetsByAlbum: [String: [AssetDescriptor]] = [:]) {
            self.albums = albums
            self.assetsByAlbum = assetsByAlbum
        }

        func fetchAlbums() -> [AlbumSummary] { albums }

        func fetchAssets(albumID: String) -> [AssetDescriptor] {
            assetsByAlbum[albumID] ?? []
        }

        func requestThumbnail(assetID: String, targetSize: CGSize,
                              onDelivery: @escaping (PlatformImage?, Bool) -> Void) {}

        func cancelThumbnail(assetID: String) {}

        func resolveFileURL(assetID: String,
                            progress: @escaping (Double) -> Void) async throws -> URL {
            resolveOrder.append(assetID)
            if let error = resolveErrors[assetID] { throw error }
            return resolveURLs[assetID]
                ?? URL(fileURLWithPath: "/tmp/cq_album_\(assetID).mov")
        }
    }

    private func descriptor(_ id: String, duration: TimeInterval = 10) -> AssetDescriptor {
        AssetDescriptor(id: id, durationSeconds: duration, isLocallyAvailable: true)
    }

    // MARK: SelectionState 状态机（纯逻辑）

    func testSelectionKeepsOrderAndRenumbersAfterRemoval() {
        var state = SelectionState(maxCount: 20)
        state = state.toggled("a")
        state = state.toggled("b")
        state = state.toggled("c")
        XCTAssertEqual(state.orderedIDs, ["a", "b", "c"], "选中按序追加")
        XCTAssertEqual(state.orderNumber(of: "c"), 3)

        state = state.toggled("b")   // 取消中间项，后续序号前移
        XCTAssertEqual(state.orderedIDs, ["a", "c"])
        XCTAssertEqual(state.orderNumber(of: "c"), 2, "取消后序号必须前移")
        XCTAssertNil(state.orderNumber(of: "b"))

        state = state.toggled("b")   // 重复选取同一 id = 重新选中，追加到队尾
        XCTAssertEqual(state.orderedIDs, ["a", "c", "b"])
    }

    func testSelectionRejectsAddWhenFull() {
        var state = SelectionState(maxCount: 2)
        state = state.toggled("a")
        state = state.toggled("b")
        XCTAssertTrue(state.isFull)

        XCTAssertTrue(state.wouldRejectAdd("c"), "满选再增必须预判拒绝")
        let unchanged = state.toggled("c")
        XCTAssertEqual(unchanged, state, "被拒的 toggle 不得改变状态")

        XCTAssertFalse(state.wouldRejectAdd("a"), "取消已选项不受满选限制")
    }

    // MARK: DurationFilter（纯逻辑）

    func testDurationFilterBoundaries() {
        let allowed: ClosedRange<TimeInterval>? = 1...300
        XCTAssertNil(DurationFilter.rejectionReason(durationSeconds: 1, allowed: allowed),
                     "下边界含")
        XCTAssertNil(DurationFilter.rejectionReason(durationSeconds: 300, allowed: allowed),
                     "上边界含")
        XCTAssertNil(DurationFilter.rejectionReason(durationSeconds: 42, allowed: allowed))
        XCTAssertNil(DurationFilter.rejectionReason(durationSeconds: 42, allowed: nil),
                     "未配置过滤 = 全可选")

        XCTAssertEqual(DurationFilter.rejectionReason(durationSeconds: 0.5, allowed: allowed),
                       "时长不足 1 秒")
        XCTAssertEqual(DurationFilter.rejectionReason(durationSeconds: 301, allowed: allowed),
                       "超过 300 秒上限")
    }

    // MARK: 权限映射（纯逻辑）

    func testAuthorizationStatusMapping() {
        XCTAssertEqual(albumAccessLevel(from: .notDetermined), .notDetermined)
        XCTAssertEqual(albumAccessLevel(from: .authorized), .authorized)
        XCTAssertEqual(albumAccessLevel(from: .limited), .limited)
        XCTAssertEqual(albumAccessLevel(from: .denied), .denied)
        XCTAssertEqual(albumAccessLevel(from: .restricted), .denied,
                       "家长控制（restricted）与拒绝同路：都进去设置引导")
    }

    // MARK: ViewModel（注入夹具）

    private func makeModel(fetcher: FixtureFetcher,
                           configuration: AlbumPickerConfiguration = .standard,
                           onConfirm: @escaping ([URL]) async -> Void = { _ in }) -> MediaPickerViewModel {
        MediaPickerViewModel(fetcher: fetcher,
                             configuration: configuration,
                             onConfirm: onConfirm)
    }

    func testLoadAlbumsAutoSelectsFirstAndEmptyLibraryStaysEmpty() {
        let emptyFetcher = FixtureFetcher()
        let emptyModel = makeModel(fetcher: emptyFetcher)
        emptyModel.loadAlbums()
        XCTAssertTrue(emptyModel.hasLoaded, "装载过一次的标志必须置位")
        XCTAssertTrue(emptyModel.albums.isEmpty)
        XCTAssertNil(emptyModel.currentAlbum, "空库不选中任何相簿，交由空态视图")

        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 2)],
            assetsByAlbum: ["recent": [descriptor("a"), descriptor("b")]])
        let model = makeModel(fetcher: fetcher)
        model.loadAlbums()
        XCTAssertEqual(model.currentAlbum?.id, "recent", "首个相簿（最近项目）自动选中")
        XCTAssertEqual(model.assets.count, 2)
        XCTAssertFalse(model.isLibraryEmpty)
    }

    func testSwitchAlbumReloadsAssets() {
        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 1),
                     AlbumSummary(id: "fav", title: "收藏", assetCount: 1)],
            assetsByAlbum: ["recent": [descriptor("a")],
                            "fav": [descriptor("b")]])
        let model = makeModel(fetcher: fetcher)
        model.loadAlbums()
        XCTAssertEqual(model.assets.map(\.id), ["a"])

        model.select(album: model.albums[1])
        XCTAssertEqual(model.assets.map(\.id), ["b"], "切相簿必须重载素材")
    }

    func testToggleSelectDurationRejectedNotStored() {
        var configuration = AlbumPickerConfiguration.standard
        configuration.allowedDuration = 1...300
        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 2)],
            assetsByAlbum: ["recent": [descriptor("short", duration: 0.5),
                                       descriptor("ok", duration: 30)]])
        let model = makeModel(fetcher: fetcher, configuration: configuration)
        model.loadAlbums()

        XCTAssertEqual(model.toggleSelect(model.assets[0]),
                       .rejectedDuration("时长不足 1 秒"))
        XCTAssertTrue(model.selection.isEmpty, "被时长过滤拒绝的素材不得进入选取")
        XCTAssertTrue(model.selectedInOrder.isEmpty)

        XCTAssertEqual(model.toggleSelect(model.assets[1]), .selected)
        XCTAssertEqual(model.selection.count, 1)
    }

    func testToggleSelectFullRejected() {
        var configuration = AlbumPickerConfiguration.standard
        configuration.maxSelectionCount = 1
        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 2)],
            assetsByAlbum: ["recent": [descriptor("a"), descriptor("b")]])
        let model = makeModel(fetcher: fetcher, configuration: configuration)
        model.loadAlbums()

        XCTAssertEqual(model.toggleSelect(model.assets[0]), .selected)
        XCTAssertEqual(model.toggleSelect(model.assets[1]), .rejectedFull,
                       "满选再增必须给出拒绝反馈")
        XCTAssertEqual(model.selection.count, 1)
        XCTAssertEqual(model.selectedInOrder.count, 1, "托盘快照与选取状态一致")
    }

    func testConfirmResolvesInSelectionOrderAndDelivers() async {
        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 3)],
            assetsByAlbum: ["recent": [descriptor("a"), descriptor("b"), descriptor("c")]])
        let urlB = URL(fileURLWithPath: "/tmp/cq_b.mov")
        fetcher.resolveURLs["b"] = urlB
        var delivered: [URL] = []
        let model = makeModel(fetcher: fetcher) { delivered = $0 }
        model.loadAlbums()

        // 故意乱序选取：交付与落盘顺序都必须 = 选取序号顺序
        model.toggleSelect(model.assets[2])   // c
        model.toggleSelect(model.assets[0])   // a
        model.toggleSelect(model.assets[1])   // b

        await model.confirm()

        XCTAssertEqual(fetcher.resolveOrder, ["c", "a", "b"], "按选取序号顺序落盘")
        XCTAssertEqual(delivered.count, 3)
        // 选取序 [c,a,b] → delivered[2] 才是 b 的自定义 URL（[0]=c 默认、[1]=a 默认）
        XCTAssertEqual(delivered[2], urlB, "交付顺序同样 = 选取序号顺序")
        XCTAssertFalse(model.isPreparingFiles, "交付后加载态复位")
        XCTAssertNil(model.preparingError)
        XCTAssertTrue(model.selection.isEmpty, "批量添加成功后清空选取（可紧接着选下一批）")
        XCTAssertTrue(model.selectedInOrder.isEmpty, "托盘快照同步清空")
    }

    func testConfirmPartialFailureDeliversSuccesses() async {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "Boom" }
        }
        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 2)],
            assetsByAlbum: ["recent": [descriptor("a"), descriptor("bad")]])
        fetcher.resolveErrors["bad"] = Boom()
        var delivered: [URL] = []
        let model = makeModel(fetcher: fetcher) { delivered = $0 }
        model.loadAlbums()
        model.toggleSelect(model.assets[0])
        model.toggleSelect(model.assets[1])

        await model.confirm()

        XCTAssertEqual(delivered.count, 1, "部分失败仍交付成功部分（Spec §3）")
        XCTAssertEqual(delivered.first?.lastPathComponent, "cq_album_a.mov")
        XCTAssertNil(model.preparingError, "有交付就不算全失败")
        XCTAssertFalse(model.isPreparingFiles)
    }

    func testConfirmAllFailuresDeliversNothingAndStaysOpen() async {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "Boom" }
        }
        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 1)],
            assetsByAlbum: ["recent": [descriptor("bad")]])
        fetcher.resolveErrors["bad"] = Boom()
        var delivered: [URL] = []
        var confirmCalled = false
        let model = makeModel(fetcher: fetcher) { urls in
            delivered = urls
            confirmCalled = true
        }
        model.loadAlbums()
        model.toggleSelect(model.assets[0])

        await model.confirm()

        XCTAssertFalse(confirmCalled, "全失败不得交付")
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(model.preparingError, "视频读取失败：Boom",
                       "全失败保持选择器打开并展示错误")
        XCTAssertFalse(model.isPreparingFiles)
    }

    func testClearSelectionResetsTraySnapshot() {
        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 2)],
            assetsByAlbum: ["recent": [descriptor("a"), descriptor("b")]])
        let model = makeModel(fetcher: fetcher)
        model.loadAlbums()
        model.toggleSelect(model.assets[0])
        model.toggleSelect(model.assets[1])
        model.clearSelection()
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.selectedInOrder.isEmpty, "清空必须连托盘快照一起复位")
    }

    // MARK: 剪映式交互（v1.1：单击即插入 / 多选显式模式）

    func testInsertSingleDeliversAndCoversFullPipeline() async {
        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 1)],
            assetsByAlbum: ["recent": [descriptor("a")]])
        let urlA = URL(fileURLWithPath: "/tmp/cq_inserted.mov")
        fetcher.resolveURLs["a"] = urlA
        var delivered: [URL] = []
        let model = makeModel(fetcher: fetcher) { urls in
            delivered = urls
            // 模拟父层导入耗时：交付回调在 runBatch 完成后才返回
        }
        model.loadAlbums()

        let outcome = await model.insertSingle(model.assets[0])

        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(delivered, [urlA], "单击即交付单条（无需多选确认）")
        XCTAssertFalse(model.isPreparingFiles, "await 导入完成后 loading 才复位")
        XCTAssertTrue(model.insertingIDs.isEmpty, "cell loading 覆盖层随交付移除")
    }

    func testInsertSingleAppliesDurationFilterAndBusyGuard() async {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "Boom" }
        }
        var configuration = AlbumPickerConfiguration.standard
        configuration.allowedDuration = 1...300
        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 3)],
            assetsByAlbum: ["recent": [descriptor("short", duration: 0.5),
                                       descriptor("bad", duration: 30),
                                       descriptor("ok", duration: 30)]])
        fetcher.resolveErrors["bad"] = Boom()
        var delivered: [URL] = []
        let model = makeModel(fetcher: fetcher, configuration: configuration) {
            delivered = $0
        }
        model.loadAlbums()

        // 时长过滤在单击路径同样生效（不进入落盘）
        let rejectedOutcome = await model.insertSingle(model.assets[0])
        XCTAssertEqual(rejectedOutcome, .rejectedDuration("时长不足 1 秒"))
        XCTAssertTrue(delivered.isEmpty)

        // 落盘失败：不交付、不崩溃，错误上抛给 toast
        let failed = await model.insertSingle(model.assets[1])
        XCTAssertEqual(failed, .failed("Boom"))
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(model.insertingIDs.isEmpty, "失败后 cell loading 必须移除")

        let ok = await model.insertSingle(model.assets[2])
        XCTAssertEqual(ok, .delivered)
        XCTAssertEqual(delivered.count, 1)
    }

    func testMultiSelectModeToggleClearsSelectionOnExit() {
        let fetcher = FixtureFetcher(
            albums: [AlbumSummary(id: "recent", title: "最近项目", assetCount: 2)],
            assetsByAlbum: ["recent": [descriptor("a"), descriptor("b")]])
        let model = makeModel(fetcher: fetcher)
        model.loadAlbums()
        XCTAssertFalse(model.isMultiSelectMode, "默认单击即插入模式")

        model.setMultiSelectMode(true)
        XCTAssertTrue(model.isMultiSelectMode)
        model.toggleSelect(model.assets[0])
        XCTAssertEqual(model.selection.count, 1)

        model.setMultiSelectMode(false)
        XCTAssertFalse(model.isMultiSelectMode)
        XCTAssertTrue(model.selection.isEmpty, "退出多选清空已选（可预期语义）")
        XCTAssertTrue(model.selectedInOrder.isEmpty)
    }

    // MARK: 角标文案（纯逻辑）

    func testDurationBadgeText() {
        XCTAssertEqual(MediaGridCell.durationText(5), "0:05")
        XCTAssertEqual(MediaGridCell.durationText(65), "1:05")
        XCTAssertEqual(MediaGridCell.durationText(3671), "1:01:11")
    }
}
