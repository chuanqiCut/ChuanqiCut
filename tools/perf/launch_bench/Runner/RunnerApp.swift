// RunnerApp — LaunchBench 的空壳宿主（Test Runner）。
//
// UI 测试 bundle 在 iOS 上必须运行在一个 app 进程里；本文件只是让这个
// 宿主存在，不承载任何业务。被测对象由测试代码按 bundle id 指定。

import SwiftUI

@main
struct RunnerApp: App {
    var body: some Scene {
        WindowGroup {
            Text("LaunchBench Runner")
        }
    }
}
