# TASK-CAM-016：相机预览方向修复（颠倒 + 横竖屏跟踪 + aspect-fill）

```yaml
id:          TASK-CAM-016
layer:       UI(iOSApp)
goal:        预览不再上下颠倒；界面方向（竖/左横/右横）被采集与渲染全程正确跟随；画面 aspect-fill 铺满
input:       [SPEC-CAM-001 v1.2 目标5/A7, 传哲 2026-10-05 拍板「横竖屏都要支持」, TASK-CAM-015 渲染链现状, pitfalls P60/P61]
output:      [apps/apple/ios/iOSApp/Camera/CameraManager.swift,
             apps/apple/ios/iOSApp/Camera/CameraRenderer.swift,
             apps/apple/ios/iOSApp/Camera/CameraViewModel.swift,
             apps/apple/ios/iOSApp/Camera/CameraView.swift]
write_set:   apps/apple/ios/iOSApp/Camera/CameraManager.swift,
             apps/apple/ios/iOSApp/Camera/CameraRenderer.swift,
             apps/apple/ios/iOSApp/Camera/CameraViewModel.swift,
             apps/apple/ios/iOSApp/Camera/CameraView.swift
read_set:    apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PreviewFrameRenderer.swift(UV 约定基准),
             docs/specs/CAM-001-相机与首页.md, .ai/modules/camera.md
deps:        [TASK-CAM-015(写集占用，先落地), TASK-CAM-003(预览链路)]
acceptance:
  - iOS App 目标编译 0 error 0 warning（iphonesimulator，scheme=ChuanqiCutApp，P61 口径）
  - 模拟器安装 + 冷启动无崩
  - 真机（传哲）：竖/左横/右横三方向预览均正立、无颠倒、aspect-fill 铺满无变形无黑边
  - 真机：拍照产物方向与预览一致；横屏录制产物用 AVAsset 加载尺寸与录制方向一致
  - 渲染计数口径不变：renderFailureCount 非 0 即异常（P60 探针仍有效）
verification:
  - xcodebuild -scheme ChuanqiCutApp -sdk iphonesimulator build
  - 模拟器安装冷启动；真机人工 = SPEC-CAM-001 A7（归传哲）
risk:        ①CI 渲进 Metal 纹理的行序在 iOS 未实证（macOS 探针不等价：本机实测该 API
             全变体静默写零 error=nil），翻转常数按「CI bottom-up」假设取值，真机一验定案，
             错则改一个符号；②横屏角度映射按「landscapeLeft=0（传感器原生位）/landscapeRight=180」
             推导，若真机横屏 180° 反接，交换 0/180 一行；③录制中旋转 = 非目标（Spec v1.2），
             录制开始锁定方向，否则 AVAssetWriter 尺寸中途变化 append 失败。
parallel:    false
```

## 背景

传哲 2026-10-05 真机报告：预览**上下颠倒**、旋转屏幕处理不对。诊断（本会话实证）：

1. 颠倒：预览链 `CI render → 中间纹理 → blit 逐行拷贝 → drawable`（CAM-015 引入的中间纹理路径）
   **全程无翻转补偿**。消去法定位：blit 保行序、drawable row0=屏幕顶（编辑器预览
   PreviewFrameRenderer 的 uv 约定已锁定该事实）⇒ CI 写 scratch 时把图像写颠倒了。
   对照组：拍照走 `createCGImage`（CG 目标路径 CI 自动处理翻转）⇒ 预期照片正立、仅预览颠倒。
   **真机判别步骤（实施前做一次）**：旧版拍一张照片——照片正立⇒坐实本诊断；
   照片也颠倒⇒是 `videoRotationAngle=90` 语义问题，修法改为角度换 270。
2. 旋转：App Info.plist 允许竖+左右横，但采集把旋转角**硬编码 90°**（`applyPortraitOrientation`）
   且只在配置/切机时设置一次，从不跟踪界面方向 ⇒ 横屏必错。

## 实现要点

1. **渲染端**（CameraRenderer）：blit 换成显式 UV 的渲染 pass（内联 MSL，与
   PreviewFrameRenderer 同约定「屏幕上边→v=0」），逐帧按 frame extent vs drawableSize
   计算 aspect-fill 采样窗；v 翻转折叠成一个**带符号 vScale 常数**（负=翻转）。
   drawable 保持 framebufferOnly（render pass 写入合法，同 CAM-015 已实测结论）。
2. **采集端**（CameraManager）：`applyPortraitOrientation` 泛化为
   `applyOrientation(_:IO)`；videoRotationAngle 映射
   {portrait:90, landscapeLeft:0, landscapeRight:180}（iOS 17+），
   iOS 16 fallback 按同名 `AVCaptureVideoOrientation` 直赋；前摄镜像在旋转之后设置。
3. **方向源**（CameraView → ViewModel）：监听
   `UIWindowScene.interfaceOrientationDidChangeNotification`（object 即 scene，
   避免 UIDevice.orientation 的 faceUp/flat 脏值与过早触发），取
   `scene.interfaceOrientation` → `manager.setInterfaceOrientation(_:)`
   （sessionQueue 串行）。ViewModel 去重同值重复设置。
4. **录制锁定**：录制中不更新 connection 方向（ViewModel 侧 `!isRecording` 门控），
   与滤镜/美颜的开始锁定同语义；录制中旋转界面 = 预览中心裁切显示，流尺寸不变。

## 验收

逐条对 acceptance：①②本机门禁；③④真机归传哲（日志先行：渲染统计口径不变）。

## 回写

- 接口变更（applyOrientation/setInterfaceOrientation）→ `.ai/modules/camera.md`
- 坑（CI 行序 iOS 实证值、横屏映射实测定案）→ `.ai/memory/pitfalls.md` / `baselines.md`
- 当日日志 → `.workbuddy/memory/2026-10-05.md`
