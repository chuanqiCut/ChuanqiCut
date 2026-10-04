# TASK-CAM-013：美型——人脸关键点驱动的 MeshWarp（B 期）

```yaml
id:          TASK-CAM-013
layer:       UI(iOSApp)
goal:        瘦脸/大眼/下巴收缩(基础 3 项):关键点 → 局部形变网格 → Metal 顶点/片段 warp,滑杆实时
input:       [SPEC-CAM-001 v1.1 §3 B 期, RESEARCH-002 §5(局部平移形变/TPS 方案), TASK-CAM-011 观测结构]
output:      [apps/apple/ios/iOSApp/Camera/Effects/FaceWarp.swift, Effects/face_warp.msl,
             SharedUI/Camera/CameraReshapeParams.swift(参数纯函数) + 单测]
write_set:   apps/apple/ios/iOSApp/Camera/Effects/(warp 部分), SharedUI/Camera/CameraReshapeParams.swift,
             SharedUITests(新增)
read_set:    Detection/FaceObservation.swift, CameraRenderer.swift(处理链插位)
deps:        [TASK-CAM-011]
acceptance:
  - 形变参数纯函数单测:控制点偏移随滑杆单调;无关键帧(未检测到人脸)时直通
  - 处理链顺序锁定:磨皮 → 美型 warp → 滤镜(顺序变更须改三处消费方+测试)
  - 真机:人脸跟随无明显抖动(帧间平滑生效)、无可见接缝(归传哲人工验收)
verification:
  - swift test + iOS 构建;真机耗时埋点入 baselines
risk:        Vision 76 点做精细美型精度有限(既有结论);先做 3 项对精度不敏感的效果,
             468 点模型(ADR-0005/CoreML 直转)是后续升级路径,不在本卡
parallel:    false
```

## 实现要点

- 形变算法:局部平移形变(局部圆域位移场,大眼/下巴) + 整体经纬收缩(瘦脸),在
  **归一化坐标系**生成网格顶点偏移,CPU 算参数 + GPU 顶点纹理采样 warp。
- 前摄增强(可选,同卡):ARFaceTrackingConfiguration(真深度,1220 顶点)可用时优先,
  Vision 76 点兜底;能力判定运行时(`ARFaceTrackingConfiguration.isSupported`)。
- 美型参数 UI 挂进既有美颜面板(瘦脸/大眼/下巴三滑杆),替换"禁用行"。
