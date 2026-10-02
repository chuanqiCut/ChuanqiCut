// swift-tools-version:6.1
import PackageDescription

// ChuanqiCut Swift 绑定（BIND-002）
//
// 结构：
//   CChuanqiCut  —— binaryTarget：内核 XCFramework（自带 Modules/module.modulemap，
//                   故 Swift 可直接 `import CChuanqiCut`）
//   ChuanqiCut   —— Swift target：面向 App 的封装（本 package 的对外产物）
//
// ⚠️ 为什么不用「C target + 手写 modulemap」包一层：
//    2026-09-29 实测 —— SPM 的 C target 在「只有头文件、无源文件」时不生成 module，
//    消费侧报 `no such module`。改为让 XCFramework 自带 modulemap（Apple 官方做法）。
//
// ⚠️ 平台基线见 ADR-0010：iOS 16 / macOS 15.4。SPM 的 platforms 只能声明到 minor，
//    故写 .v15；**实际最低 macOS 15.4**，由内核静态库的部署目标保证。
//
// ⚠️ Frameworks/ChuanqiCut.xcframework 是**构建产物**（符号链接到 build/apple），
//    不入库。clone 后须先跑 tools/build/build_core_apple.sh，
//    再跑 bindings/swift/prepare.sh 建立链接。

let package = Package(
    name: "ChuanqiCut",
    platforms: [
        .macOS(.v15),
        .iOS(.v16),
    ],
    products: [
        .library(name: "ChuanqiCut", targets: ["ChuanqiCut"])
    ],
    targets: [
        .binaryTarget(
            name: "ChuanqiCutCore",
            path: "Frameworks/ChuanqiCut.xcframework"
        ),
        // C target 必须有**源文件**才会生成 module（仅头文件不够，实测报
        // "no such module"），故配了一个 shim.c。头文件用符号链接指向内核，不复制。
        .target(
            name: "CChuanqiCut",
            dependencies: ["ChuanqiCutCore"],
            path: "Sources/CChuanqiCut",
            // ⚠️ 必须显式链接：SPM **不会**自动把 binaryTarget 里的静态库链进最终产物。
            //    不写这一行时 `swift build` 仍然成功（library target 只编译不链接），
            //    直到 `swift test` 要链接可执行宿主时才报 "symbol(s) not found" ——
            //    即：编译绿 ≠ 能链接（又一次"绿灯≠可用"）。
            //
            // ⚠️ 系统框架清单与 ChuanqiCut.podspec 的 ss.frameworks 一致：一旦链接
            //    拉入预览 / 媒体 TU（cq_sdk_preview.o → PAL 图形 + 解码），VideoToolbox /
            //    CoreMedia / Metal 等符号就必须有归属（2026-10-02 UIA-003 实测）。
            //    libc++ 同理 —— 内核是 C++20，之前测试碰不到 C++ TU 所以没暴露。
            linkerSettings: [
                .linkedLibrary("ChuanqiCut"),
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("QuartzCore"),
                // IOSurface 是 macOS 专有框架（iOS SDK 无此框架，PALA-002 已踩过）。
                .linkedFramework("IOSurface", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "ChuanqiCut",
            dependencies: ["CChuanqiCut"],
            path: "Sources/ChuanqiCut",
            linkerSettings: [
                .linkedLibrary("ChuanqiCut"),
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "ChuanqiCutTests",
            dependencies: ["ChuanqiCut"],
            path: "Tests/ChuanqiCutTests"
        ),
    ]
)
