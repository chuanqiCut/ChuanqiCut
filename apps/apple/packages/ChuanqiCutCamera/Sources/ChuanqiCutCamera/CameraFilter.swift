// SharedUI — 相机滤镜预设（CAM-003）
//
// 平台无关的纯函数封装：输入 CIImage，输出滤镜后的 CIImage。放 SharedUI 是为了
// 能在 macOS 宿主上单测（ADR-0014：相机页本身 iOS 专属，但纯函数两端同构）。
//
// 选型（ADR-0014 扬长清单）：Core Image 系统滤镜自带 GPU 加速与色彩管理；
// B 期自写 Metal kernel（磨皮/美型）从同一插槽插入，调用方无感。

import CoreImage
import Foundation

/// 相机滤镜预设。`none` = 原图直通。
public enum CameraFilterPreset: String, CaseIterable, Identifiable, Sendable {

    case none
    case mono
    case chrome
    case fade
    case instant
    case noir
    case process
    case transfer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "原图"
        case .mono: return "单色"
        case .chrome: return "铬黄"
        case .fade: return "褪色"
        case .instant: return "拍立得"
        case .noir: return "黑白"
        case .process: return "冲印"
        case .transfer: return "怀旧"
        }
    }

    /// 应用滤镜。`none` 原样返回入参（调用方无需特判）。
    /// 返回 nil = 平台缺少该系统滤镜（理论不发生，诚实暴露而非伪造成功）。
    public func apply(to image: CIImage) -> CIImage? {
        let filterName: String
        switch self {
        case .none: return image
        case .mono: filterName = "CIPhotoEffectMono"
        case .chrome: filterName = "CIPhotoEffectChrome"
        case .fade: filterName = "CIPhotoEffectFade"
        case .instant: filterName = "CIPhotoEffectInstant"
        case .noir: filterName = "CIPhotoEffectNoir"
        case .process: filterName = "CIPhotoEffectProcess"
        case .transfer: filterName = "CIPhotoEffectTransfer"
        }
        guard let filter = CIFilter(name: filterName) else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }
}
