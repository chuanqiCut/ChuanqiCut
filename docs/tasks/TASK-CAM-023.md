# TASK-CAM-023：景深人像（C 期）

```yaml
id:          TASK-CAM-023
layer:       UI(iOSApp)
goal:        拍照人像虚化：AVCaptureDepthDataOutput 采集深度 → 拍照帧关联 AVDepthData →
             背景按深度羽化虚化（f 值可调），处理链插位 = 滤镜之后（与贴纸同段协商）
input:       [SPEC-CAM-001 §3 C 期, RESEARCH-002 §C(AVDepthData 扬长清单), ADR-0014]
output:      [ChuanqiCutCameraImpl/CameraManager.swift(DepthDataOutput + 深度关联),
             ChuanqiCutCameraImpl/Effects/PortraitBlur.swift(CI 虚化蒙版),
             设置面板「人像虚化」开关 + f 值滑杆]
write_set:   apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/CameraManager.swift,
             apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/Effects/PortraitBlur.swift
read_set:    .ai/modules/camera.md, Apple AVDepthData/CaptureDepthDataDelivery 文档,
             CameraBeauty.swift(蒙版混合惯例), TASK-CAM-019(区域化蒙版同族)
deps:        [构建机门禁（CameraManager 同一写集，本轮批次先过编译）]
acceptance:
  - 仅双摄/广角+深度数据可用机型生效；无深度如实降级（开关置灰/虚化跳过），不伪造
  - 真机：人像背景虚化自然、发际无硬边（羽化生效）；f 值滑杆单调
  - 拍照路径与预览不冲突（深度仅服务拍照，预览虚化归后续轮）
verification:
  - iOS BUILD（构建机）；真机人工归传哲
risk:        DepthDataOutput 与 video/photo 输出的帧同步（syncedCaptureConnection）是
             主要复杂度；竖屏 depth map 方向与帧方向的配准需真机校验
parallel:    false
```

## 实现要点

- 会话加 AVCaptureDepthDataOutput + `photoOutput.connection(with: .video)` 与 depth
  connection 做 `synchronizedCaptureConnection`（拍录并发的同步语义）。
- 深度虚化用 CI：depth → 归一化蒙版（近景保留/远景虚化，CIRadialGradient 不适用，
  按 depth 线性分档 + CIGaussianBlur 混合），复用 CAM-019 的 blended 蒙版惯例。
- f 值滑杆映射虚化半径与过渡带宽度（纯函数，进统一测试轮锁定数值）。
