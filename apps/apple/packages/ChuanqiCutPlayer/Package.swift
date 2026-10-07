// swift-tools-version:6.1
import PackageDescription

// ChuanqiCutPlayer — 独立播放器域（UIA-015~027，ADR-0022 AVPlayer 过渡）
//
// ADR-0031 阶段 1 自 SharedUI 迁出（INFRA-015，2026-10-07）。本包**零外部依赖**：
// 不依赖 ChuanqiCut SDK（AVPlayer 过渡期纯系统框架），也不依赖 SharedUI 基座
// （与 MediaSheet 的联动经 PlayerPreviewInjector 由壳层反向注入，横向零依赖）。
//
// ⚠️ Package.swift 仅作 `swift test` 测试宿主；App 集成走 ChuanqiCutPlayer.podspec
//    （App 不使用 SPM，INFRA-009 决策）。两份构建定义描述同一份 Sources/，
//    改动源码接口时两边都要顾到。

let package = Package(
    name: "ChuanqiCutPlayer",
    platforms: [
        .iOS(.v16),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ChuanqiCutPlayer", targets: ["ChuanqiCutPlayer"])
    ],
    targets: [
        .target(
            name: "ChuanqiCutPlayer",
            path: "Sources/ChuanqiCutPlayer"
        ),
        .testTarget(
            name: "ChuanqiCutPlayerTests",
            dependencies: ["ChuanqiCutPlayer"],
            path: "Tests/ChuanqiCutPlayerTests"
        ),
    ]
)
