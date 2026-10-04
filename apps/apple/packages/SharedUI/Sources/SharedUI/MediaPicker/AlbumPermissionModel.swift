// SharedUI — 自研相册浏览器：相册读权限模型（UIA-013）
//
// 与 UIA-011/012 系统 picker 的"零权限"惯例相比，自研浏览器**显式引入相册读
// 权限**（NSPhotoLibraryUsageDescription + 隐私标签申报）—— 该偏离已在
// ADR-0015 决策 3 批准。受限模式（.limited）显示常驻横幅；"管理可选照片"
// 的系统面板只有 UIKit 入口，SwiftUI 接线留后续增量（Spec §7）。
//
// 状态映射是纯函数（无 PhotoKit 环境可单测）；请求动作闭包注入（测试注入
// 固定序列，生产走 PHPhotoLibrary）。

import Foundation
import Photos

// MARK: - 状态（与 PHAuthorizationStatus 解耦，便于无相册单测）

enum AlbumAccessLevel: Equatable {
    case notDetermined
    case denied          // 拒绝 / 家长控制（restricted 同路：都进"去设置"引导）
    case authorized
    case limited         // 用户只授权了部分照片（iOS 14+；macOS 部分版本也存在）
}

/// PHAuthorizationStatus → UI 状态的纯映射。
func albumAccessLevel(from status: PHAuthorizationStatus) -> AlbumAccessLevel {
    switch status {
    case .notDetermined: return .notDetermined
    case .restricted, .denied: return .denied
    case .authorized: return .authorized
    case .limited: return .limited
    @unknown default: return .denied
    }
}

// MARK: - 权限模型

@MainActor
final class AlbumPermissionModel: ObservableObject {

    @Published private(set) var access: AlbumAccessLevel

    private let readCurrent: () -> PHAuthorizationStatus
    private let request: (@escaping (PHAuthorizationStatus) -> Void) -> Void

    /// 生产 = PhotoKit 真实现（.readWrite：自研浏览器要的是读，受限补选走
    /// 同一授权位；测试注入固定值）。
    init(readCurrent: @escaping () -> PHAuthorizationStatus = {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }, request: @escaping (@escaping (PHAuthorizationStatus) -> Void) -> Void = {
        PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: $0)
    }) {
        self.readCurrent = readCurrent
        self.request = request
        self.access = albumAccessLevel(from: readCurrent())
    }

    /// 首次进入时请求授权；其余状态原样（denied 不再重复弹，引导去设置）。
    func requestIfNeeded() async {
        guard access == .notDetermined else { return }
        let status = await withCheckedContinuation { continuation in
            request { status in continuation.resume(returning: status) }
        }
        access = albumAccessLevel(from: status)
    }

    var shouldShowGuide: Bool { access == .denied }
    var shouldShowLibrary: Bool { access == .authorized || access == .limited }
}
