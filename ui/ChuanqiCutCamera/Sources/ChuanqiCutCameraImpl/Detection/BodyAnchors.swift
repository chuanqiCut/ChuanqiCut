// BodyAnchors — 人体姿态 → 美体锚点（CAM-025，C 期）
//
// BodyPoseObservation（CAM-011 19 关节）→ BodyReshapeAnchors 四关节投影。
// 任一关节缺失（低置信度 dropout / 半身入画）→ nil：该帧美体跳过，
// 不做部分形变（半身状态下的腰/腿几何不可信）。

import CoreGraphics
import Foundation

extension BodyReshapeAnchors {

    init?(body: BodyPoseObservation) {
        guard let leftShoulder = body.point(for: .leftShoulder),
              let rightShoulder = body.point(for: .rightShoulder),
              let leftHip = body.point(for: .leftHip),
              let rightHip = body.point(for: .rightHip) else {
            return nil
        }
        self.init(leftShoulder: leftShoulder, rightShoulder: rightShoulder,
                  leftHip: leftHip, rightHip: rightHip)
    }
}
