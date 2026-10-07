# TASK-CAM-028：AR 路线——ARKit 人脸网格与跟踪升级（C 期）

```yaml
id:          TASK-CAM-028
layer:       UI(iOSApp)
goal:        前摄 AR 能力底座：ARFaceTrackingConfiguration（TrueDepth 1220 点网格 +
             实时位姿）接入检测桥；人脸跟踪从「15Hz 逐帧检测+平滑」升级为
             「检测 30Hz + 网格/位姿预测插值」，贴纸/美型/美妆锚定精度与稳定性对齐主流
input:       [传哲 2026-10-07 定则, SPEC-CAM-001 §4 扬长清单(ARKit 1220 顶点),
             RESEARCH-009 §差距2/§差距5, ADR-0014, TASK-CAM-013 卡(ARKit 可选路径)]
output:      [ChuanqiCutCameraImpl/Detection/ARFaceTracker.swift,
             消费方（贴纸锚定/warp 控制点）网格源适配]
write_set:   apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/Detection/ARFaceTracker.swift
read_set:    Detection/FaceObservation.swift(观测契约——网格映射为高精度 FaceObservation 变体),
             RESEARCH-009, Apple ARKit 文档
deps:        [TASK-CAM-011]
acceptance:
  - 运行时门控（ARFaceTrackingConfiguration.isSupported，TrueDepth 机型）；不支持走
    Vision 76 点路径（双源同契约，消费方无感）
  - 网格/位姿 60fps（ARFrame 节奏）；锚定漂移显著小于 76 点路径（真机 A/B）
  - 与采集会话共存不互抢相机（ARSession 与 AVCaptureSession 并行约束验证）
verification:  iOS 构建 + 真机 A/B 归传哲
risk:        ARSession 与 AVCaptureSession 双会话并存是主要工程风险（部分机型互斥/
             热切换开销）；美型 warp 消费 1220 点的 ROI 映射需真机标定
parallel:    false
```

## 实现要点

- ARSession 独立跑（不接管采集），只取 faceAnchor 几何 → 映射进 FaceObservation 契约
  （点位数扩展位，消费方按契约消费不关心来源）；468 点第三方模型（MediaPipe→CoreML
  直转，ADR-0005）作为后摄/无 TrueDepth 机型的补位，另立卡评估。
- 跟踪升级：Vision 检测降频跑「确认」+ ARKit/位姿每帧「预测」——丢检帧由位姿外推补锚。
