// BeautyKernel — 磨皮 Metal 双边滤波引擎（CAM-012，ADR-0014 §3）
//
// App 层资产：本文件与同目录 beauty_bilateral.metal 属相机特效域，
// 不进 SDK shader 清单（红线 #6 边界见 ADR-0014 §3）。
//
// 加载路径：beauty_bilateral.metal 由 Xcode Metal 编译期内建为
// default.metallib（iOS 17.2 SDK 的 CIKernel 只有
// fromMetalLibraryData:，没有源码串初始化器 —— P47），本类从
// Bundle 扫出 metallib → CIKernel(functionName:fromMetalLibraryData:)。
// 加载失败 / kernel 缺失 → init 返回 nil → SharedUI 默认 CI 实现兜底
//（能力缺失降级，不悄悄假装升级）。
//
// 算法：亮度域双边滤波，两 pass（见 .metal 文件头管线图）。
//   磨皮强度滑杆 → kernel 参数的映射是纯函数（BeautyKernelProfile），
//   对滑杆单调：taps / σr / mix 三者随强度不减。
//
// 线程模型：实例不可变（kernel 对象 init 后只读），apply 只构造 CIImage
// DAG（值语义，懒执行），可被预览渲染线程与录制队列并发调用；
// 实际渲染由共享 CIContext 完成（线程安全）。
//
// 坐标契约：仅支持 extent origin = (0,0) 的输入（相机帧恒成立）；
// 其他情况 apply 返回 nil → 调用方回落默认实现。

import CoreImage
import Foundation
import os.log
import os

// MARK: - 强度 → kernel 参数映射（纯函数，可单测）

/// 滑杆 0...1 → kernel 参数。三个参数对强度**单调不减**，这是
/// 「磨皮输出对滑杆单调」验收的数学前提（GPU 侧实证归 beauty_harness）。
enum BeautyKernelProfile {

    /// 半分辨率采样半径（tap 数，2...5）：半径越大平滑范围越大。
    /// 离散取值（阶梯不减）——避免每帧核半径连续变化引入的调度抖动。
    static func taps(strength: Double) -> Int {
        2 + Int((3.0 * min(max(strength, 0), 1)).rounded())
    }

    /// 亮度域范围 σ：越大磨得越狠、保边越弱。
    /// 上限 0.11 是 GPU 实证定案（beauty_harness 边缘剖面）：未标记 BGRA 经
    /// 默认 CIContext 表现为 gamma 域，硬边 ΔY≈0.37，σr=0.15 时跨边权重
    /// 只压到 ~5%，边退化成 6px 渐变坡（保持率 30% 不达标）；σr≤0.11 时
    /// 权重 ≤0.4%，保持率回到 ≥60%。mix 仍严格等于滑杆（任务卡口径）。
    static func rangeSigma(strength: Double) -> Float {
        Float(0.03 + 0.08 * min(max(strength, 0), 1))
    }

    /// 与原图的混合系数（0...1）：1 = 完全采用双边结果。
    static func mix(strength: Double) -> Float {
        Float(min(max(strength, 0), 1))
    }

    /// 半分辨率 extent（向上取整，不丢末行末列；Swift 侧与 kernel 的
    /// inv_scale/down_scale 映射配套）。
    static func halfExtent(of extent: CGRect) -> CGRect {
        CGRect(x: 0, y: 0,
               width: (Int(extent.width) + 1) / 2,
               height: (Int(extent.height) + 1) / 2)
    }
}

// MARK: - Metal 磨皮引擎

final class BeautyKernel: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.chuanqi.cut", category: "camera.beauty")

    static let downHFunctionName = "cq_beauty_down_h"
    static let upVMixFunctionName = "cq_beauty_up_v_mix"

    private let downH: CIKernel
    private let upVMix: CIKernel

    /// - Parameter libraryData: 编译期内建的 .metallib 原始数据。
    ///   kernel 缺失或加载失败返回 nil（调用方走 SharedUI 默认实现）。
    init?(libraryData: Data) {
        guard let downH = try? CIKernel(functionName: Self.downHFunctionName,
                                        fromMetalLibraryData: libraryData),
              let upVMix = try? CIKernel(functionName: Self.upVMixFunctionName,
                                         fromMetalLibraryData: libraryData) else {
            return nil
        }
        self.downH = downH
        self.upVMix = upVMix
    }

    /// 从宿主各 bundle 扫出 metallib（INFRA-018 Pod 化后产物位置有两种布局：
    /// ① static pod `s.resources` 直拷主 bundle（默认）；② resource_bundles 形态的
    /// `ChuanqiCutCamera.bundle`。双路兜底，谁先扫到含本卡 kernel 的用谁。
    /// 顺序：Pod 资源包（若存在）→ main（default.metallib 优先逻辑在单 bundle 内）。
    static func libraryDataInHostBundles() -> Data? {
        var bundles: [Bundle] = []
        if let podBundleURL = Bundle.main.url(forResource: "ChuanqiCutCamera", withExtension: "bundle"),
           let podBundle = Bundle(url: podBundleURL) {
            bundles.append(podBundle)
        }
        bundles.append(.main)
        for bundle in bundles {
            if let data = libraryData(in: bundle) { return data }
        }
        return nil
    }

    /// 从单个 bundle 扫出包含本卡 kernel 的 metallib。
    /// 优先 default.metallib；找不到或 kernel 不齐时遍历其余 metallib。
    static func libraryData(in bundle: Bundle) -> Data? {
        let urls = bundle.urls(forResourcesWithExtension: "metallib", subdirectory: nil) ?? []
        let sorted = urls.sorted { ($0.lastPathComponent == "default.metallib" ? 0 : 1)
            < ($1.lastPathComponent == "default.metallib" ? 0 : 1) }
        for url in sorted {
            guard let data = try? Data(contentsOf: url) else { continue }
            let names = CIKernel.kernelNames(fromMetalLibraryData: data)
            if names.contains(downHFunctionName), names.contains(upVMixFunctionName) {
                return data
            }
        }
        return nil
    }

    /// 组装 SharedUI 注入点用的引擎闭包。
    /// 强持有 self：闭包被 CameraBeautyEngine 全局安装（进程级生命周期），
    /// 弱捕获会让相机页销毁后引擎静默失效回落默认实现 —— 行为不一致；
    /// kernel 本体只有两个 CIKernel 对象，常驻成本可忽略，重装时整体替换。
    /// 返回 nil = 引擎放弃（本卡两 pass 之外的情况，如非零 origin / 过小图），
    /// SharedUI 自动回落默认 CI 近似 —— 引擎永不制造黑帧或崩坏输出。
    ///
    /// ⚠️ 黏性回落（CAM-017）：引擎**间歇** nil 会让画面逐帧在「双边/高斯兜底」
    /// 两种视觉之间翻转 —— 真机首验的「磨皮闪屏」。连续 3 次 nil 即本会话停用
    /// 引擎（nil 计数走 os_log，可定位设备侧失败原因），只走默认实现。
    /// 黏性回落状态盒（@Sendable 闭包捕获可变局部变量在 Swift 6 下非法，
    /// 走 P49 RecorderBox 同款 `@unchecked Sendable` + 锁的既有惯例）。
    private final class FallbackState: @unchecked Sendable {
        private let lock = NSLock()
        private var consecutiveFailures = 0
        private var disabled = false

        /// false = 已停用（调用方直接走默认实现，不再尝试引擎）。
        func isEnabled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !disabled
        }

        func record(_ succeeded: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if succeeded {
                consecutiveFailures = 0
                return
            }
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                disabled = true
                BeautyKernel.logger.error("磨皮引擎连续 \(self.consecutiveFailures, privacy: .public) 次放弃处理，本会话回落默认 CI 实现")
            }
        }
    }

    func smoothingEngine() -> CameraBeautySmoothingEngine {
        let state = FallbackState()
        return { image, strength in
            guard state.isEnabled() else { return nil }
            let result = self.apply(image, strength: strength)
            state.record(result != nil)
            return result
        }
    }

    /// 幂等安装：bundle 里有本卡 metallib 才装，否则保持 SharedUI 默认实现。
    /// 每条路径一次性日志（CAM-018 诊断：修「引擎是否在跑」不可知——历史上
    /// 96B 空壳 metallib 曾静默回落默认实现且无从发现，见 ADR-0021）。
    static func installSharedSmoothingIfNeeded() {
        guard CameraBeautyEngine.smoothing == nil else { return }
        guard let data = libraryDataInHostBundles() else {
            statusLogger.error("beauty engine FALLBACK: bundle 无含 cq_beauty kernels 的 metallib → SharedUI 默认 CI 实现")
            return
        }
        guard let kernel = BeautyKernel(libraryData: data) else {
            statusLogger.error("beauty engine FALLBACK: metallib 存在但 CIKernel 初始化失败 → 默认实现")
            return
        }
        CameraBeautyEngine.smoothing = kernel.smoothingEngine()
        statusLogger.notice("beauty engine INSTALLED: Metal 双边滤波（两 pass CIKernel）")
    }

    private static let statusLogger = Logger(subsystem: "com.chuanqi.cut", category: "beauty")

    /// 双 pass 磨皮。失败返回 nil（回落默认实现），不抛错不崩溃。
    func apply(_ image: CIImage, strength: Double) -> CIImage? {
        let extent = image.extent
        guard strength > 0,
              extent.origin.x == 0, extent.origin.y == 0,
              extent.width >= 4, extent.height >= 4 else {
            return nil
        }

        let halfExtent = BeautyKernelProfile.halfExtent(of: extent)
        let taps = BeautyKernelProfile.taps(strength: strength)
        let sigma = BeautyKernelProfile.rangeSigma(strength: strength)
        let mixT = BeautyKernelProfile.mix(strength: strength)
        let fullW = CGFloat(Int(extent.width))
        let fullH = CGFloat(Int(extent.height))
        let halfW = halfExtent.width
        let halfH = halfExtent.height

        // Pass 1：下采样 + 水平双边（输出半分辨率 extent）。
        let invScale = CIVector(x: fullW / halfW, y: fullH / halfH)
        guard let horizontal = downH.apply(
            extent: halfExtent,
            roiCallback: { _, _ in extent },
            arguments: [image, invScale, NSNumber(value: taps), NSNumber(value: sigma)])
        else { return nil }

        // Pass 2：垂直双边 + 上采样 + 混合（输出原图 extent，保边混合）。
        let downScale = CIVector(x: halfW / fullW, y: halfH / fullH)
        return upVMix.apply(
            extent: extent,
            roiCallback: { index, _ in index == 0 ? halfExtent : extent },
            arguments: [horizontal, image, downScale,
                        NSNumber(value: taps), NSNumber(value: sigma), NSNumber(value: mixT)])
    }
}
