# TASK-CAM-021：双摄提前（MultiCamSession 画中画 + 独立开关 + 录合成流）

```yaml
id:          TASK-CAM-021
layer:       UI(iOSApp)
goal:        前后同开：独立「双摄」开关（不复用翻转按钮）、画中画预览（双路均过美颜/滤镜链）、
             录制前后合成流；运行时 isMultiCamSupported 查询，不支持诚实降级单摄
input:       [SPEC-CAM-001 v1.2 目标4/A8/Q3(已拍板画中画), RESEARCH-002 §5/§C, pitfalls P38/P44,
             传哲 2026-10-05 拍板「双摄提前 + 开关独立」]
output:      [apps/apple/ios/iOSApp/Camera/CameraManager.swift,
             apps/apple/ios/iOSApp/Camera/CameraRenderer.swift,
             apps/apple/ios/iOSApp/Camera/CameraViewModel.swift,
             apps/apple/ios/iOSApp/Camera/CameraView.swift]
write_set:   apps/apple/ios/iOSApp/Camera/CameraManager.swift,
             apps/apple/ios/iOSApp/Camera/CameraRenderer.swift,
             apps/apple/ios/iOSApp/Camera/CameraViewModel.swift,
             apps/apple/ios/iOSApp/Camera/CameraView.swift
read_set:    docs/research/RESEARCH-002-相机采集与实时特效链路调研.md, .ai/modules/camera.md,
             Apple AVCaptureMultiCamSession 文档, WWDC19-249
deps:        [TASK-CAM-016(写集串行；方向修复先行), TASK-CAM-002~005]
acceptance:
  - iOS App 目标编译 0 error 0 warning（P61 口径）
  - 真机（MultiCam 支持机型，iPhone XS+ / A12+）：双摄开关开启后预览同显前后两路
    （主画面 = 背面，PiP = 正面，PiP 可与主画面互换），两路均过美颜/滤镜链（WYSIWYG）
  - 真机：双摄录制产物为单视频轨合成流，系统播放器可播，前后画面均可见
  - isMultiCamSupported == false：开关置灰 + 文案明示，不闪退（模拟器可验此分支）
  - 双摄帧率/分辨率实测（iPhone 17 Pro）入 .ai/memory/baselines.md（SPEC A8 + RESEARCH-002 §C）
verification:
  - xcodebuild -scheme ChuanqiCutApp -sdk iphonesimulator build
  - 真机人工 = SPEC-CAM-001 A8（归传哲）；帧率看 camera.preview 埋点摘要
risk:        ①MultiCamSession 配置约束严苛（停止态改配置、每 input 独立 output、总带宽上限
             ≤1080p/流 [E，待实测]）；②双路渲染帧率预算 = 单路×2，aspect-fill 渲染 pass 需跑两遍
             （或合成 pass 一次采样两纹理——实现时二选一并实测）；③录制合成流需要在录制队列
             做双帧对齐（硬件时间戳同步，若抖动则按主路帧节拍取最近从路帧，latest-wins）。
parallel:    false
```

## 背景

双摄本是 SPEC-CAM-001 §1.4 / Q3（画中画合成）的目标，原排 C 期（CAM-021~024）。
2026-10-05 传哲拍板：提前至当前执行，且**双摄开关必须是独立控件**——前后翻转按钮
永远只做单摄切换（这是本任务对交互的硬约束，源自「切前后被误解为开了双摄」的教训）。

另：2026-10-05 排查确认当前代码**没有任何双摄路径**（单 session 单 input，
`switchPosition` = removeInput+addInput），用户在真机看到的任何"前后同画"现象
都不来自双摄，本任务交付前该误解不会再发生。

## 实现要点

1. **会话层**（CameraManager）：新增双摄模式。`AVCaptureMultiCamSession`（仅 iOS，
   P38；`isMultiCamSupported` 运行时查询，红线 #3）。背面 wide + 正面 wide 双 input，
   各挂独立 `AVCaptureVideoDataOutput`（MultiCam 硬约束：每 input 至少独立 output），
   两个帧槽。开关切换 = 停会话 → 重建配置 → 启（MultiCamSession 要求停止态改配置，
   与既有 sessionQueue 纪律一致）。
2. **渲染层**（CameraRenderer）：第二帧槽 + PiP 合成——主画面 aspect-fill 全屏，
   从画面按固定比例（默认 1/4 宽，右上角圆角边框）二次采样；两路都过 `process`
   （美颜→滤镜，与单摄同序）。主/从互换 = 交换两帧槽的语义角色。
3. **录制**：录合成流（渲染到 CVPixelBufferPool，复用单摄录制形态）；双帧对齐按
   主路节拍取从路最近帧（latest-wins，不做等待）。音频轨沿用单路麦克风。
4. **UI**（CameraView）：顶部独立「双摄」Toggle（图标 + 支持性置灰）；双摄开启时
   翻转按钮语义 = 主/从画面互换；录制/拍照按钮行为不变（拍照 = 主画面单帧）。
5. **降级**：不支持机型开关置灰 + 「此机型不支持前后同开」文案；运行中查询失败
   同样走明示路径，不伪造成功（SPEC §7）。

## 验收

逐条对 acceptance；帧率/分辨率/温控实测数字回写 baselines.md 后才算 A8 关闭。

## 回写

- 双摄装配形状（会话/渲染/录制三层变化）→ `.ai/modules/camera.md`
- MultiCam 配置坑（若有）→ `.ai/memory/pitfalls.md`
- 实测数字 → `.ai/memory/baselines.md`；当日日志 → `.workbuddy/memory/`
