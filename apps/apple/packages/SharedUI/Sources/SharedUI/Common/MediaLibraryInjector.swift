// MediaLibraryInjector — 功能 Pod 横向解耦注入点（ADR-0031 决定 3）
//
// MediaSheet（编辑器域）需要弹出相册浏览器（UIA-013 自研相册导入流），但
// ChuanqiCutEditor Pod 不得直接依赖 ChuanqiCutImport Pod（功能 Pod 横向零依赖）。
// 壳层在启动时注入相册浏览器视图工厂；未注入（单测环境）走空占位，可观察降级不崩。
//
// 装配点：apps/apple/ios/iOSApp/ChuanqiCutApp.swift 与
//         apps/apple/mac/MacApp/ChuanqiCutMacApp.swift 的 App.init。

import SwiftUI

/// @MainActor：视图工厂只能在主线程装配与求值，同时满足 Swift 6 全局可变态隔离。
@MainActor
public enum MediaLibraryInjector {
    /// `onDeliver` = 选片完成回调（URL 列表，顺序 = 选取序号；与 AlbumPickerScreen
    /// 的 `onDeliver` 语义对齐）。返回 `AnyView`：基座不引用任何导入域类型。
    public static var makeAlbumPicker: ((_ onDeliver: @escaping ([URL]) async -> Void) -> AnyView)?
}
