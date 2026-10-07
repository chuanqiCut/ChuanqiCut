// SharedUI — 跨 Apple 平台的图像类型桥（MediaPicker 内部用）
//
// 这是 UI 管道层的类型统一（Photos 框架在两端分别交付 UIImage / NSImage），
// 不是能力推断 —— 红线 #3 约束的是"用编译期平台宏推断**能力可用性**"，
// 能力可用性一律走 cq_query_capability / PhotoKit 运行时返回值。

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif
