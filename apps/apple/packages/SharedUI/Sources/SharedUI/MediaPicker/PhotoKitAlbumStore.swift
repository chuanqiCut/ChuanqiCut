// SharedUI — 自研相册浏览器：PhotoKit 取数层（UIA-013）
//
// 取数 seam：`AlbumFetching` 协议把 PhotoKit 挡在本文件内，ViewModel / 纯逻辑
// 依赖注入夹具即可脱离相册单测（同 PhotoLibraryImporter 的注入手法）。
//
// 两个关键 PhotoKit 行为（实现要点，均来自 ZL/HX 的成熟处理）：
// 1. **iCloud 判定**：PHAsset 没有公开的"本地可用"标志 —— 缩略图请求用
//    `isNetworkAccessAllowed = false`，拿不到图且 info 里
//    PHImageResultIsInCloudKey = true 即"仅云端"。确认导出时才允许联网拉取。
// 2. **选中项 → 文件 URL**：core 的 probe/解码消费文件 URL（Spec §2 方向锚），
//    用 PHAssetResourceManager.writeData 落到我方 tmp（iCloud 素材在这一步
//    联网下载，progress 上抛给确认按钮）—— 不改"选中项落成文件 URL"的导入
//    落盘路径，落盘优化归素材库整理任务。

import Foundation
import Photos

// MARK: - 取数协议（测试 seam）

protocol AlbumFetching {

    /// 相簿列表（首项固定为合成条目"最近项目"）。
    func fetchAlbums() -> [AlbumSummary]

    /// 相簿内全部视频（按创建时间倒序 —— 相册 App 的默认观感）。
    func fetchAssets(albumID: String) -> [AssetDescriptor]

    /// 缩略图请求（回调可能先到低清图再到高清图，onDelivery 主线程回调）。
    /// 返回 nil 表示 asset 不存在（已删除等）。
    func requestThumbnail(assetID: String, targetSize: CGSize,
                          onDelivery: @escaping (PlatformImage?, Bool) -> Void)

    /// 取消在途缩略图请求（cell 复用/滚出可视区时调用）。
    func cancelThumbnail(assetID: String)

    /// 选中项 → 我方 tmp 文件 URL（联网下载 iCloud 素材，progress 0...1）。
    func resolveFileURL(assetID: String,
                        progress: @escaping (Double) -> Void) async throws -> URL
}

// MARK: - PhotoKit 生产实现

final class PhotoKitAlbumStore: AlbumFetching {

    /// "最近项目"的合成相簿 ID（fetchAssets 对它走全库视频查询）。
    static let recentAlbumID = "__cq_recent__"

    private let cachingImageManager = PHCachingImageManager()

    // ---- 相簿 ----

    func fetchAlbums() -> [AlbumSummary] {
        var albums: [AlbumSummary] = []
        let videoOptions = PHFetchOptions()
        videoOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)

        // 最近项目：smartAlbumUserLibrary（相册 App 首页同源）
        let recent = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
        let recentCount = recent.firstObject.map {
            PHAsset.fetchAssets(in: $0, options: videoOptions).count
        } ?? 0
        if recentCount > 0 {
            albums.append(AlbumSummary(id: Self.recentAlbumID, title: "最近项目", assetCount: recentCount))
        }

        // 其余智能相簿（收藏 / 视频等），只留有视频的
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .any, options: nil)
        smartAlbums.enumerateObjects { collection, _, _ in
            // 最近项目已合成；最近删除（回收站）没有选取意义，一并排除
            guard collection.assetCollectionSubtype != .smartAlbumUserLibrary,
                  collection.assetCollectionSubtype != .smartAlbumRecentlyDeleted else { return }
            let count = PHAsset.fetchAssets(in: collection, options: videoOptions).count
            guard count > 0 else { return }
            albums.append(AlbumSummary(id: collection.localIdentifier,
                                       title: collection.localizedTitle ?? "未命名相簿",
                                       assetCount: count))
        }

        // 用户自建相簿
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: videoOptions).count
            guard count > 0 else { return }
            albums.append(AlbumSummary(id: collection.localIdentifier,
                                       title: collection.localizedTitle ?? "未命名相簿",
                                       assetCount: count))
        }
        return albums
    }

    func fetchAssets(albumID: String) -> [AssetDescriptor] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let fetchResult: PHFetchResult<PHAsset>
        if albumID == Self.recentAlbumID {
            fetchResult = PHAsset.fetchAssets(with: options)
        } else if let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID], options: nil).firstObject {
            fetchResult = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            return []
        }

        var descriptors: [AssetDescriptor] = []
        fetchResult.enumerateObjects { asset, _, _ in
            descriptors.append(AssetDescriptor(
                id: asset.localIdentifier,
                durationSeconds: asset.duration,
                isLocallyAvailable: false))   // 真实可用性在缩略图请求时判定（cell 回填）
        }
        return descriptors
    }

    // ---- 缩略图 ----

    func requestThumbnail(assetID: String, targetSize: CGSize,
                          onDelivery: @escaping (PlatformImage?, Bool) -> Void) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            onDelivery(nil, false)
            return
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic      // 先低清后高清，两次回调
        options.isNetworkAccessAllowed = false     // 云端素材不在此联网（确认导出时才拉）
        options.isSynchronous = false
        let isCloudAsset = { (info: [AnyHashable: Any]) -> Bool in
            (info[PHImageResultIsInCloudKey] as? Bool) ?? false
        }
        cachingImageManager.requestImage(
            for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            DispatchQueue.main.async {
                onDelivery(image, !degraded && isCloudAsset(info ?? [:]))
            }
        }
    }

    func cancelThumbnail(assetID: String) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
        cachingImageManager.stopCachingImages(for: asset, targetSize: Self.thumbnailTargetSize,
                                              contentMode: .aspectFill, options: nil)
    }

    /// cell 请求的目标尺寸（2x 缩略图，覆盖 minColumnWidth ~ 120pt 的显示）。
    static let thumbnailTargetSize = CGSize(width: 240, height: 240)

    // ---- 选中项落盘 ----

    func resolveFileURL(assetID: String,
                        progress: @escaping (Double) -> Void) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw AlbumResolveError.assetNotFound
        }
        // 视频资源优先级：fullSizeVideo（含滤镜/慢动作调整结果）> video（原始）
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .fullSizeVideo }
            ?? resources.first { $0.type == .video }
        guard let videoResource = resource else {
            throw AlbumResolveError.videoResourceMissing
        }

        let ext = (videoResource.originalFilename as NSString).pathExtension
        let fileExt = ext.isEmpty ? "mov" : ext
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cq_album_\(UUID().uuidString).\(fileExt)")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true     // iCloud 素材在此下载（Spec §3）
        options.progressHandler = { fraction in
            DispatchQueue.main.async { progress(fraction) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: videoResource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return url
    }

    enum AlbumResolveError: LocalizedError {
        case assetNotFound
        case videoResourceMissing
        var errorDescription: String? {
            switch self {
            case .assetNotFound: return "素材不存在或已删除"
            case .videoResourceMissing: return "找不到可导出的视频资源"
            }
        }
    }
}
