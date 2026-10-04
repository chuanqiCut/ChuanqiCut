# TASK-CAM-014：贴纸 + 头部道具锚定（B 期）

```yaml
id:          TASK-CAM-014
layer:       UI(iOSApp)
goal:        贴纸/头部道具:人脸锚定(位置/尺度/旋转随头动)+ 纹理叠加 pass + 贴纸选择 UI
input:       [SPEC-CAM-001 v1.1 §3 B 期, TASK-CAM-011 观测结构, EDIT-005(资源格式参照)]
output:      [apps/apple/ios/iOSApp/Camera/Effects/StickerOverlay.swift, Effects/sticker.msl,
             SharedUI/Camera/StickerAnchor.swift(锚定纯函数) + 单测, 贴纸资产清单]
write_set:   apps/apple/ios/iOSApp/Camera/Effects/(贴纸部分), SharedUI/Camera/StickerAnchor.swift,
             SharedUITests(新增), apps/apple/ios/iOSApp/Resources/Stickers/(资产)
read_set:    Detection/FaceObservation.swift, CameraRenderer.swift(叠加层插位)
deps:        [TASK-CAM-011]
acceptance:
  - 锚定纯函数单测:给定关键点集输出贴纸位置/尺度/旋转(双眼连线定朝向),数值锁定
  - 道具随头动无持续漂移(平滑生效);多贴纸互不遮挡人脸(层级规则)
  - 资产许可干净(自产/CC0),登记进资产清单(走 cq-dependency-governance)
  - 录制/拍照含贴纸(WYSIWYG 三路口径与美颜一致)
verification:
  - swift test + iOS 构建;真机锚定稳定性归传哲人工验收
risk:        贴纸资源设计与美型滑杆的叠加次序(道具应贴在 warp 后的画面上——处理链最后一段)
parallel:    false
```

## 实现要点

- 锚定模型:双眼中心=位置、双眼间距=尺度、眼线角度+yaw/pitch/roll=旋转;
  平滑复用 CAM-011 的帧间平滑。
- 渲染:纹理 quad 叠加 pass(处理链最后一环,美型 warp 之后),静态 PNG 起步;
  序列帧/APNG 动效在资产格式里预留。
- UI:美颜面板同级的"贴纸"入口(横滑选择条,与滤镜条同款式)。
