// ChuanqiCut — Swift 绑定：有理数时间（BIND-003 子步骤 6 引入）
//
// 对应内核 cq::RationalTime（ADR-0006）；项目 timescale = 120000（ADR-0009）。
//
// ⚠️ 红线 #4：时间一律有理数，禁止浮点秒。本类型只持有整数，**刻意不提供**
//    浮点秒的构造 / 转换入口 —— 任何「秒」的换算都必须在上层以整数完成。

import CChuanqiCut

public struct RationalTime: Equatable, Comparable, Sendable {

    public let value: Int64
    public let timescale: Int32

    /// 项目固定 timescale（ADR-0009）。
    public static let projectTimescale: Int32 = 120000

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    /// 跨 timescale 比较：交叉相乘（现实时长量级下远离 Int64 溢出：
    /// 1 小时 @120000 = 4.3e8，乘上 timescale 仍 < 1e14）。
    public static func < (lhs: RationalTime, rhs: RationalTime) -> Bool {
        lhs.value * Int64(rhs.timescale) < rhs.value * Int64(lhs.timescale)
    }
}
