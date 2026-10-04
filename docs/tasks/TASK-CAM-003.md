# TASK-CAM-003：相机预览渲染链路 + 滤镜（MTKView + Core Image，iOS 原生）

```yaml
id:          TASK-CAM-003
layer:       UI(iOSApp + SharedUI 纯函数)
goal:        相机帧 → Core Image 滤镜 → MTKView 连续渲染;滤镜预设纯函数可单测
input:       [SPEC-CAM-001 v1.1, ADR-0014, SharedUI MetalPreviewView.swift(上屏模式参照)]
output:      [apps/apple/ios/iOSApp/Camera/CameraVideoView.swift, CameraRenderer.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/Camera/CameraFilter.swift,
             apps/apple/packages/SharedUI/Tests/SharedUITests/CameraFilterTests.swift]
write_set:   上述文件
read_set:    SharedUI/Common/Theme.swift
deps:        [TASK-CAM-002]
acceptance:
  - CameraFilter 单测:每个预设对构造 CIImage 返回非 nil 且不等于原图对象;名称/唯一性
  - 渲染链路真机 ≥30fps(埋点,baselines 入库;归 A5)
  - 零 CPU 读回路径:全程 CIContext→drawable,无像素 memcpy(Instruments 抽查)
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - iOS 构建命令同 CAM-002
risk:        Core Image 与 MTKView drawable 色彩空间匹配(用 CIRenderDestination 显式指定)
parallel:    false
```

## 实现要点

- CVPixelBuffer → `CIImage(cvPixelBuffer:)` → 滤镜 → `CIContext.render(_:to: CIRenderDestination(drawable))`。
- MTKView `isPaused=false` 连续渲染（与编辑器"按需单帧"刻意不同，见 RESEARCH-002 §7.1）。
- 帧槽：采集队列写、渲染线程读，串行队列/`os_unfair_lock` 保护，**丢帧不排队**。
- 滤镜预设：CIPhotoEffect 系（Mono/Chrome/Fade/Instant/Noir/Process/Transfer）+ 原图，
  纯函数 `apply(to:) -> CIImage` 放 SharedUI（平台无关，可测）。
- B 期接入自写 Metal kernel（磨皮/美型）时从同一插槽插 CIImage 链。

---

## 2026-10-04 晚追加（传哲需求：拍照 + 基础美颜提前到 A 期）

- **拍照**：`AVCapturePhotoOutput` 进会话；原始帧走与预览同一条 `process` 链
  （美颜→滤镜，WYSIWYG）→ CGImage → 存相册（addOnly 权限已声明）。
  UI：照片/视频模式切换 + 双态快门。
- **基础美颜（真实生效，非占位）**：`SharedUI/Camera/CameraBeauty.swift` 纯函数
  （磨皮=高斯模糊+亮度锐化保边近似；美白=小步长曝光+亮度；参数单调、off 恒等直通）
  + 单测 `CameraBeautyTests`；预览/拍照/录制三路共用，录制开始时与滤镜一并锁定。
  UI：美颜面板（磨皮/美白滑杆）。
- **美型不进本档**：瘦脸/大眼需人脸关键点驱动的 Metal 网格形变，仍归
  CAM-012/013（B 期）；UI 中以禁用行如实标注「B 期上线」，不做假滑杆。
- 验证：swiftc -parse 全过；真机项归 A5/A6 口径不变。
