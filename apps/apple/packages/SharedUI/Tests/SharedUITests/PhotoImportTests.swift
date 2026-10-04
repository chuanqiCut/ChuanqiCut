// SharedUI — 相册导入胶水验收（UIA-011）
//
// PhotosPicker 的系统选择器与 loadTransferable 需要真实 PHAsset，XCTest 宿主
// 没有相册数据，无法驱动（同 UIA-005"SwiftUI 手势不可测"的既有结论）—— 故把
// item→URL→importMedia 的状态机抽成 PhotoLibraryImporter（闭包注入），本文件锁：
//   * loading 翻转（resolve 期间 true，结束必复位）
//   * resolve 抛错 / 返回 nil → 只置错误信息，不触发导入（不留半截状态）
//   * 成功 → URL 原样汇入导入闭包；导入失败 → 错误文本带 Status
//   * 与真 ViewModel 组合：golden 视频 URL → 素材表 + 时间线最终一致
//     （等价 MediaImportTests 手法，证明生产接线闭包可用）
// 选择器接线（PhotosPicker / onChange）靠 App 冒烟与真机人工验证。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import XCTest
import ChuanqiCut
@testable import SharedUI

@MainActor
final class PhotoImportTests: XCTestCase {

    // MARK: 状态机（注入闭包，不依赖相册）

    func testLoadFailureSetsErrorAndSkipsImport() async {
        let importer = PhotoLibraryImporter()
        struct Boom: Error {}
        var imported: [URL] = []
        await importer.run(resolveURL: { throw Boom() },
                           importURL: { imported.append($0); return .ok })
        XCTAssertFalse(importer.isLoading, "失败后 loading 必须复位")
        XCTAssertEqual(importer.errorMessage?.hasPrefix("相册读取失败"), true)
        XCTAssertTrue(imported.isEmpty, "读取失败不得触发导入")
    }

    func testLoadNilSetsUnsupportedError() async {
        let importer = PhotoLibraryImporter()
        var imported: [URL] = []
        await importer.run(resolveURL: { nil },
                           importURL: { imported.append($0); return .ok })
        XCTAssertEqual(importer.errorMessage, "相册素材无法读取（类型不受支持）")
        XCTAssertTrue(imported.isEmpty, "解析不出 URL 不得触发导入")
        XCTAssertFalse(importer.isLoading)
    }

    func testLoadingFlipsDuringResolve() async {
        let importer = PhotoLibraryImporter()
        var loadingDuringResolve: Bool?
        await importer.run(resolveURL: {
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
        await importer.run(resolveURL: { url },
                           importURL: { imported.append($0); return .ok })
        XCTAssertEqual(imported, [url], "解析出的 URL 必须原样汇入导入闭包")
        XCTAssertNil(importer.errorMessage, "成功必须清空旧错误")
        XCTAssertFalse(importer.isLoading)
    }

    func testImportFailureSurfacesStatusText() async {
        let importer = PhotoLibraryImporter()
        // 2000 = kDecodeError（AppEntry.importMedia 对"打不开/解析不了"的用法）
        await importer.run(resolveURL: { URL(fileURLWithPath: "/tmp/cq_photo_item.mov") },
                           importURL: { _ in Status(rawValue: 2000) })
        XCTAssertEqual(importer.errorMessage?.hasPrefix("导入失败"), true)
        XCTAssertFalse(importer.isLoading, "导入失败 loading 同样复位")
    }

    // MARK: 与真 ViewModel 组合（生产接线 = importMedia）

    func testFunnelIntoRealViewModelCreatesClip() async throws {
        let viewModel = try EditorViewModel()
        guard FileManager.default.fileExists(atPath: RepoPath.goldenVideo) else {
            return XCTFail("golden 夹具缺失：\(RepoPath.goldenVideo)")
        }
        let importer = PhotoLibraryImporter()
        let url = URL(fileURLWithPath: RepoPath.goldenVideo)

        // 生产接线同款闭包：resolve 出的相册 tmp URL 走 importMedia
        await importer.run(resolveURL: { url },
                           importURL: { viewModel.importMedia(url: $0) })

        XCTAssertNil(importer.errorMessage, "生产接线导入 golden 应成功")
        // 建轨 + 追加片段是异步提交：泵主队列等版本推进到 3（同 MediaImportTests）
        let deadline = Date().addingTimeInterval(5)
        while viewModel.timeline.version < 3 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(viewModel.mediaLibrary.count, 1, "素材表应出现条目（D3：引用原路径）")
        XCTAssertEqual(viewModel.timeline.clips.count, 1, "视频轨自动创建并追加片段")
        XCTAssertGreaterThan(viewModel.timeline.clips.first?.duration.value ?? 0, 0)
    }
}
