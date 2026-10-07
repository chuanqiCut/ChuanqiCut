// AnimalEyeAnchor — 动物观测 → 贴纸双眼锚点（CAM-024，C 期）
//
// 动物姿态（AnimalJoint 5 关节，iOS 17+ 检测门控）中的双眼 → 契约层
// StickerEyeAnchor。姿态缺失（iOS 16 设备）或双眼不全 → nil：消费方该帧
// 跳过宠物贴纸，**不**退化为框中心粘贴（诚实降级，贴纸漂移比没有贴纸更糟）。

import CoreGraphics
import Foundation

extension StickerEyeAnchor {

    init?(animal: AnimalObservation) {
        guard let pose = animal.pose,
              let left = pose[.leftEye],
              let right = pose[.rightEye] else {
            return nil
        }
        self.init(leftEye: left, rightEye: right)
    }
}
