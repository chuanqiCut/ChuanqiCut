# TASK-CAM-002：相机采集管理器（AVCaptureSession，iOS 原生）

```yaml
id:          TASK-CAM-002
layer:       UI(iOSApp)
goal:        CameraManager:AVCaptureSession 会话编排——前后摄切换、视频/音频帧输出、权限、生命周期
input:       [SPEC-CAM-001 v1.1, ADR-0014, pitfalls P44]
output:      [apps/apple/ios/iOSApp/Camera/CameraManager.swift]
write_set:   apps/apple/ios/iOSApp/Camera/CameraManager.swift, apps/apple/ios/project.yml(权限声明)
read_set:    .ai/modules/ui-apple.md, apps/apple/ios/iOSApp/ChuanqiCutApp.swift
deps:        []
acceptance:
  - 权限请求状态机:未授权 → 请求 → 授权/拒绝三分支可单测的纯逻辑(系统回调注入)
  - 会话配置只在停止态变更;前后切换后 position 状态正确
  - iOS 构建 -Werror(构建脚本)通过
verification:
  - cd apps/apple/ios && xcodegen generate && bundle install && bundle exec pod install && xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -sdk iphoneos18.4 CODE_SIGNING_ALLOWED=NO
  - (本机 Xcode 15.2 若 SWIFT_VERSION=6.1 不可构建,验证降级为 macOS 侧 swift build 语法检查 + 真机构建归传哲,如实记录)
risk:        本机 Xcode 15.2 与工程 Swift 6.1 的兼容性(如实记录,不悄悄改工程版本)
parallel:    false
```

## 实现要点

- `AVCaptureSession` 单摄（前后切换 = 重建 inputs，Stopped 态执行）；
  双摄留 CAM-021（`AVCaptureMultiCamSession`，**仅 iOS**，P38）。
- `AVCaptureVideoDataOutput` 32BGRA + `alwaysDiscardsLateVideoFrames`（latest-wins）；
  回调专用串行队列；音频 `AVCaptureAudioDataOutput`。
- 权限：`AVCaptureDevice.authorizationStatus` + `requestAccess`，拒绝态上抛 UI。
- App 进后台停止、回前台恢复（NotificationCenter）。
