// FaceWarp — 美型 Metal warp 引擎（CAM-013，ADR-0014 §3）
//
// 加载纪律与 BeautyKernel 完全同构：face_warp.metal 由壳工程 postBuildScripts
// 编译为 face_warp.metallib（-fcikernel 两阶段，ADR-0021），本类从宿主 bundle
// 扫出含 cq_face_warp 的 metallib → CIWarpKernel 加载；扫描失败 / kernel 缺失
// → shared == nil → 处理链**跳过美型**（诚实降级，无 CI 兜底、不做假效果）。
//
// 输入：契约层 FaceWarpGeometry.controls 生成的控制点（归一化 origin 左上），
// 本类只做打包（8 槽定长 + 尾部补零）与 kernel 调用；算法数学全部在契约层
// （macOS 可单测）。extent 非 (0,0) origin 或过小时直通（相机帧恒成立，
// 防御分支与 BeautyKernel.apply 同口径）。
//
// 线程模型：实例不可变（kernel init 后只读），apply 只构造 CIImage DAG
//（值语义，懒执行）；预览渲染线程 / 拍照采集队列 / 录制 videoQueue 可并发调用，
// 实际渲染由共享 CIContext 完成。

import CoreImage
import Foundation
import os

final class FaceWarp: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.chuanqi.cut", category: "camera.reshape")

    static let functionName = "cq_face_warp"
    /// kernel 定长槽位（上睑×2 + 下睑×2 + 下巴 + 左右颊 = 7，留 1 空位给扩展）
    static let slotCount = 8

    private let kernel: CIWarpKernel

    /// 进程级单例。nil = 本设备无法加载美型引擎（metallib 缺失/损坏），
    /// 消费方跳过美型步骤——一次性日志可定位（P60 伪绿教训：静默失败不能复现）。
    static let shared: FaceWarp? = {
        guard let data = BeautyKernel.libraryDataInHostBundles(requiring: [functionName]) else {
            logger.error("warp engine FALLBACK: bundle 无含 cq_face_warp 的 metallib → 美型跳过")
            return nil
        }
        guard let warp = FaceWarp(libraryData: data) else {
            logger.error("warp engine FALLBACK: metallib 存在但 CIWarpKernel 初始化失败 → 美型跳过")
            return nil
        }
        logger.notice("warp engine INSTALLED: 局部圆域位移场 warp（单 pass CIWarpKernel）")
        return warp
    }()

    /// - Parameter libraryData: 编译期内建 .metallib 原始数据。kernel 缺失或
    ///   加载失败返回 nil（调用方跳过美型）。
    init?(libraryData: Data) {
        guard let kernel = try? CIWarpKernel(functionName: Self.functionName,
                                             fromMetalLibraryData: libraryData) else {
            return nil
        }
        self.kernel = kernel
    }

    /// 美型 warp。off / 无锚点 / 控制点为空 → 原样返回（=== 恒等或同值 DAG）。
    func apply(to image: CIImage, anchors: CameraReshapeAnchors?,
               params: CameraReshapeParams) -> CIImage {
        guard !params.isOff, let anchors else { return image }
        return apply(to: image, controls: FaceWarpGeometry.controls(from: anchors, params: params))
    }

    /// 通用控制点入口（CAM-025 美体复用同一 kernel/打包路径；人脸美型与美体
    /// 只是控制点来源不同，位移场数学与 shader 完全共享）。
    func apply(to image: CIImage, controls: [FaceWarpControl]) -> CIImage {
        guard !controls.isEmpty else { return image }
        let extent = image.extent
        guard extent.origin.x == 0, extent.origin.y == 0,
              extent.width >= 4, extent.height >= 4 else { return image }

        // 打包：有效控制点顺序填充，尾部补零槽（kernel 按半径 0 跳过）。
        var slots: [CIVector] = []
        var radii: [CGFloat] = []
        for index in 0..<Self.slotCount {
            if index < controls.count {
                let c = controls[index]
                slots.append(CIVector(x: c.center.x, y: c.center.y,
                                      z: c.offset.dx, w: c.offset.dy))
                radii.append(c.radius)
            } else {
                slots.append(CIVector(x: 0, y: 0, z: 0, w: 0))
                radii.append(0)
            }
        }
        let radiiA = CIVector(x: radii[0], y: radii[1], z: radii[2], w: radii[3])
        let radiiB = CIVector(x: radii[4], y: radii[5], z: radii[6], w: radii[7])
        let activeCount = NSNumber(value: min(controls.count, Self.slotCount))

        // ROI：源可能被采样到 dest 外扩最大位移处（kernel 内有 clamp，
        // 外扩只为让 CI 不裁掉边缘所需像素；maxRadius 与 kernel 同基准 = 帧高）。
        let maxShift = (radii.max() ?? 0) * extent.height
        let args: [Any] = slots + [radiiA, radiiB, activeCount]
        return kernel.apply(
            extent: extent,
            roiCallback: { _, dest in dest.insetBy(dx: -maxShift, dy: -maxShift) },
            arguments: args) ?? image
    }
}
