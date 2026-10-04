# TASK-CAM-012：美颜升级——Metal 磨皮替换高斯近似（B 期）

```yaml
id:          TASK-CAM-012
layer:       UI(iOSApp)
goal:        磨皮从 A 期"高斯+锐化近似"升级为保边正经算法(Metal kernel:引导滤波或双边滤波),滑杆接口不变
input:       [SPEC-CAM-001 v1.1 §3 B 期, RESEARCH-002 §5, CameraBeauty.swift(既有接口)]
output:      [apps/apple/ios/iOSApp/Camera/Effects/BeautyKernel.swift, Effects/*.metal(编译期内嵌 MSL),
             SharedUI CameraBeauty.apply 改为薄封装(算法参数由原生侧注入)]
write_set:   apps/apple/ios/iOSApp/Camera/Effects/, SharedUI/Camera/CameraBeauty.swift(仅封装层),
             SharedUITests(用例适配)
read_set:    CameraRenderer.swift, CameraRecorder.swift
deps:        [TASK-CAM-003]
acceptance:
  - 磨皮输出对滑杆单调、off 恒等直通(既有单测口径不变,算法实现可替换)
  - 1080p 单帧磨皮 ≤ 8ms [E,真机实测后回填 baselines];不掉帧(≥30fps 维持)
  - 肤色区域平滑、发丝/眼缘/唇线保边(真机人工验收项,归传哲)
verification:
  - swift test + iOS 构建;真机帧率/耗时埋点入 baselines
risk:        引导滤波需要 downsample 金字塔,复杂度高于双边;先双边后引导,以真机帧率定案
parallel:    false
```

## 实现要点

- Metal fragment kernel 双 pass:下采样 → 域变换模糊(亮度域双边)→ 上采样 → 与原图按强度混合;
  混合强度 = 磨皮滑杆。MSL 直接写在 `Effects/` 目录(App 层资产,ADR-0014 §3 红线 #6 边界)。
- `CameraBeauty.apply` 的公开语义(单调/off 恒等)**不变**,调用方(预览/拍照/录制)零改动;
  原生侧在 process 链中用 kernel 版本替换纯 CI 版本。
