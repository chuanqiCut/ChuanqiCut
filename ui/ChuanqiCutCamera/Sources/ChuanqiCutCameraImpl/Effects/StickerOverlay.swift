// StickerOverlay — 贴纸/头部道具叠加（CAM-014，ADR-0014 §3）
//
// v1 定位（诚实边界）：静态 PNG 资产 + **CI 合成**（缩放/旋转/平移仿射 +
// source-over），不做自定义 Metal —— 锚定姿态只有位置/等比缩放/平面旋转
// 三自由度（StickerPlacement），CI 仿射足够表达；不给 metallib 管线加面。
// 序列帧动效、yaw/pitch 3D 贴合、多贴纸遮挡层级归资产格式后续卡。
//
// 处理链位置 = **最后一段**（滤镜之后，道具贴在 warp 后画面上，
// TASK-CAM-014 风险栏口径）；预览 / 拍照 / 录制三路同序（WYSIWYG）。
//
// 资产来源：main bundle `stickers.json` 清单 + 同名 PNG。资产必须许可干净
// 并登记资产清单（走 cq-dependency-governance）才入 bundle —— 清单缺失 =
// 贴纸目录为空，UI 隐藏入口（不出现假功能）。

import CoreImage
import Foundation

/// 单个贴纸资产（载入期解码一次纹理，运行期只读）。
struct StickerAsset: Identifiable {
    let id: String
    let displayName: String
    /// 预解码纹理。
    let texture: CIImage
    /// 锚点垂直偏移（× 眼距，向上为正）：帽子 > 0、眼镜 ≈ 0、嘴部 < 0。
    /// 缺省用 StickerAnchor.headTopLiftRatio。
    let liftRatio: CGFloat
    /// 设计宽度：placement.scale == 1 时贴纸宽度 / 帧高 [E]（资产定稿校准）。
    let designWidthToFrameHeight: CGFloat

    /// scale=1 时的默认设计宽度（帧高的 35%）：无资产标定值时的兜底 [E]。
    static let defaultDesignWidthToFrameHeight: CGFloat = 0.35
}

/// 资产目录：bundle 清单加载。清单 schema：
/// `[{"id":"hat-cap","name":"鸭舌帽","file":"hat_cap","liftRatio":1.1,"designWidth":0.4}]`
/// （liftRatio/designWidth 可选；file 不带扩展名，按同名 .png 解析）。
enum StickerCatalog {

    struct ManifestEntry: Decodable {
        let id: String
        let name: String
        let file: String
        let liftRatio: Double?
        let designWidth: Double?
    }

    static func load(bundle: Bundle = .main) -> [StickerAsset] {
        guard let manifestURL = bundle.url(forResource: "stickers", withExtension: "json"),
              let data = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) else {
            return []
        }
        return entries.compactMap { entry in
            guard let pngURL = bundle.url(forResource: entry.file, withExtension: "png"),
                  let texture = CIImage(contentsOf: pngURL) else {
                return nil   // 清单条目与资产不一致：跳过该条，不让整目录失效
            }
            return StickerAsset(
                id: entry.id,
                displayName: entry.name,
                texture: texture,
                liftRatio: CGFloat(entry.liftRatio ?? Double(StickerAnchor.headTopLiftRatio)),
                designWidthToFrameHeight: CGFloat(
                    entry.designWidth ?? Double(StickerAsset.defaultDesignWidthToFrameHeight)))
        }
    }
}

/// 合成（纯函数式：输入图与锚点，输出叠加结果；无状态，三路可并发调用）。
enum StickerOverlay {

    /// 把贴纸按锚定姿态合成到画面。锚点缺失（无眼点）→ 原样返回（不猜位置）。
    ///
    /// 姿态映射：placement.scale 以帧高为像素基准（与 warp 半径同基准）；
    /// rotationRadians 为屏幕顺时针（y 向下口径），CI 工作空间 y 向上
    /// —— 取负号补偿（与 ciWritesBottomUp 同族的「真机一验再定案」常数）。
    static func composite(_ asset: StickerAsset, over image: CIImage,
                          anchors: CameraReshapeAnchors) -> CIImage {
        guard let placement = StickerAnchor.placement(
            eyeLeft: anchors.leftEyeCenter,
            eyeRight: anchors.rightEyeCenter,
            roll: anchors.roll,
            liftRatio: asset.liftRatio) else { return image }
        return compositing(asset, placement: placement, over: image)
    }

    /// 动物锚合成（CAM-024）：宠物姿态双眼 → 同一锚定数学（有脸优先人脸路径，
    /// 由消费侧选择入口；本文件不做优先级判断）。
    static func composite(_ asset: StickerAsset, over image: CIImage,
                          eyeAnchor: StickerEyeAnchor) -> CIImage {
        guard let placement = StickerAnchor.placement(
            eyeAnchor: eyeAnchor,
            liftRatio: asset.liftRatio) else { return image }
        return compositing(asset, placement: placement, over: image)
    }

    /// 共用变换体：placement → 仿射 → 叠加。单一实现，两个入口零重复。
    private static func compositing(_ asset: StickerAsset, placement: StickerPlacement,
                                    over image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }

        let targetWidth = asset.designWidthToFrameHeight * extent.height * placement.scale
        let textureExtent = asset.texture.extent
        guard textureExtent.width >= 1 else { return image }
        let scale = targetWidth / textureExtent.width

        // 归一化 origin 左上 → CI 像素 origin 左下
        let center = CGPoint(x: placement.center.x * extent.width,
                             y: (1 - placement.center.y) * extent.height)

        // 平移(中心) × 旋转 × 缩放 × 平移(-纹理中心)：绕纹理中心变换后定位。
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
        transform = transform.rotated(by: -placement.rotationRadians)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: -textureExtent.midX, y: -textureExtent.midY)

        return asset.texture.transformed(by: transform).composited(over: image)
    }
}
