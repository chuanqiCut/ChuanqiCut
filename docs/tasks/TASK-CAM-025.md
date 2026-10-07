# TASK-CAM-025：美体起步——人体姿态驱动瘦腰/长腿（C 期）

```yaml
id:          TASK-CAM-025
layer:       UI(iOSApp)
goal:        瘦腰/长腿两项（SPEC §3 C 期「美体起步」）：人体姿态（CAM-011 BodyPoseObservation，
             19 关节含 root/髋）→ 位移场控制点 → 复用 cq_face_warp kernel（控制点场与
             人脸美型同构，零新 shader）
input:       [SPEC-CAM-001 §3 C 期, RESEARCH-002 §5(局部平移形变), TASK-CAM-011(BodyJoint 契约),
             TASK-CAM-013(FaceWarpGeometry/face_warp.metal 复用)]
output:      [ChuanqiCutCamera/BodyReshape.swift(BodyReshapeParams + BodyWarpGeometry 纯函数),
             后续轮：检测接线(FaceBoxStore 扩展) + 处理链插位 + 美体滑杆 UI]
write_set:   apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCamera/BodyReshape.swift（本轮）,
             后续轮接线 = CameraRenderer/CameraRecorder/CameraViewModel/CameraView（另行开工）
read_set:    CameraReshape.swift(FaceWarpControl 契约), FaceObservation.swift(BodyPoseObservation),
             DetectionSmoothing.swift, TASK-CAM-013 卡
deps:        [TASK-CAM-011, TASK-CAM-013(warp kernel 就绪)]
acceptance:
  - 纯函数单测：控制点位移对滑杆线性单调；off 恒等直通；关键关节缺失逐项降级（统一测试轮）
  - 单人假设（CAM-011 单主体策略）；多人 → 取置信度最高一组，不扩展
  - 真机：人体移动时形变跟随无撕裂（warp 幅度夹取生效），归传哲人工验收
verification:
  - swift test（契约层 macOS）；iOS 构建（构建机）
risk:        长腿 = 髋部区域上移（躯干压缩/下肢拉长），人体接触画面边缘时位移场被
             裁切 → 观感断层；幅度系数全 [E]，真机定案后锁数
parallel:    false
```

## 实现要点

- 数学：瘦腰 = 躯干两侧（肩中-髋中连线中段）向身体中轴水平收缩（比例收缩，同 013 颊点）；
  长腿 = 髋中点上提（dy 负）+ 半径 = 躯干宽度。控制点结构直接复用 FaceWarpControl，
  kernel 复用 face_warp.metal——C 期零新 shader。
- 关节缺失逐项降级：缺肩 → 瘦腰跳过；缺髋 → 长腿跳过（不猜）。
- 本轮先落契约纯函数层（macOS 可测）；检测接线/插位/UI 在当前批次过构建机门禁后接续
  （Camera 四件套热区不叠未验证改动）。
- ⚠️ 编号说明：美体自 SPEC 原「CAM-022~024」拆出单卡（见 TASK-CAM-024 备注）。
