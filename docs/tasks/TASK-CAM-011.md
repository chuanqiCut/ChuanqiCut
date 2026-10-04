# TASK-CAM-011：Vision 检测桥 + 帧间平滑（B 期）

```yaml
id:          TASK-CAM-011
layer:       UI(iOSApp)
goal:        Vision 系统能力桥:人脸关键点(76)/人体姿态/动物框的实时检测 + 关键点帧间平滑,输出给美型/道具/贴纸消费
input:       [SPEC-CAM-001 v1.1 §3 B 期, ADR-0014, RESEARCH-002 §4]
output:      [apps/apple/ios/iOSApp/Camera/Detection/VisionDetector.swift,
             apps/apple/ios/iOSApp/Camera/Detection/FaceObservation.swift, ctest 不可用→SharedUI 纯函数单测]
write_set:   apps/apple/ios/iOSApp/Camera/Detection/, apps/apple/packages/SharedUI/Sources/SharedUI/Camera/(平滑纯函数),
             apps/apple/packages/SharedUI/Tests/SharedUITests/(新增用例)
read_set:    .ai/modules/ui-apple.md, CameraManager.swift(帧队列节奏)
deps:        [TASK-CAM-002, TASK-CAM-003, TASK-CAM-004]
acceptance:
  - 观测结构(归一化坐标 0...1,与图像方向无关)纯函数单测:映射/平滑收敛
  - 检测降频可配置(默认 15Hz [E],真机可调);检测队列与采集/渲染队列互不阻塞
  - iOS 17+ 动物姿态用 @available 门控,低版本如实不可用(不做假能力)
  - swiftc -parse + SharedUI swift test(新 Xcode 机器)全过
verification:
  - swift test(SharedUI) + iOS 构建(命令同 CAM-002);真机检测耗时埋点入 baselines
risk:        Vision 每帧检测的 CPU/ANE 占用与预览争抢(缓解:降频+小图输入;真机实测定频)
parallel:    false
```

## 实现要点

- `VisionDetector`:对降采样帧跑 `VNDetectFaceLandmarksRequest`(76 点)+ `DetectHumanBodyPoseRequest`
  + `DetectAnimalsRequest`;结果转**中性观测结构**(归一化坐标 + yaw/pitch/roll + 置信度)。
- 帧间平滑放 SharedUI 纯函数(EMA 或 One-Euro 简化款),两端可测;参数(平滑强度)随美颜面板。
- ARKit 前摄 1220 顶点人脸网格**不在本卡**(归 CAM-013 的前摄增强);本卡输出是后摄/通用底座。
