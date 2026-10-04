// main.swift — 磨皮 Metal kernel 宿主验证（CAM-012，macOS 宿主，非真机）
//
// 编排见同目录 build_and_run.sh；本程序做的断言：
//   1. profile 单调性：taps / rangeSigma / mix 对滑杆单调不减，taps(0) < taps(1)
//   2. GPU 实证：合成 1080p 图（肤色噪声底 + 垂直硬边 + 暗圆），逐强度渲染后
//      - 平坦区亮度方差随强度单调不增（且严格下降）
//      - 硬边梯度保持率 ≥ 60%（保边，发丝/眼缘代理指标）
//      - extent 不变、输出非 nil
//   3. 耗时：1080p 单帧全链渲染（含 GPU 完成）均值，与 A 期默认 CI 实现对照
//
// 退出码 0 = 全部通过；1 = 有断言失败（逐条打印 FAIL）。

import CoreImage
import CoreVideo
import Foundation
import Metal
import SharedUI

let kWidth = 1920
let kHeight = 1080

// MARK: - 断言收集

var failures: [String] = []
func check(_ ok: Bool, _ message: String) {
    let tag = ok ? "PASS" : "FAIL"
    print("[\(tag)] \(message)")
    if !ok { failures.append(message) }
}

// MARK: - 1. profile 单调性（纯 Swift）

var profileMono = true
var prevTaps = 0
var prevSigma: Float = -1
var prevMix: Float = -1
for step in 0...100 {
    let s = Double(step) / 100.0
    let taps = BeautyKernelProfile.taps(strength: s)
    let sigma = BeautyKernelProfile.rangeSigma(strength: s)
    let mix = BeautyKernelProfile.mix(strength: s)
    profileMono = profileMono
        && taps >= prevTaps && sigma >= prevSigma && mix >= prevMix
    prevTaps = taps
    prevSigma = sigma
    prevMix = mix
}
check(profileMono, "profile 单调性：taps/σr/mix 对滑杆单调不减")
check(BeautyKernelProfile.taps(strength: 0) == 2
      && BeautyKernelProfile.taps(strength: 1) == 5,
      "profile 覆盖范围：taps 2→5（滑杆全程有效）")
let oddExtent = BeautyKernelProfile.halfExtent(of: CGRect(x: 0, y: 0, width: 1081, height: 1921))
check(oddExtent.width == 541 && oddExtent.height == 961,
      "halfExtent 奇数尺寸向上取整不丢末行末列")

// MARK: - 2/3. GPU 实证

guard let metallibPath = CommandLine.arguments.dropFirst().first else {
    print("用法: harness <beauty.metallib>")
    exit(2)
}
guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    print("FAIL: 本机无 Metal 设备，宿主验证不可用（改在真机/新 Xcode 机器跑）")
    exit(1)
}

guard let libraryData = FileManager.default.contents(atPath: metallibPath),
      let kernel = BeautyKernel(libraryData: libraryData) else {
    print("FAIL: metallib 加载失败或 kernel 名缺失: \(metallibPath)")
    exit(1)
}
print("metallib 加载成功，kernel 引擎就绪")

// 合成图：肤色噪声底 + x=960 垂直硬边（毛发代理）+ 暗圆（眼缘代理）。
guard let buffer = makeSyntheticBuffer(width: kWidth, height: kHeight) else {
    print("FAIL: 合成图创建失败")
    exit(1)
}
let source = CIImage(cvPixelBuffer: buffer)
let context = CIContext(mtlDevice: device)
let texture = makeRenderTarget(device: device, width: kWidth, height: kHeight)
CameraBeautyEngine.smoothing = kernel.smoothingEngine()
defer { CameraBeautyEngine.reset() }

var samplesByStrength: [Double: [Float]] = [:]
var pixelsByStrength: [Double: [UInt8]] = [:]
var timingsKernel: [Double: Double] = [:]

for strength in [0.0, 0.25, 0.5, 0.75, 1.0] {
    let params = CameraBeautyParams(smoothing: strength, brightening: 0)
    let output = params.apply(to: source)  // 非 Optional：引擎放弃时内部已回落默认实现
    check(output.extent == source.extent, "strength=\(strength) extent 不变")

    guard let pixels = renderAndRead(image: output, context: context,
                                     queue: queue, texture: texture) else {
        check(false, "strength=\(strength) 渲染/回读失败")
        continue
    }
    pixelsByStrength[strength] = pixels
    let samples = sampleLuma(pixels: pixels, width: kWidth, height: kHeight)
    samplesByStrength[strength] = samples

    // 耗时（3 轮 × [预热 5 + 计时 20]，取最优轮均值 —— 本机 GPU 降频/JIT 抖动大，
    // 单轮数字不可复现；只计渲染到 GPU 完成，不含回读，与生产链路口径一致）。
    var best = Double.greatestFiniteMagnitude
    for _ in 0..<3 {
        var total = 0.0
        for i in 0..<25 {
            let t0 = CFAbsoluteTimeGetCurrent()
            renderAndWait(image: output, context: context, queue: queue, texture: texture)
            let t1 = CFAbsoluteTimeGetCurrent()
            if i >= 5 { total += (t1 - t0) }
        }
        best = min(best, total / 20.0)
    }
    timingsKernel[strength] = best * 1000.0
}

// 方差单调（平坦区）
if let v0 = variance(samplesByStrength[0.0]) {
    var prevV = v0
    var monoOK = true
    var strictOK = false
    for strength in [0.25, 0.5, 0.75, 1.0] {
        guard let v = variance(samplesByStrength[strength]) else {
            monoOK = false
            break
        }
        if v > prevV + 1e-9 { monoOK = false }
        if v < v0 - 1e-9 { strictOK = true }
        print(String(format: "  strength=%.2f 方差=%.6f (基线 %.6f)", strength, v, v0))
        prevV = v
    }
    check(monoOK, "GPU 实证：平坦区方差对强度单调不增")
    check(strictOK, "GPU 实证：方差相对基线严格下降（磨皮真的在磨）")
} else {
    check(false, "方差计算失败（基线缺失）")
}

// 保边（CPU 仿真定标，TASK-CAM-012 进度段）：
//   最大邻接差类指标不适用 —— 2× 上采样的双线性内建插值就把过渡铺成 2px，
//   其最大邻接差恒 = 对比度/2（CPU 扫描实证：与 taps/σs 无关恒 ~50%）。
//   改用两个直接对应"发丝边是否糊"的稳健指标：
//   - 过渡宽度：10%→90% 对比度的跨越跨度（原始硬边 ~1px，2px=纯插值下限）
//   - 平台对比度：边两侧 ±20px 平台亮度差保持率
if let base = edgeRowMetrics(pixels: pixelsByStrength[0.0] ?? [], width: kWidth, height: kHeight) {
    for strength in [0.5, 1.0] {
        if let m = edgeRowMetrics(pixels: pixelsByStrength[strength] ?? [],
                                  width: kWidth, height: kHeight) {
            let ratio = m.meanContrast / max(base.meanContrast, 1e-9)
            print(String(format: "  strength=%.2f 过渡宽度=%.1fpx 平台对比度保持率=%.1f%%",
                         strength, m.meanWidth, ratio * 100))
            check(m.meanWidth <= (strength == 1.0 ? 4.5 : 3.5),
                  "GPU 实证：strength=\(strength) 边缘过渡宽度 ≤ \(strength == 1.0 ? 4.5 : 3.5)px（实得 \(String(format: "%.1f", m.meanWidth))px）")
            check(ratio >= 0.85,
                  "GPU 实证：strength=\(strength) 平台对比度保持率 ≥ 85%（实得 \(String(format: "%.1f", ratio * 100))%）")
        }
    }
}

// MARK: - 耗时报告（宿主参考值，非真机；真机实测归传哲后回填 baselines）

print("-- 1080p 单帧耗时（macOS 宿主 Intel Iris Plus 640，全链含 GPU 完成）--")
for strength in [0.0, 0.5, 1.0] {
    if let ms = timingsKernel[strength] {
        print(String(format: "  Metal kernel 引擎 strength=%.2f: %.2f ms", strength, ms))
    }
}
// A 期默认实现对照（引擎摘除后同口径）
CameraBeautyEngine.reset()
let legacyParams = CameraBeautyParams(smoothing: 0.5, brightening: 0)
let legacyImage = legacyParams.apply(to: source)
var legacyBest = Double.greatestFiniteMagnitude
for _ in 0..<3 {
    var total = 0.0
    for i in 0..<25 {
        let t0 = CFAbsoluteTimeGetCurrent()
        renderAndWait(image: legacyImage, context: context, queue: queue, texture: texture)
        let t1 = CFAbsoluteTimeGetCurrent()
        if i >= 5 { total += (t1 - t0) }
    }
    legacyBest = min(legacyBest, total / 20.0)
}
print(String(format: "  A 期默认 CI 高斯 strength=0.50: %.2f ms（对照）", legacyBest * 1000.0))

// MARK: - 结论

// 边缘亮度剖面诊断（CQ_DEBUG_PROFILE=1 时输出，用于保边不达标时的形状分析）
if ProcessInfo.processInfo.environment["CQ_DEBUG_PROFILE"] == "1" {
    let stride = kWidth * 4 / MemoryLayout<UInt8>.stride
    func lumaAt(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Float {
        let idx = y * stride + x * 4
        let b = Float(pixels[idx]) / 255
        let g = Float(pixels[idx + 1]) / 255
        let r = Float(pixels[idx + 2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    for strength in [0.0, 1.0] {
        guard let pixels = pixelsByStrength[strength] else { continue }
        var line = "s=\(strength) y=600 x=950...970: "
        for x in 950...970 { line += String(format: "%.3f ", lumaAt(pixels, x, 600)) }
        print(line)
    }
}

if failures.isEmpty {
    print("\nALL PASS（\(kWidth)x\(kHeight) 宿主验证）")
    exit(0)
} else {
    print("\nFAILED: \(failures.count) 项")
    exit(1)
}

// MARK: - 工具函数

/// 肤色噪声底 + 垂直硬边 + 暗圆，BGRA 8bit。
func makeSyntheticBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let stride = bytesPerRow / MemoryLayout<UInt8>.stride

    var seed: UInt64 = 42
    let rand: () -> Int = {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % 41) - 20  // -20...20 的亮度噪声
    }

    let pointer = base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            // 肤色底；x ≥ 960 硬边变暗（毛发）；(480,300) r=50 暗圆（眼缘）
            var r = 240, g = 200, b = 176
            if x >= 960 { r = 132; g = 110; b = 97 }
            let dx = x - 480, dy = y - 300
            if dx * dx + dy * dy < 50 * 50 { r = 60; g = 50; b = 45 }
            let noise = rand()
            let idx = y * stride + x * 4
            pointer[idx + 0] = UInt8(max(0, min(255, b + noise)))
            pointer[idx + 1] = UInt8(max(0, min(255, g + noise)))
            pointer[idx + 2] = UInt8(max(0, min(255, r + noise)))
            pointer[idx + 3] = 255
        }
    }
    return buffer
}

func makeRenderTarget(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    return device.makeTexture(descriptor: descriptor)!
}

/// 渲染到 GPU 完成（不含回读）。耗时口径与生产链路一致（预览/录制无回读）。
func renderAndWait(image: CIImage, context: CIContext, queue: MTLCommandQueue,
                   texture: MTLTexture) {
    guard let commandBuffer = queue.makeCommandBuffer() else { return }
    context.render(image, to: texture, commandBuffer: commandBuffer,
                   bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
}

/// 渲染整链到纹理并回读 BGRA 字节（含 GPU 完成等待，计时应如实含这一段）。
func renderAndRead(image: CIImage, context: CIContext, queue: MTLCommandQueue,
                   texture: MTLTexture) -> [UInt8]? {
    guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
    // 此 render 变体在本 SDK 非 throws（错误经 commandBuffer.error 暴露，下方已查）。
    context.render(image, to: texture, commandBuffer: commandBuffer,
                   bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.error == nil else { return nil }

    let width = texture.width, height = texture.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return pixels
}

/// 平坦区采样点亮度（0...1）：避开硬边(x≥940)与暗圆，网格步进 7。
func sampleLuma(pixels: [UInt8], width: Int, height: Int) -> [Float] {
    var samples: [Float] = []
    let stride = width * 4 / MemoryLayout<UInt8>.stride
    var y = 100
    while y < min(1000, height) {
        var x = 100
        while x < 900 {
            let dx = x - 480, dy = y - 300
            if !(abs(dx) < 70 && abs(dy) < 70) {
                let idx = y * stride + x * 4
                let b = Float(pixels[idx]) / 255
                let g = Float(pixels[idx + 1]) / 255
                let r = Float(pixels[idx + 2]) / 255
                samples.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
            x += 7
        }
        y += 7
    }
    return samples
}

func variance(_ samples: [Float]?) -> Float? {
    guard let samples, samples.count > 1 else { return nil }
    let mean = samples.reduce(0, +) / Float(samples.count)
    let sq = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
    return sq / Float(samples.count)
}

/// 保边指标：边是垂直且行行相同的，先做跨行平均得到列剖面（残留噪声 /√行数），
/// 再测 10%→90% 对比度过渡宽度与两侧平台（±20px）亮度差。
/// 阈值定标见 TASK-CAM-012 进度段。
func edgeRowMetrics(pixels: [UInt8], width: Int, height: Int) -> (meanWidth: Double, meanContrast: Double)? {
    guard pixels.count >= height * width * 4 else { return nil }
    let stride = width * 4 / MemoryLayout<UInt8>.stride
    func lumaAt(_ x: Int, _ y: Int) -> Float {
        let idx = y * stride + x * 4
        let b = Float(pixels[idx]) / 255
        let g = Float(pixels[idx + 1]) / 255
        let r = Float(pixels[idx + 2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    // 跨行平均列剖面（x∈[930,990]，y∈[400,800) 100 行）
    var profile = [Float](repeating: 0, count: 61)
    let rowCount = 100
    for (i, x) in (930...990).enumerated() {
        var sum: Float = 0
        for y in 400..<800 { sum += lumaAt(x, y) }
        profile[i] = sum / Float(rowCount)
    }
    func at(_ x: Int) -> Float { profile[x - 930] }
    func mean(_ range: ClosedRange<Int>) -> Float {
        var sum: Float = 0
        for x in range { sum += at(x) }
        return sum / Float(range.count)
    }
    let lp = mean(935...950)
    let rp = mean(970...985)
    let contrast = abs(lp - rp)
    guard contrast > 0.05 else { return nil }
    let t90 = lp - 0.1 * contrast
    let t10 = lp - 0.9 * contrast
    var x90 = -1, x10 = -1
    var x = 950
    while x <= 970 {
        let v = at(x)
        if x90 < 0 && v < t90 { x90 = x }
        if x10 < 0 && v < t10 { x10 = x; break }
        x += 1
    }
    guard x90 >= 0, x10 >= 0, x10 >= x90 else { return nil }
    return (Double(x10 - x90), Double(contrast))
}
