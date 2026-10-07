// swift-tools-version:6.1
import PackageDescription

// ChuanqiCutEditor — 编辑器域（三件套 + Timeline + EditorViewModel；UIA-002 起，
// UIA-032 重构主战场；ADR-0031 阶段 5）
//
// 依赖：ChuanqiCut SDK（EditorViewModel 持内核 Session）+ SharedUI 基座
// （Theme + PlayerPreviewInjector/MediaLibraryInjector 注入点）。
// ⚠️ ChuanqiCut 绑定层的 XCFramework 是构建产物，clone 后须先跑：
//    tools/build/build_core_apple.sh && bindings/swift/prepare.sh

let package = Package(
    name: "ChuanqiCutEditor",
    platforms: [ .iOS(.v16), .macOS(.v15) ],
    products: [ .library(name: "ChuanqiCutEditor", targets: ["ChuanqiCutEditor"]) ],
    dependencies: [
        .package(path: "../../../../engine/bindings/swift"),
        .package(path: "../SharedUI"),
    ],
    targets: [
        .target(
            name: "ChuanqiCutEditor",
            dependencies: [
                // ⚠️ 本地包身份取目录名（bindings/swift → "swift"），同 SharedUI 惯例
                .product(name: "ChuanqiCutEngine", package: "swift"),
                .product(name: "SharedUI", package: "SharedUI"),
            ],
            path: "Sources/ChuanqiCutEditor"
        ),
        .testTarget(
            name: "ChuanqiCutEditorTests",
            dependencies: ["ChuanqiCutEditor"],
            path: "Tests/ChuanqiCutEditorTests"
        ),
    ]
)
