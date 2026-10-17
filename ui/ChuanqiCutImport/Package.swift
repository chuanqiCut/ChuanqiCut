// swift-tools-version:6.1
import PackageDescription

// ChuanqiCutImport — 素材导入域（相册浏览器 UIA-011/012/013；ADR-0031 阶段 2）
//
// 依赖：仅 SharedUI 基座（MediaGridCell 用 Theme 配色）。Package.swift 仅作
// `swift test` 测试宿主；App 集成走 ChuanqiCutImport.podspec。

let package = Package(
    name: "ChuanqiCutImport",
    platforms: [ .iOS(.v16), .macOS(.v15) ],
    products: [ .library(name: "ChuanqiCutImport", targets: ["ChuanqiCutImport"]) ],
    dependencies: [ .package(path: "../SharedUI") ],
    targets: [
        .target(
            name: "ChuanqiCutImport",
            dependencies: [ .product(name: "SharedUI", package: "SharedUI") ],
            path: "Sources/ChuanqiCutImport"
        ),
        .testTarget(
            name: "ChuanqiCutImportTests",
            dependencies: ["ChuanqiCutImport"],
            path: "Tests/ChuanqiCutImportTests"
        ),
    ]
)
