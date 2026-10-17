// PlayerPreviewInjector — 功能 Pod 横向解耦注入点（ADR-0031 决定 3）
//
// MediaSheet（UIA-026 播放器联动）需要弹出播放器，但编辑器域不得直接依赖
// ChuanqiCutPlayer Pod（功能 Pod 横向零依赖）。壳层在启动时把 PlayerScreen
// 工厂注入本注入器；单测等未注入环境走空占位，可观察降级不崩。
//
// 装配点（各壳 App.init）：
//   apps/apple/ios/iOSApp/ChuanqiCutApp.swift
//   apps/apple/mac/MacApp/ChuanqiCutMacApp.swift

import SwiftUI

/// @MainActor：视图工厂只能在主线程装配与求值（App.init / sheet 内容构建都是
/// MainActor），也顺带满足 Swift 6 对全局可变状态的隔离要求（P49 同款教训）。
@MainActor
public enum PlayerPreviewInjector {
    /// `urls.count == 1` 时给单条预览，否则批量连播（与 PlayerScreen 双 init 语义对齐）。
    /// 返回 `AnyView`：基座不引用任何播放器类型，依赖方向保持 Player → 基座单向。
    public static var makePlayerPreview: ((_ urls: [URL]) -> AnyView)?
}
