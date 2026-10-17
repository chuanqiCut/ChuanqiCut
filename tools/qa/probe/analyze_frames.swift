// 磨皮输出帧间稳定性分析（CAM-033）：
// 逐帧抽脸中心区域 → 灰度 → 3×3 拉普拉斯绝对值均值（高频能量=纹理清晰度代理）。
// 磨皮强度脉动 → 高频能量帧间高频振荡；AE/手持运动 → 低频缓变。
// 用法：swift analyze_frames.swift <video.mp4>

import AVFoundation
import CoreImage
import Foundation

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
let asset = AVAsset(url: url)
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero

let duration = CMTimeGetSeconds(asset.duration)
let fps = 30.0
var frame = 0
var results: [(Double, Double, Double)] = []   // (t, lapMean, meanLuma)
let ciContext = CIContext(options: [.useSoftwareRenderer: true])

while true {
    let t = CMTime(seconds: Double(frame) / fps, preferredTimescale: 600)
    guard let buf = try? gen.copyCGImage(at: t, actualTime: nil) else { break }
    let ci = CIImage(cgImage: buf)
    let extent = ci.extent
    // 脸中心区域：画面中部（探针持机人脸大致居中），取 40%×30% 窗口
    let w = extent.width * 0.4, h = extent.height * 0.3
    let roi = CGRect(x: extent.midX - w/2, y: extent.midY - h/2, width: w, height: h)
    guard let cg = ciContext.createCGImage(ci, from: roi) else { break }
    let width = cg.width, height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = CGContext(data: &pixels, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    // 灰度
    var gray = [Double](repeating: 0, count: width * height)
    var lumaSum = 0.0
    for i in 0..<(width * height) {
        let g = 0.299 * Double(pixels[i*4]) + 0.587 * Double(pixels[i*4+1]) + 0.114 * Double(pixels[i*4+2])
        gray[i] = g
        lumaSum += g
    }
    // 3×3 拉普拉斯绝对值均值（跳过边界）
    var lapSum = 0.0, lapCount = 0
    for y in 1..<(height-1) {
        for x in 1..<(width-1) {
            let i = y * width + x
            let lap = abs(4*gray[i] - gray[i-1] - gray[i+1] - gray[i-width] - gray[i+width])
            lapSum += lap
            lapCount += 1
        }
    }
    results.append((Double(frame)/fps, lapSum / Double(lapCount), lumaSum / Double(lapCount)))
    frame += 1
    if Double(frame) / fps > duration { break }
}

print("frames=\(results.count)")
print("t,lapMean,lumaMean")
for (t, lap, luma) in results {
    print(String(format: "%.3f,%.2f,%.1f", t, lap, luma))
}
