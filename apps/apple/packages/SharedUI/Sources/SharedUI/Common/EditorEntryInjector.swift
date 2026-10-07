// EditorEntryInjector — 功能 Pod 横向解耦注入点（ADR-0031 决定 3）
//
// 相机域录制完成后需进入编辑器（CameraView → EditorScreen，CAM-005 起的链路），
// 但 ChuanqiCutCamera Pod 不得直接依赖编辑器域（功能 Pod 横向零依赖；编辑器
// 阶段 5 还会迁出基座独立成 Pod，届时本注入点语义不变）。壳层在启动时注入
// EditorScreen 工厂；未注入（单测环境）时消费侧走空占位，可观察降级不崩。
//
// 装配点：apps/apple/ios/iOSApp/ChuanqiCutApp.swift 的 App.init（mac 无相机域）。

import SwiftUI

/// @MainActor：视图工厂只能在主线程装配与求值，同时满足 Swift 6 全局可变态隔离。
@MainActor
public enum EditorEntryInjector {
    /// `initialMediaURL` = 录制产物等初始素材（可为 nil = 空编辑器）。
    /// 返回 `AnyView`：基座不引用任何相机/编辑器域类型，依赖方向保持单向。
    public static var makeEditor: ((_ initialMediaURL: URL?) -> AnyView)?
}
