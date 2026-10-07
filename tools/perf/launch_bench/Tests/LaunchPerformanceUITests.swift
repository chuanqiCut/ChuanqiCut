// LaunchPerformanceUITests — 「到首页」冷启动基线（cq-perf-baseline 技能产出）。
//
// 测什么：点图标 → 首页可交互，即 XCTApplicationLaunchMetric 的标准语义
// （launch 请求 → 首帧呈现，含 pre-main）。被测 app 是设备上已安装的
// com.chuanqi.cut 正式路径（HomeView，无 CQ_AUTO_ROUTE）。
//
// 取样约定（.ai/memory/baselines.md 技能）：先预热一轮再计量；每次迭代
// terminate 后 launch，保证是进程级冷启（dyld 页缓存仍是热的，属正常
// 「第二次启动」体感）。

import XCTest

final class LaunchPerformanceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testColdLaunchToHome() throws {
        try measureLaunch(bundleId: "com.chuanqi.cut")
    }

    /// 背景成本参照：极简 SwiftUI 空壳（非宿主 Runner，避免自杀）。
    /// 解释测量结果时用「ChuanqiCut − 参照」作为净成本。
    func testColdLaunchReferenceApp() throws {
        try measureLaunch(bundleId: "com.chuanqi.perf.reference")
    }

    private func measureLaunch(bundleId: String) throws {
        let app = XCUIApplication(bundleIdentifier: bundleId)

        // 预热：首轮不计入样本（系统 dyld/页面缓存从冷到热的过程不反映日常体感）。
        app.launch()
        sleep(3)
        app.terminate()

        let options = XCTMeasureOptions()
        options.iterationCount = 7
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.terminate()
            app.launch()
        }
    }
}
