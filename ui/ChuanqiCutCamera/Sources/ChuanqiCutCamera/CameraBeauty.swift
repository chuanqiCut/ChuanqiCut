// SharedUI — 相机美颜（CAM-003 建立，CAM-012 改薄封装）
//
// 平台无关纯函数，与 CameraFilterPreset 同插槽约定：输入 CIImage 输出 CIImage，
// 预览 / 拍照 / 录制三路共用（WYSIWYG）。
//
// 职责分层（CAM-012 起）：
//   - 本文件 = **契约层**：参数结构（单调 / off 恒等直通）+ 磨皮算法注入点
//     + 默认实现兜底。调用方（预览/拍照/录制）零改动。
//   - 算法实现 = **可替换**：iOS 侧在启动时把 Metal 双边滤波引擎
//     （iOSApp Camera/Effects/BeautyKernel）装进 CameraBeautyEngine；
//     引擎返回 nil（设备/输入不支持）时自动回落本文件的默认 CI 近似。
//     macOS 等未注入方始终走默认实现 —— 默认实现必须永远保留。
//
// 默认算法档位（诚实定位）：**基础款**——高斯模糊 + 锐化保边的近似磨皮，
// 以及曝光/亮度的小步长美白。精细美型（瘦脸/大眼）归 CAM-013。
//
// 所有效果对参数**单调**（滑杆方向可预期），off（0,0）必须恒等直通（可测）。

import CoreImage
import Foundation

/// 磨皮算法引擎签名：`(输入图, 磨皮强度 0...1) -> 结果图`。
/// 返回 nil = 引擎放弃处理（能力缺失/输入不支持），调用方回落默认实现。
/// 实现要求：对强度单调、不改变 extent、只构造 CIImage DAG（懒执行，线程安全）。
public typealias CameraBeautySmoothingEngine = @Sendable (CIImage, Double) -> CIImage?

/// 语义蒙版引擎签名（CAM-027）：`(输入图, 归一化人脸框) -> 蒙版图`。
/// 返回 nil = 本帧不接管（无关键点 / 能力缺失）→ 调用方回落到框级椭圆蒙版
/// （`FaceMask.mask`，CAM-019 行为）——**默认即这条老路径，零回归**。
/// 实现要求：只构造 CIImage DAG（懒执行、线程安全），extent 与输入图一致。
public typealias CameraBeautySemanticMaskEngine = @Sendable (CIImage, [CGRect]) -> CIImage?

/// 磨皮算法注入点。原生侧（iOS App）启动时安装 Metal 引擎；不安装 =
/// 默认 CI 近似。锁保护：主线程写（启动期一次），渲染/录制线程读。
/// 实现说明：Swift 5.9（本机验证工具链）没有 nonisolated(unsafe)，用
/// 锁保护类 + 不可变 static let 持有，两种语言模式（5.9/6.x）都并发安全。
public enum CameraBeautyEngine {

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var impl: CameraBeautySmoothingEngine?
        private var maskImpl: CameraBeautySemanticMaskEngine?
        var smoothing: CameraBeautySmoothingEngine? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return impl
            }
            set {
                lock.lock()
                impl = newValue
                lock.unlock()
            }
        }
        /// 语义皮肤蒙版（CAM-027）。nil = 框级椭圆蒙版（老行为）。
        var semanticMask: CameraBeautySemanticMaskEngine? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return maskImpl
            }
            set {
                lock.lock()
                maskImpl = newValue
                lock.unlock()
            }
        }
    }

    private static let storage = Storage()

    /// 当前磨皮引擎。nil = 默认实现。
    public static var smoothing: CameraBeautySmoothingEngine? {
        get { storage.smoothing }
        set { storage.smoothing = newValue }
    }

    /// 当前语义皮肤蒙版（CAM-027）。**nil = 框级椭圆蒙版**，即 2026-10-08 之前的
    /// 全部行为——不安装注入点就零风险回归，这也是默认形态。
    public static var semanticMask: CameraBeautySemanticMaskEngine? {
        get { storage.semanticMask }
        set { storage.semanticMask = newValue }
    }

    /// 测试隔离用：恢复默认实现。
    public static func reset() {
        smoothing = nil
        semanticMask = nil
    }
}

/// 美颜参数。0...1，0 = 关闭。
public struct CameraBeautyParams: Equatable, Sendable {

    /// 磨皮强度（0 = 关）。
    public var smoothing: Double
    /// 美白强度（0 = 关）。
    public var brightening: Double

    public init(smoothing: Double = 0, brightening: Double = 0) {
        self.smoothing = min(max(smoothing, 0), 1)
        self.brightening = min(max(brightening, 0), 1)
    }

    /// 全关（直通）。
    public static let off = CameraBeautyParams(smoothing: 0, brightening: 0)

    public var isOff: Bool { smoothing <= 0 && brightening <= 0 }

    /// 应用美颜。off 时原样返回入参（=== 恒等，调用方无需特判）。
    ///
    /// faces 两态（CAM-019 §4；**2026-10-07 修订**：nil 从「全画面兜底」改为「直通」，
    /// 传哲定则：美颜/美型/美体/美妆等一切人像能力必须**算法驱动**，无算法即无效果，
    /// 不得退化为滤镜式全画面修改）：
    ///   nil  = 无检测数据（能力缺失/未接入/首帧前）→ **直通**（旧行为已废除）；
    ///   []   = 检测过但无脸 → **直通**（对齐美型/美体「无脸直通」口径）；
    ///   非空 = 图像归一化人脸框（origin 左上，CAM-011 契约）→ 磨皮/美白
    ///          经羽化蒙版（FaceMask）只作用于人脸区域，背景保持原样。
    public func apply(to image: CIImage, faces: [CGRect]? = nil) -> CIImage {
        guard !isOff else { return image }
        guard let faces, !faces.isEmpty else { return image }
        // CAM-027：蒙版来源可替换。默认（未安装注入点）= FaceMask 框级椭圆，
        // 与改造前逐位等价；安装了则用「语义 ∩ 框」。**签名与调用方零改动**。
        let mask = CameraBeautyEngine.semanticMask?(image, faces)
            ?? FaceMask.mask(forNormalizedBoxes: faces, in: image.extent)

        // CAM-033：磨皮与美白**级联合成后单次**混合（原实现各自 blended 一次 =
        // 每帧两次全帧 CIBlendWithMask）。数值等价：同一 mask 下两次嵌套线性插值
        // （mask 区=美白(磨皮图)、黑区=原图）≡ 一次（mask 区=美白(磨皮图)、
        // 黑区=原图）——混合是逐像素线性算子，嵌套可折叠。
        // CAM-035 P3 后半：**美颜子链半分辨率**（磨皮/美白是低频信息，540×960
        // 处理后上采样混回，观感无损 [E]；SPEC-CAM-033-035 §3.P3）——美型/美妆/
        // 滤镜仍全分辨率。CQ_CAM_FULLCHAIN=1 反向开关（排查观感回归用）。
        let fullChain = ProcessInfo.processInfo.environment["CQ_CAM_FULLCHAIN"] == "1"
        var work = image
        var downscaled = false
        if !fullChain, image.extent.width >= 16, image.extent.height >= 16 {
            work = work.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            downscaled = true   // scale 不平移 → origin 仍 (0,0)，磨皮引擎契约成立
        }

        var processed = work
        let segLog = ProcessInfo.processInfo.environment["CQ_CAM_BEAUTY_SEG"] == "1"
        if smoothing > 0 {
            processed = CameraBeautyEngine.smoothing?(processed, smoothing)
                ?? defaultSmoothing(processed, strength: smoothing)
            if segLog { fputs("[beauty-seg] smoothing done\n", stderr); fflush(stderr) }
        }
        if brightening > 0 {
            // CAM-035 P3 后半：**亮度曲线替代线性曝光**——CIToneCurve 五点，
            // 两端锚定（高光不动=防死白）+ 中调提亮 + 肤色饱和度微降（防塑料）。
            // 参数 [E]（真机定标归收尾批）；对强度单调（验收前提）。
            let s = CGFloat(brightening)
            var brightened = processed.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: 0.0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + 0.06 * s),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.10 * s),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.06 * s),
                "inputPoint4": CIVector(x: 1.0, y: 1.0),
            ])
            brightened = brightened.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.0 - 0.05 * s,
            ])
            processed = brightened
            if segLog { fputs("[beauty-seg] brighten done\n", stderr); fflush(stderr) }
        }
        guard processed !== work else { return image }   // 理论不可达（isOff 已挡），防御
        if downscaled {
            processed = processed.transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        }
        // 半分辨率上采样后 extent 可能比原帧大 1px（奇数帧向上取整），裁回兜底。
        let out = blended(processed, over: image, mask: mask).cropped(to: image.extent)
        if segLog { fputs("[beauty-seg] blend done\n", stderr); fflush(stderr) }
        return out
    }

    /// 蒙版混合：白（蒙版）区取处理结果、黑区取原图。mask = nil（含蒙版构造
    /// 失败的兜底）→ 全画面采用处理结果（旧行为）。
    private func blended(_ processed: CIImage, over original: CIImage, mask: CIImage?) -> CIImage {
        guard let mask else { return processed }
        return processed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: original,
            kCIInputMaskImageKey: mask,
        ])
    }

    /// 默认磨皮（A 期口径：高斯模糊 + 亮度锐化近似保边）。
    /// 引擎未注入（macOS）或引擎放弃时走这里，是兜底不是死代码。
    /// internal（非 private）：两段式参考实现的单测共用（CAM-033 合并等价用例）。
    func defaultSmoothing(_ image: CIImage, strength: Double) -> CIImage {
        // 高斯模糊（半径随强度单调）+ 轻度亮度锐化找回边缘轮廓。
        // clampedToExtent 防模糊边缘发黑，最后裁回原 extent。
        let radius = 3.0 + 9.0 * strength
        let blurred = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: radius,
            ])
            .cropped(to: image.extent)
        return blurred.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: 0.2 + 0.2 * strength,
            kCIInputRadiusKey: 4.0,
        ])
    }
}
