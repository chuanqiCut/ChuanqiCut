// SharedUI — 相册导入胶水验收（UIA-011 单选语义 + UIA-012 批量语义）
//
// 导入胶水的选取源需要真实相册数据（UIA-011/012 时代的 loadTransferable、
// UIA-013 起自研浏览器交付的 tmp URL 列表），XCTest 宿主无法驱动（同 UIA-005
// "SwiftUI 手势不可测"的既有结论）—— 故把 URLs→importMedia 的批量状态机抽成
// PhotoLibraryImporter（闭包注入），本文件锁：
//   * UIA-011 单条语义（以 count:1 的批量特例表达，逐条保留）：loading 翻转、
//     resolve 抛错 / 返回 nil → 只置错误信息不导入、成功汇入导入闭包、
//     导入失败带 Status 文本
//   * UIA-012 批量语义：多条按序汇入、部分失败不中断且汇总「成功 M / 失败 K」、
//     全失败不产生素材不崩溃、批量期间 loading 翻转复位
//   * 与真 ViewModel 组合：golden 视频 URL → 素材表 + 时间线最终一致
//     （走生产同款 sequencedImport：importMedia + 等落库，证明接线可用）
// 选择器接线（PhotosPicker / onChange）靠 App 冒烟与真机人工验证。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import XCTest
import ChuanqiCut
@testable import SharedUI

@MainActor
final class PhotoImportTests: XCTestCase {

    // MARK: 状态机（注入闭包，不依赖相册）—— UIA-011 单条语义（批量 count:1 特例）

    func testLoadFailureSetsErrorAndSkipsImport() async {
        let importer = PhotoLibraryImporter()
        struct Boom: Error {}
        var imported: [URL] = []
        await importer.runBatch(count: 1,
                                resolveURL: { _ in throw Boom() },
                                importURL: { imported.append($0); return .ok })
        XCTAssertFalse(importer.isLoading, "失败后 loading 必须复位")
        XCTAssertEqual(importer.errorMessage?.hasPrefix("相册读取失败"), true)
        XCTAssertTrue(imported.isEmpty, "读取失败不得触发导入")
    }

    func testLoadNilSetsUnsupportedError() async {
        let importer = PhotoLibraryImporter()
        var imported: [URL] = []
        await importer.runBatch(count: 1,
                                resolveURL: { _ in nil },
                                importURL: { imported.append($0); return .ok })
        XCTAssertEqual(importer.errorMessage, "相册素材无法读取（类型不受支持）")
        XCTAssertTrue(imported.isEmpty, "解析不出 URL 不得触发导入")
        XCTAssertFalse(importer.isLoading)
    }

    func testLoadingFlipsDuringResolve() async {
        let importer = PhotoLibraryImporter()
        var loadingDuringResolve: Bool?
        await importer.runBatch(count: 1, resolveURL: { _ in
            loadingDuringResolve = importer.isLoading
            return nil
        }, importURL: { _ in .ok })
        XCTAssertEqual(loadingDuringResolve, true, "resolve 期间应为加载态")
        XCTAssertFalse(importer.isLoading, "结束后必须复位")
    }

    func testSuccessFunnelsURLIntoImportAndClearsError() async {
        let importer = PhotoLibraryImporter()
        importer.errorMessage = "旧错误"      // 前置：上一次失败留下的错误
        let url = URL(fileURLWithPath: "/tmp/cq_photo_item.mov")
        var imported: [URL] = []
        await importer.runBatch(count: 1,
                                resolveURL: { _ in url },
                                importURL: { imported.append($0); return .ok })
        XCTAssertEqual(imported, [url], "解析出的 URL 必须原样汇入导入闭包")
        XCTAssertNil(importer.errorMessage, "成功必须清空旧错误")
        XCTAssertFalse(importer.isLoading)
    }

    func testImportFailureSurfacesStatusText() async {
        let importer = PhotoLibraryImporter()
        // 2000 = kDecodeError（AppEntry.importMedia 对"打不开/解析不了"的用法）
        await importer.runBatch(count: 1,
                                resolveURL: { _ in URL(fileURLWithPath: "/tmp/cq_photo_item.mov") },
                                importURL: { _ in Status(rawValue: 2000) })
        XCTAssertEqual(importer.errorMessage?.hasPrefix("导入失败"), true)
        XCTAssertFalse(importer.isLoading, "导入失败 loading 同样复位")
    }

    // MARK: 批量状态机（UIA-012）

    func testBatchImportsAllInSelectionOrder() async {
        let importer = PhotoLibraryImporter()
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/cq_batch_\($0).mov") }
        var imported: [URL] = []
        await importer.runBatch(count: urls.count,
                                resolveURL: { urls[$0] },
                                importURL: { imported.append($0); return .ok })
        XCTAssertEqual(imported, urls, "多条必须按选取序号顺序汇入")
        XCTAssertNil(importer.errorMessage, "全部成功不得置错误信息")
        XCTAssertFalse(importer.isLoading)
    }

    func testBatchPartialFailureContinuesAndSummarizes() async {
        let importer = PhotoLibraryImporter()
        // LocalizedError 让 localizedDescription 确定（默认实现是系统长文案）
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "Boom" }
        }
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/cq_batch_\($0).mov") }
        var imported: [URL] = []
        await importer.runBatch(count: urls.count,
                                resolveURL: { index in
                                    // 第 2 条读取失败：其余两条必须照常导入
                                    if index == 1 { throw Boom() }
                                    return urls[index]
                                },
                                importURL: { imported.append($0); return .ok })
        XCTAssertEqual(imported, [urls[0], urls[2]], "部分失败不得中断整批")
        XCTAssertEqual(importer.errorMessage, "成功 2 条，失败 1 条（相册读取失败：Boom）")
        XCTAssertFalse(importer.isLoading)
    }

    func testBatchImportFailureIsCountedNotFatal() async {
        let importer = PhotoLibraryImporter()
        let ok = URL(fileURLWithPath: "/tmp/cq_batch_ok.mov")
        // 2000 = kDecodeError（importMedia 对"打不开/解析不了"的返回）。
        // MEDIA-022：错误文案经 Status.userText 分级 → "文件解析失败"（原为裸 text）。
        await importer.runBatch(count: 2,
                                resolveURL: { $0 == 0 ? ok : URL(fileURLWithPath: "/tmp/cq_batch_bad.mov") },
                                importURL: { $0 == ok ? .ok : Status(rawValue: 2000) })
        XCTAssertEqual(importer.errorMessage, "成功 1 条，失败 1 条（导入失败：文件解析失败）")
        XCTAssertFalse(importer.isLoading)
    }

    func testBatchAllFailuresSurfacesLastDetailAndImportsNothing() async {
        let importer = PhotoLibraryImporter()
        struct Boom: Error {}
        var imported: [URL] = []
        await importer.runBatch(count: 2,
                                resolveURL: { _ in throw Boom() },
                                importURL: { imported.append($0); return .ok })
        XCTAssertTrue(imported.isEmpty, "全失败不得产生素材")
        XCTAssertEqual(importer.errorMessage?.hasPrefix("相册读取失败"), true,
                       "零成功走既有错误路径：展示最后一条失败详情")
        XCTAssertFalse(importer.isLoading)
    }

    // MARK: 与真 ViewModel 组合（生产接线 = sequencedImport → importMedia）

    func testFunnelIntoRealViewModelCreatesClip() async throws {
        let viewModel = try EditorViewModel()
        guard FileManager.default.fileExists(atPath: RepoPath.goldenVideo) else {
            return XCTFail("golden 夹具缺失：\(RepoPath.goldenVideo)")
        }
        let importer = PhotoLibraryImporter()
        let url = URL(fileURLWithPath: RepoPath.goldenVideo)

        // 生产接线同款闭包：importMedia + 等本条落库（批量顺序保证的泵）
        await importer.runBatch(count: 1,
                                resolveURL: { _ in url },
                                importURL: importer.sequencedImport(into: viewModel))

        XCTAssertNil(importer.errorMessage, "生产接线导入 golden 应成功")
        // 建轨 + 追加片段是异步提交：泵主队列等版本推进到 3（同 MediaImportTests）
        // async 上下文禁 RunLoop.main.run(until:)（Swift 6 编译期拒绝）——用 Task.sleep 让出，
        // observer 的 @MainActor Task 趁挂起推进 applySnapshot。
        let deadline = Date().addingTimeInterval(5)
        while viewModel.timeline.version < 3 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(viewModel.mediaLibrary.count, 1, "素材表应出现条目（D3：引用原路径）")
        XCTAssertEqual(viewModel.timeline.clips.count, 1, "视频轨自动创建并追加片段")
        XCTAssertGreaterThan(viewModel.timeline.clips.first?.duration.value ?? 0, 0)
    }

    func testSequencedImportBatchAppendsInOrderWithoutOverlap() async throws {
        let viewModel = try EditorViewModel()
        guard FileManager.default.fileExists(atPath: RepoPath.goldenVideo) else {
            return XCTFail("golden 夹具缺失：\(RepoPath.goldenVideo)")
        }
        let importer = PhotoLibraryImporter()
        let url = URL(fileURLWithPath: RepoPath.goldenVideo)

        // 批量 3 条走生产闭包：若逐条不等落库，第 2 条起会以同一 end 提交、
        // 被内核按重叠拒绝 —— 本用例是 sequencedImport 泵的回归锁。
        await importer.runBatch(count: 3,
                                resolveURL: { _ in url },
                                importURL: importer.sequencedImport(into: viewModel))

        XCTAssertNil(importer.errorMessage, "3 条 golden 顺序导入应全部成功")
        XCTAssertEqual(viewModel.mediaLibrary.count, 3,
                       "importMedia 每次调用都注册新素材（不按路径去重），3 次导入 = 3 条")
        // 同上：async 上下文用 Task.sleep 让出（RunLoop.main.run 在 Swift 6 编译期拒绝）
        let deadline = Date().addingTimeInterval(5)
        while viewModel.timeline.clips.count < 3 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(viewModel.timeline.clips.count, 3, "三条片段全部落库")
        // 顺序与不重叠：按 start 升序逐段衔接（统一换算成秒比较，timescale 各异）
        func seconds(_ t: RationalTime) -> Double { Double(t.value) / Double(t.timescale) }
        let clips = viewModel.timeline.clips.sorted { $0.start.value < $1.start.value }
        XCTAssertEqual(seconds(clips[0].start), 0, accuracy: 0.01, "首条从 0 起")
        for (prev, next) in zip(clips, clips.dropFirst()) {
            XCTAssertEqual(seconds(next.start),
                           seconds(prev.start) + seconds(prev.duration),
                           accuracy: 0.01, "相邻片段必须首尾衔接（追加式不重叠）")
        }
    }
}
