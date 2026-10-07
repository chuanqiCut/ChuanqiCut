// SharedUI — 播放器最近播放存储（UIA-021；PLAN-播放器进阶 P1）
//
// 跨会话记住最近播放的视频：
//   * 本地文件：macOS 未开 sandbox 直接存路径；iOS 的 fileImporter URL 存
//     security-scoped bookmark（跨会话重开仍可读）。
//   * 远程 URL：直接存绝对串（无 scope 语义，UIA-024 起出现）。
// 失效策略：无书签本地路径不存在 / bookmark 解析失败 → playbackURL 返回
// nil，Launcher 据此剔除条目（失效即消失，不留死条目）。
//
// 线程：@MainActor。持久化 = UserDefaults JSON（defaults 注入便于测试）。
// 共享实例 shared 供 Launcher 列表与 VM 记录同源使用。

import Foundation
import os

/// 最近播放条目。id = urlString（同一文件唯一，去重以此为准）。
struct RecentMediaItem: Codable, Equatable, Identifiable {
    let urlString: String
    let name: String
    let addedAt: Date
    let isRemote: Bool
    /// iOS 本地文件的安全作用域书签（远程 / macOS 无书签路径为 nil）。
    let bookmarkData: Data?

    var id: String { urlString }
}

@MainActor
final class PlayerRecentStore: ObservableObject {

    @Published private(set) var items: [RecentMediaItem] = []

    static let maxItems = 20
    private static let storageKey = "cq.player.recent"

    /// 共享实例（Launcher 列表与 VM 记录同源）。
    static let shared = PlayerRecentStore()

    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.chuanqi.cut", category: "PlayerRecentStore")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                items = try JSONDecoder().decode([RecentMediaItem].self, from: data)
            } catch {
                // 坏数据按空处理并覆盖重写（自愈，比卡死在坏状态好）
                log.error("最近播放解码失败，按空处理: \(String(describing: error), privacy: .public)")
                items = []
            }
        }
        pruneUnreachable()
    }

    /// 播放成功（引擎 ready）后记录：去重置顶 + 钳制上限。
    func record(url: URL, name: String) {
        let urlString = url.absoluteString
        items.removeAll { $0.urlString == urlString }
        let bookmark: Data?
        if url.isFileURL {
            #if os(iOS)
            // fileImporter 产出的 URL：bookmarkData 携带安全作用域，
            // 重启后 resolvingBookmarkData 恢复可读。
            bookmark = try? url.bookmarkData()
            #else
            bookmark = nil // macOS 未开 sandbox，路径即可重开
            #endif
        } else {
            bookmark = nil
        }
        let displayName = name.isEmpty ? url.lastPathComponent : name
        items.insert(RecentMediaItem(urlString: urlString,
                                     name: displayName,
                                     addedAt: Date(),
                                     isRemote: !url.isFileURL,
                                     bookmarkData: bookmark), at: 0)
        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }
        persist()
    }

    /// 条目当前是否可播；不可播 = 调用方剔除（失效即消失）。
    func playbackURL(for item: RecentMediaItem) -> URL? {
        if item.isRemote {
            return URL(string: item.urlString)
        }
        if let data = item.bookmarkData {
            // 解析失败 = 来源已失效（try? 语义化合理：失效条目剔除即可）
            // Swift 侧该 init 的 `bookmarkDataIsStale` 是 `inout Bool`（不是 ObjCBool）。
            var stale = false
            return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        }
        guard let url = URL(string: item.urlString) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func remove(_ item: RecentMediaItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    // MARK: 内部

    /// ⚠️ `urlString` 存的是 **`absoluteString`**（含 `file://` scheme），直接喂给
    /// `FileManager.fileExists(atPath:)` 恒为 false —— 初版就是这么写的，
    /// 于是「重新装载 = 全部条目判为失效并清空」，跨会话持久化名存实亡。
    /// 存在性判定只有这一处入口，`playbackURL` 也复用它（口径不再漂移）。
    private static func localPathExists(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 装载时清理已不可达的无书签本地条目（macOS 路径失效场景；
    /// 书签项不在此解析（开销大），延迟到 playbackURL 播放时判定）。
    private func pruneUnreachable() {
        let before = items.count
        items.removeAll { item in
            if item.isRemote { return false }
            if item.bookmarkData != nil { return false }
            return !Self.localPathExists(item.urlString)
        }
        if items.count != before {
            persist()
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            log.error("最近播放编码失败: \(String(describing: error), privacy: .public)")
        }
    }
}
