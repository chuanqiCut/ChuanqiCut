// SharedUI — MTKView 预览链路像素级验收（UIA-003）
//
// 不经 MTKView 本体验证（XCTest 无窗口宿主，drawable 机制不可靠），
// 而是拆开验证两个可独立断言的环节：
//
//   1. PreviewFrameRenderer 的恒等映射：已知源纹理 → blit → 逐字节对比，
//      抓「上下颠倒 / 通道错位」（与 PAL blit 几何同源的约定靠这里锁定）。
//   2. 真实帧上屏链路：Preview（golden 素材）→ renderFrame → blit 到
//      可读纹理 → 非黑。覆盖「内核离屏 RT → 显示路径」的完整 GPU 链路。
//
// 离屏 RT 是 MTLStorageModePrivate（gfx_metal.mm），CPU 读回必须经 blit ——
// 这与 C++ 测试的 ReadRenderTargetPixels 辅助同一原理，属测试专用路径。
//
// 运行：cd apps/apple/packages/SharedUI && swift test --disable-sandbox

import XCTest
import Metal
import ChuanqiCut
@testable import ChuanqiCutEditor

// @MainActor：PreviewFrameRenderer 是 MainActor 隔离（见其文件头）。
@MainActor
final class MetalPreviewViewTests: XCTestCase {

    private var goldenVideo: String { RepoPath.goldenVideo }

    // MARK: 工具

    private func makeTexture(_ device: any MTLDevice, format: MTLPixelFormat,
                             width: Int, height: Int) -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("测试纹理创建失败")
        }
        return tex
    }

    /// 读回纹理像素：blit 到 Shared Buffer 再读 contents —— 与 C++ 侧
    /// ReadRenderTargetPixels 同一手法。⚠️ 本机（AMD/macOS 15.4）实测
    /// MTLTexture.getBytes 读不到 GPU 写入的内容（返回全零），**不要**改回 getBytes。
    private func readBytes(_ device: any MTLDevice, _ texture: any MTLTexture) -> [UInt8] {
        let w = texture.width
        let h = texture.height
        let bytesPerRow = w * 4
        let total = bytesPerRow * h
        guard let buffer = device.makeBuffer(length: total, options: .storageModeShared),
              let cb = device.makeCommandQueue()?.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            return []
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: total)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let ptr = buffer.contents().bindMemory(to: UInt8.self, capacity: total)
        return Array(UnsafeBufferPointer(start: ptr, count: total))
    }

    // MARK: 1. 恒等映射（方向 / 通道）

    func testIdentityBlitPreservesOrientationAndChannels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return XCTFail("无 Metal 设备")
        }
        guard let renderer = PreviewFrameRenderer(device: device) else {
            return XCTFail("渲染器创建失败")
        }

        // 源：rgba8Unorm，顶行红、底行蓝（Metal 纹理第 0 行 = 呈现时的屏幕顶行）。
        let source = makeTexture(device, format: .rgba8Unorm, width: 4, height: 4)
        var srcBytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for x in 0..<4 {
            let top = (0 * 4 + x) * 4
            let bottom = (3 * 4 + x) * 4
            (srcBytes[top], srcBytes[top + 1], srcBytes[top + 2], srcBytes[top + 3]) = (255, 0, 0, 255)
            (srcBytes[bottom], srcBytes[bottom + 1], srcBytes[bottom + 2], srcBytes[bottom + 3]) = (0, 0, 255, 255)
        }
        source.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: 4, height: 4, depth: 1)),
            mipmapLevel: 0, withBytes: &srcBytes, bytesPerRow: 4 * 4)

        let destination = makeTexture(device, format: .bgra8Unorm, width: 4, height: 4)
        XCTAssertTrue(renderer.blitAndWait(source: source, to: destination),
                      "blit 命令编码与执行应成功")

        let dstBytes = readBytes(device, destination)

        // 顶行必须是红（BGRA 中 r 在第 2 字节），底行必须是蓝 ——
        // 若上下颠倒，两行互换；若通道错位，字节序不符。
        for x in 0..<4 {
            let top = (0 * 4 + x) * 4
            let bottom = (3 * 4 + x) * 4
            XCTAssertEqual(Array(dstBytes[top..<top + 4]), [0, 0, 255, 255],
                           "屏幕顶行应为红色（源顶行直传，不颠倒）")
            XCTAssertEqual(Array(dstBytes[bottom..<bottom + 4]), [255, 0, 0, 255],
                           "屏幕底行应为蓝色")
        }
    }

    // MARK: 2. 真实帧上屏链路

    func testGoldenFrameRendersThroughDisplayPath() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return XCTFail("无 Metal 设备")
        }
        guard let renderer = PreviewFrameRenderer(device: device) else {
            return XCTFail("渲染器创建失败")
        }
        guard FileManager.default.fileExists(atPath: goldenVideo) else {
            return XCTFail("golden 夹具缺失：\(goldenVideo)")
        }
        guard let session = Session() else { return XCTFail("Session 创建失败") }
        // 会话装配（UIA-009 子步骤 2：模型真源在 Session；提交异步需等生效）
        XCTAssertEqual(session.registerAsset(id: 1, path: goldenVideo), .ok)
        XCTAssertEqual(session.addTrack(kind: 0), .ok)
        let deadline = Date().addingTimeInterval(5)
        while session.currentSnapshot.version < 2 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        guard let trackId = session.queryTracks().first?.trackId else {
            return XCTFail("轨道查询为空")
        }
        let ts = RationalTime.projectTimescale
        XCTAssertEqual(session.addClip(trackId: trackId, assetId: 1,
                                       start: RationalTime(value: 0, timescale: ts),
                                       duration: RationalTime(value: 5 * Int64(ts), timescale: ts),
                                       sourceIn: RationalTime(value: 0, timescale: ts)), .ok)
        while session.currentSnapshot.version < 3 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        guard let preview = Previewer(session: session, width: 256, height: 256) else {
            return XCTFail("预览创建失败（内核预览后端缺失）")
        }
        XCTAssertEqual(preview.renderFrame(
            pts: RationalTime(value: 60000, timescale: ts)), .ok)

        // 中性句柄 → MTLTexture（与 MetalPreviewView.draw 的呈现路径同一做法）。
        let handle = try XCTUnwrap(preview.textureHandle)
        let sourceTexture = unsafeBitCast(handle, to: (any MTLTexture).self)

        let destination = makeTexture(device, format: .bgra8Unorm, width: 256, height: 256)
        XCTAssertTrue(renderer.blitAndWait(source: sourceTexture, to: destination),
                      "离屏 RT → 可读纹理的 blit 应成功")

        // 非黑断言：统计亮度超过阈值的像素（golden 是彩条类素材，
        // 不对具体颜色做脆弱断言 —— 颜色正确性由 C++ 像素用例负责）。
        let bytes = readBytes(device, destination)
        let litCount = bytes.enumerated()
            .filter { $0.offset % 4 != 3 }        // 跳过 alpha 通道
            .filter { $0.element > 16 }
            .count
        XCTAssertGreaterThan(
            Double(litCount) / Double(bytes.count / 4 * 3), 0.01,
            "显示路径的输出不应是黑屏（预览区非黑屏的像素级证据）")
    }
}
