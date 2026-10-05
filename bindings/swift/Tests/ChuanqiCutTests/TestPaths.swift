// ChuanqiCutTests — 测试路径 helper（唯一真源）
//
// ⚠️ #filePath 上溯层数极易错（本轮 TimelineTests 用了 4 层，正确是 5 层）
// ——集中到这里，**新测试不要再手写上溯链**。

import Foundation

enum TestPaths {
    /// 仓库根（本文件位置：bindings/swift/Tests/ChuanqiCutTests/）。
    static let root: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // 1 → Tests/ChuanqiCutTests
        .deletingLastPathComponent()   // 2 → Tests
        .deletingLastPathComponent()   // 3 → bindings/swift
        .deletingLastPathComponent()   // 4 → bindings
        .deletingLastPathComponent()   // 5 → 仓库根
        .path

    static var goldenVideo: String { root + "/tests/golden/frames/gf_1080p_h264.mp4" }

    /// HEVC golden（MEDIA-022）：iPhone 相册默认编码的回归基线。
    static var goldenVideoHevc: String { root + "/tests/golden/frames/gf_1080p_hevc.mp4" }
}
