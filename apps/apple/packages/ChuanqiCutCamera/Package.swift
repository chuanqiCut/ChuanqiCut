// swift-tools-version:6.1
import PackageDescription

// ChuanqiCutCamera — 相机域（iOS 原生，ADR-0014；ADR-0031 阶段 4 自 SharedUI/App target 迁出）
//
// ⚠️ 本 Package.swift 的 SPM target 只含**契约层**（Sources/ChuanqiCutCamera/：
//    CameraBeauty / CameraFilter / DetectionSmoothing / FaceMask，跨平台可编译），
//    作为 `swift test` 测试宿主在 macOS 上跑契约单测。
//    **实现层**（Sources/ChuanqiCutCameraImpl/：采集/渲染/录制/检测/BeautyKernel）
//    是 iOS 专属（AVCaptureSession + MetalKit + Metallib），不进 SPM target ——
//    由 ChuanqiCutCamera.podspec（仅 iOS）编译。两份构建定义描述同一模块名。
//
// 依赖：零外部依赖（契约层只用 CoreImage/Foundation；实现层同样不引 SDK/基座，
//       与 MediaSheet 的联动由壳层装配，横向零依赖，ADR-0031 决定 3）。

let package = Package(
    name: "ChuanqiCutCamera",
    platforms: [
        .iOS(.v16),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ChuanqiCutCamera", targets: ["ChuanqiCutCamera"])
    ],
    targets: [
        .target(
            name: "ChuanqiCutCamera",
            path: "Sources/ChuanqiCutCamera"
        ),
        .testTarget(
            name: "ChuanqiCutCameraTests",
            dependencies: ["ChuanqiCutCamera"],
            path: "Tests/ChuanqiCutCameraTests"
        ),
    ]
)
