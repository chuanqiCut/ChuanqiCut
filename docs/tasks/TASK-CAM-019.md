# TASK-CAM-019：美白/磨皮人脸区域化——接 CAM-011 检测桥 + 羽化蒙版混合

> ⚠️ **曾号 TASK-CAM-016**（2026-10-07 撞号裁定让位，随 CAM-018 同批迁移；
> git 历史中本任务提交用旧号 `CAM-015/016`，追溯按此桥接）。

```yaml
id:          TASK-CAM-019
layer:       UI(iOSApp)
layer:       UI(iOSApp)
goal:        美白与磨皮只作用于人脸区域；无脸直通；检测能力缺失时保持全画面旧行为（向后兼容）
input:       [SPEC-CAM-018-019 §4, TASK-CAM-011(检测桥/坐标契约/One-Euro), CameraBeauty.swift 既有契约]
output:      [SharedUI/Camera/FaceMask.swift(纯函数,新), SharedUI/Camera/CameraBeauty.swift(契约扩展),
             CameraViewModel.swift(检测接线+每N帧), CameraRenderer.swift(faces 注入),
             CameraRecorder.swift(faces 注入), SharedUITests(新增用例)]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Camera/{FaceMask,CameraBeauty}.swift,
             apps/apple/ios/iOSApp/Camera/{CameraViewModel,CameraRenderer,CameraRecorder}.swift,
             apps/apple/packages/SharedUI/Tests/SharedUITests/(新增 FaceMask 相关)
read_set:    Detection/{VisionDetector,FaceObservation}.swift, DetectionSmoothing.swift,
             CameraVideoView.swift, Effects/BeautyKernel.swift
deps:        [TASK-CAM-011, TASK-CAM-018]
acceptance:
  - 坐标链纯函数单测：Vision(左下)→图像归一化(左上)→CI(左下) 翻转正确、夹取正确（macOS 宿主跑）
  - faces nil/[]/非空 三态语义（SPEC §4 表）：nil=全画面旧行为、[]=直通、非空=蒙版混合
  - off 恒等直通、单调等既有 SharedUITests 口径不回归（全量）
  - 引擎注入签名 (CIImage, Double) -> CIImage? 不变；蒙版在 CameraBeauty.apply 内施加
  - 真机人工：美白只在脸、背景不糊、无脸不处理、检测跳帧不抖动（归传哲）
verification:
  - swift test（SharedUI 全量，构建机）；本机先以纯 Swift 临时脚本验证算法（Foundation-only，Swift 5.5 可跑）
  - cq-media-pipeline 专项：检测在采集队列每 N 帧同步执行（VNDetectFaceRectanglesRequest），
    N=3 [E]；faces 经锁保护 store 跨线程；渲染/录制只读最新值
risk:        Vision 检测耗时未实测（CAM-011 遗留），若拖慢采集队列导致掉帧，提高 N 或降分辨率检测；
             椭圆蒙版对侧脸/多人场景的覆盖度 v1 从宽（框放大 15% 羽化），精细肤色分割不做
parallel:    false
```

## 实现要点

- **纯函数（SharedUI，宿主可测）**：
  - `FaceMask.ciRects(fromNormalized:in:)`：归一化框(左上) → CI 空间CGRect（y 翻转）；
  - `FaceMask.mask(for faces:in extent:) -> CIImage?`：每脸一个径向渐变椭圆（白→透明，
    框放大 15% [E]），source-over 累加，空/无脸返回 nil；
  - box 平滑：两角点复用 `smoothKeypoints`（count=2，形状一致），状态由采集队列侧持有。
- **契约**：`CameraBeautyParams.apply(to:faces:)`——nil=全画面（macOS/未接检测兜底）、
  []=直通、非空=磨皮与美白各自 `CIBlendWithMask(原图, 处理后, mask)`。
- **接线**：wireCallbacks（采集队列）每 N=3 帧 VNDetectFaceRectanglesRequest → 平滑 →
  `FaceBoxStore`（锁）；renderer.draw 与 recorder.appendVideo 读最新 faces。
- **处理链顺序不变**：美颜(磨皮→美白,区域化) → 滤镜——与 CAM-013 锁定的
  "磨皮 → 美型 warp → 滤镜" 相容，美型未来插在磨皮后不受影响。

## 进度（2026-10-06 代码落地，本机宿主验证；swift test/真机待构建机与传哲）

| 子步骤 | 状态 |
|---|---|
| `SharedUI/Camera/FaceMask.swift`（ciRect 翻转外扩 / smoothedBox / mask 黑底+椭圆） | 完成 |
| `CameraBeauty.apply(to:faces:)` 三态契约 + `CIBlendWithMask` 混合（引擎签名不变） | 完成；默认参 `faces: [CGRect]? = nil` 既有调用方零改动 |
| `FaceBoxStore`（CameraRenderer.swift 内，与 CameraFrameSlot 同纪律） | 完成；update（检测队列串行写，平滑状态）/ current（渲染录制读）/ reset（前后摄切换） |
| 检测接线：`detector.offer` 挂 wireCallbacks + onResult → store | 完成；`CQ_DEBUG_PROFILE=1` 打印检测耗时/计数 |
| 三消费方传 faces：预览 draw / 拍照 capturePhoto / 录制 appendVideo | 完成；录制实时跟随主体（WYSIWYG），前后摄切换 reset |
| `SharedUITests/FaceMaskTests.swift`（13 用例：坐标/平滑/蒙版渲染采样/三态契约） | 落盘；**swift test 未跑**（本机 Swift 5.5 阻塞，P45/P46 口径） |
| 本机宿主脚本验证 | **14/14 PASS**（坐标翻转/夹取/平滑三态/空脸 nil/退化框全黑/蒙版 extent/渲染采样/区域化端到端：脸内 76→115、背景 76→76） |
| 真机人工：美白只在脸/背景不糊/无脸不处理/检测跳帧不抖 | **未做**（归传哲） |

## 验证证据（2026-10-06，本机宿主脚本 + 代码 grep）

- 宿主脚本（临时，未入库）：Swift 5.5 + macOS 12 宿主 CoreImage 实渲染，
  逐项断言见上表；脚本逻辑与 FaceMask.swift 实现逐行同源。
- **宿主验证的价值实证**：两处 API 假设错误在写测试前被抓（CGPoint+CGVector
  运算符不存在；CIRadialGradient 输出 extent 有限、cropped 只做交集 → 蒙版
  extent 陷阱）——均落 pitfalls P81（曾号 P63，撞号让位）。
- 代码 grep：三消费方 `faces:` 落位；`FaceBoxStore` 三方法落位；
  `detector.offer` 在 wireCallbacks。

## 剩余风险与待办

- Vision 检测耗时真机数字未入库（C2 验收项，`CQ_DEBUG_PROFILE=1` 埋点）。
- 前摄镜像如果未来引入（目前预览不镜像），faces 坐标需同步镜像——留注释锚点。
