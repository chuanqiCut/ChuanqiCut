// ChuanqiCutTests — 媒体时长探测验收（MEDIA-022）
//
// 背景：探测走「完整解码管线打开」（demuxer + 解码器），解码器 Open 曾只收
// H.264 —— iPhone 相册默认的 HEVC 素材 probe 必返回 2001，导入链路在第一步
// 就挂，且 UI 统一显示「解码失败」。本文件锁定两条契约：
//   1. H.264 与 HEVC golden 的 probe 都成功（时长 5s = 600000/120000）；
//   2. 详细版 API 失败时透传内核原始状态码（不再折叠成 nil）。
//
// 运行：cd bindings/swift && swift test --disable-sandbox

import XCTest
import ChuanqiCut

final class ProbeTests: XCTestCase {

    func testProbeH264GoldenSucceeds() throws {
        let session = Session()
        XCTAssertNotNil(session)
        let duration = session?.probeMediaDuration(path: TestPaths.goldenVideo)
        XCTAssertNotNil(duration, "H.264 golden probe 应成功")
        XCTAssertEqual(duration?.value, 600000)
        XCTAssertEqual(duration?.timescale, 120000)
    }

    /// 修复目标：HEVC 素材（iPhone 相册默认编码）probe 成功。
    /// 修复前此处返回 2001 kDecodeUnsupported（VideoToolboxDecoder.Open 仅收 H.264）。
    func testProbeHevcGoldenSucceeds() throws {
        let session = Session()
        XCTAssertNotNil(session)
        let duration = session?.probeMediaDuration(path: TestPaths.goldenVideoHevc)
        XCTAssertNotNil(duration, "HEVC golden probe 应成功（MEDIA-022）")
        XCTAssertEqual(duration?.value, 600000)
        XCTAssertEqual(duration?.timescale, 120000)
    }

    /// 详细版：失败透传内核原始状态码，成功路径与旧 API 语义一致。
    /// （缺失文件在 demuxer 侧报 1000 kIoError：AVAsset 加载失败 + stat 兜底。）
    func testDetailedProbePassesThroughRawStatus() throws {
        let session = try XCTUnwrap(Session())

        let ok = session.probeMediaDurationDetailed(path: TestPaths.goldenVideo)
        guard case .success(let d) = ok else {
            return XCTFail("H.264 详细探测应成功")
        }
        XCTAssertEqual(d.value, 600000)

        let missing = session.probeMediaDurationDetailed(path: "/nonexistent/no_such_file.mp4")
        guard case .failure(let status) = missing else {
            return XCTFail("不存在文件应失败")
        }
        XCTAssertEqual(status.rawValue, 1000, "缺失文件应透传 kIoError(1000)")
    }
}
