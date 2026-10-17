// SharedUI — 播放器捏合缩放的纯几何（UIA-017）
//
// 为什么单独成文件：缩放是「手势 → 画面变换」里唯一可被单测覆盖的部分，
// 而且调用方有两侧（VM 状态机 + 控制层双击/松手），抽成无状态纯函数后
// VM 不持有视图几何、视图不持有阈值常量。
//
// ⚠️ 这个文件在 `cc7267a`（UIA-024/017 进阶版 Batch B）里只写进了提交信息，
// 实现从未入库 —— 结果 SharedUI 整包在 macOS / iOS 上都编译不过，而那一轮用
// `swiftc -parse` 验收（只查语法），把缺失类型漏了过去（见 pitfalls P78）。
// 常量取值以下面三个行为的既有测试为准（Tests/SharedUITests/PlayerTests.swift
// 「缩放几何」三例），改动必须与那三例同步。
//
// 几何口径：画面按 scale 放大后仍以容器中心对齐，故单轴可拖移的最大距离 =
// 半幅 × (scale - 1)：1x 时必为 0（不可拖移），3x 时等于容器该轴长度。

import CoreGraphics
import Foundation

enum PlayerZoomMath {

    /// 最小档位。低于此值无意义（画面小于容器），1x 也是「未缩放」判定值。
    static let minScale: CGFloat = 1.0
    /// 最大档位。再大收益递减而拖移边界急剧膨胀。
    static let maxScale: CGFloat = 3.0
    /// 松手回弹阈值：低于它回落到 1x，避免出现「放了一点点」的悬挂态。
    static let settleThreshold: CGFloat = 1.15

    /// 钳制到 [minScale, maxScale]。
    static func clampScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isNaN == false else { return minScale }
        return min(maxScale, max(minScale, scale))
    }

    /// 松手后的落档：低于回弹阈值 → 1x，否则仍要过一遍上界钳制（手势可能给到 5x）。
    static func settledScale(_ scale: CGFloat) -> CGFloat {
        let clamped = clampScale(scale)
        return clamped < settleThreshold ? minScale : clamped
    }

    /// 某档位下单轴可拖移的最大距离（CGSize 表示 x/y 两轴）。
    /// 1x 及以下恒为零 —— 「不可拖移」是这里保证的，调用方不要再额外判等。
    static func maxOffset(for scale: CGFloat, containerSize: CGSize) -> CGSize {
        guard scale > minScale, containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        let factor = (clampScale(scale) - 1.0) / 2.0
        return CGSize(width: containerSize.width * factor, height: containerSize.height * factor)
    }

    /// 把拖移量钳制在当前档位的画面边界内（每轴独立）。
    static func clampOffset(_ offset: CGSize, scale: CGFloat, containerSize: CGSize) -> CGSize {
        let limit = maxOffset(for: scale, containerSize: containerSize)
        guard limit != .zero else { return .zero }
        return CGSize(width: clamp(offset.width, to: limit.width),
                      height: clamp(offset.height, to: limit.height))
    }

    private static func clamp(_ value: CGFloat, to limit: CGFloat) -> CGFloat {
        min(max(value, -limit), limit)
    }
}
