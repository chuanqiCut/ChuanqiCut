// SharedUI — 测试路径 helper（唯一真源）
//
// ⚠️ #filePath 上溯层数极易错（本轮 TimelineTests/MediaImportTests 各错过一次：
// 4 层/6 层都不对，正确是 7 层）——故集中到这里，**新测试不要再手写上溯链**。

import Foundation

enum RepoPath {
    /// 仓库根（本文件位置：apps/apple/packages/SharedUI/Tests/SharedUITests/）。
    static let root: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // 1 → Tests/SharedUITests
        .deletingLastPathComponent()   // 2 → Tests
        .deletingLastPathComponent()   // 3 → SharedUI 包根
        .deletingLastPathComponent()   // 4 → packages
        .deletingLastPathComponent()   // 5 → apple
        .deletingLastPathComponent()   // 6 → apps
        .deletingLastPathComponent()   // 7 → 仓库根
        .path

    static var goldenVideo: String { root + "/tests/golden/frames/gf_1080p_h264.mp4" }
}
