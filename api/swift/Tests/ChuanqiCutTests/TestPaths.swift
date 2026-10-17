// ChuanqiCutTests — 测试路径 helper（唯一真源）
//
// ⚠️ #filePath 上溯层数极易错（本轮 TimelineTests 用了 4 层，正确是 5 层）
// ——集中到这里，**新测试不要再手写上溯链**。

import Foundation

enum TestPaths {
    /// 仓库根（本文件位置：api/swift/Tests/ChuanqiCutTests/）。
    /// 2026-10-07 引擎源收拢 engine/（INFRA-022）：上溯 5→6 层。
    /// 2026-10-16 门面外提 api/swift/（INFRA-032）：上溯 6→5 层。
    static let root: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // 1 → ChuanqiCutTests
        .deletingLastPathComponent()   // 2 → Tests
        .deletingLastPathComponent()   // 3 → swift
        .deletingLastPathComponent()   // 4 → api
        .deletingLastPathComponent()   // 5 → 仓库根
        .path

    static var goldenVideo: String { root + "/tests/golden/frames/gf_1080p_h264.mp4" }

    /// HEVC golden（MEDIA-022）：iPhone 相册默认编码的回归基线。
    static var goldenVideoHevc: String { root + "/tests/golden/frames/gf_1080p_hevc.mp4" }
}
