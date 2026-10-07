# TASK-CAM-024：宠物美化——动物姿态锚定贴纸（C 期）

```yaml
id:          TASK-CAM-024
layer:       UI(iOSApp)
goal:        贴纸体系扩展到宠物：CAM-011 已识别猫/狗（VNRecognizeAnimalsRequest）+
             iOS 17+ 动物头部姿态（5 关节）；无人类脸时把选中贴纸锚到宠物双眼
             （眼距定尺度/眼线定旋转，复用 StickerAnchor 数学与 StickerOverlay 合成）
input:       [SPEC-CAM-001 §3 C 期「宠物识别+美化」, SPEC §2 非目标口径（美化走贴纸锚定）,
             TASK-CAM-011(DetectionSnapshot.animals + AnimalJoint), TASK-CAM-014(贴纸体系)]
output:      [ChuanqiCutCamera/StickerAnchor.swift(StickerEyeAnchor 中性锚点 + 重载),
             ChuanqiCutCameraImpl/Detection/ReshapeAnchors+FaceObservation.swift 旁
             (动物眼锚点提取), CameraRenderer.swift/FaceBoxStore(动物眼存储),
             CameraRecorder.swift(录制同源), CameraViewModel.swift(onResult 接线)]
write_set:   apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCamera/StickerAnchor.swift,
             apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/Detection/AnimalEyeAnchor.swift,
             apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/CameraRenderer.swift,
             apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/CameraRecorder.swift,
             apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/CameraViewModel.swift
read_set:    .ai/modules/camera.md, Detection/FaceObservation.swift(AnimalJoint 契约),
             DetectionSmoothing.swift, TASK-CAM-014 卡
deps:        [TASK-CAM-014(贴纸体系), TASK-CAM-011(检测桥)]
acceptance:
  - 有脸优先锚人脸，无脸且检出宠物（有姿态）锚宠物双眼；两者都无 → 贴纸跳过（不猜位置）
  - 动物姿态缺失（iOS 16 或低置信度）→ 该帧宠物贴纸跳过（诚实降级，不退化为框中心粘贴）
  - 锚定纯函数与 014 同源单测覆盖（眼点交换序/尺度/旋转数值锁定，统一测试轮补）
  - 真机：宠物头动贴纸跟随无明显漂移（帧间平滑继承检测桥），归传哲人工验收
verification:
  - swift test（契约层 macOS）+ iOS 构建（构建机）
risk:        猫狗眼部低置信度 dropout → 平滑层保持上一帧（检测桥已处理）；双眼序（左/右）
             与镜像语义需真机对表（与人脸同约定：图像归一化 origin 左上）
parallel:    false
```

## 实现要点

- 契约层加 `StickerEyeAnchor`（leftEye/rightEye 中性结构）与 placement 重载——贴纸锚定
  数学对人脸/动物同构，零重复；StickerOverlay 加动物锚合成入口。
- 存储复用 FaceBoxStore（改注释说明其语义已扩展为「检测锚点槽」）：人/宠互斥优先级在
  消费侧（renderer/Recorder）实现，不进存储层。
- iOS 16 无动物姿态（AnimalJoint 检测 iOS 17+ 门控）：只跳过贴纸，不影响人脸路径。
- ⚠️ 编号说明：SPEC §3 原「CAM-022~024」规划四项（MetalFX/景深/宠物/美体），本卡立项
  时美体拆出单卡 TASK-CAM-025（写集/验收差异大，一卡一写集）。
