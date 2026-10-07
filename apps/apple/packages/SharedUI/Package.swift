// swift-tools-version:6.1
import PackageDescription

// SharedUI — SwiftUI 共享编辑器组件（UIA-002）
//
// 被 iOSApp / MacApp 两个 target 消费。依赖 ChuanqiCut 绑定层（本地 SPM 包）。
//
// ⚠️ ChuanqiCut 绑定层的 XCFramework 是构建产物，clone 后须先跑：
//    tools/build/build_core_apple.sh && bindings/swift/prepare.sh

let package = Package(
    name: "SharedUI",
    platforms: [
        .iOS(.v16),
        .macOS(.v15),
    ],
    products: [
        .library(name: "SharedUI", targets: ["SharedUI"])
    ],
    dependencies: [
        .package(path: "../../../../bindings/swift")
    ],
    targets: [
        .target(
            name: "SharedUI",
            dependencies: [
                // ⚠️ 本地包身份取**目录名**（bindings/swift → "swift"）而非包内
                //    Package.swift 里的 name；写 "ChuanqiCut" 会报 unknown package。
                .product(name: "ChuanqiCut", package: "swift")
            ],
            path: "Sources/SharedUI"
        ),
    ]
)
