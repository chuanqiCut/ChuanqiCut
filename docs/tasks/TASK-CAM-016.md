# ⚠️ 编号撞号告警（2026-10-07 双线合并时发现，待传哲拍板）

> **本文件当前混合了两个不同任务的卡**，因为本机线与远端线各自独立占用了 CAM-016：
> 本机线 = 美白/磨皮人脸区域化；远端线 = 相机预览方向修复（颠倒 + 横竖屏 + aspect-fill）。
> 与 TASK-UIA-015/016 撞号同源（双线长期未同步，取号未核对对方已用号）。
>
> **处置原则（沿 UIA-015/016 既有先例）**：本文件保留两侧内容，**不擅自重命名**——
> 重命名会波及代码注释、README 登记与 BACKLOG，需人工裁定。
>
> 上半部分 = 本地线内容；下半部分 = 远端线内容。裁定后请拆成两张卡并更新登记。

---

# TASK-CAM-016：美白/磨皮人脸区域化——接 CAM-011 检测桥 + 羽化蒙版混合

```yaml
id:          TASK-CAM-016
layer:       UI(iOSApp)
goal:        美白与磨皮只作用于人脸区域；无脸直通；检测能力缺失时保持全画面旧行为（向后兼容）
input:       [SPEC-CAM-015-016 §4, TASK-CAM-011(检测桥/坐标契约/One-Euro), CameraBeauty.swift 既有契约]
output:      [SharedUI/Camera/FaceMask.swift(纯函数,新), SharedUI/Camera/CameraBeauty.swift(契约扩展),
             CameraViewModel.swift(检测接线+每N帧), CameraRenderer.swift(faces 注入),
             CameraRecorder.swift(faces 注入), SharedUITests(新增用例)]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Camera/{FaceMask,CameraBeauty}.swift,
             apps/apple/ios/iOSApp/Camera/{CameraViewModel,CameraRenderer,CameraRecorder}.swift,
             apps/apple/packages/SharedUI/Tests/SharedUITests/(新增 FaceMask 相关)
read_set:    Detection/{VisionDetector,FaceObservation}.swift, DetectionSmoothing.swift,
             CameraVideoView.swift, Effects/BeautyKernel.swift
deps:        [TASK-CAM-011, TASK-CAM-015]
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
  extent 陷阱）——均落 pitfalls P63。
- 代码 grep：三消费方 `faces:` 落位；`FaceBoxStore` 三方法落位；
  `detector.offer` 在 wireCallbacks。

## 剩余风险与待办

- Vision 检测耗时真机数字未入库（C2 验收项，`CQ_DEBUG_PROFILE=1` 埋点）。
- 前摄镜像如果未来引入（目前预览不镜像），faces 坐标需同步镜像——留注释锚点。


---

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

## 验证状态

- [x] `xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp
      -sdk iphonesimulator -configuration Debug build` → **BUILD SUCCEEDED，0 error，
      改动文件 0 warning**（2026-10-06 00:02）。全日志去重 2 条警告均为环境级
      （Metal 工具链搜索路径 + AppIntents 元数据），与本次改动无关。
- [x] 模拟器（iPhone 16 Pro, iOS 18.4）安装 + 冷启动无崩（launchctl 进程存活；
      模拟器无相机设备，走「设备缺失不伪造成功」降级路径）。
- [ ] **真机（归传哲）**：①竖/左横/右横三方向预览正立、铺满；②拍照判别（照片正立
      ⇒ 行序诊断坐实；照片也颠倒 ⇒ rotationAngle portrait 改 270 一行）；③若预览
      变镜像 → `ciWritesBottomUp` 改 false 一行；④横屏 180° 反接 → 交换 0/180 一行。
- [ ] 真机帧率（渲染 pass vs 旧 blit）—— **baselines 未实测**，待传哲数据。
- ⚠️ 与并行会话 MEDIA-022 同仓并行：其间 SharedUI/bindings 未提交中间态曾阻塞
  全量构建（其自行修复后本卡构建通过）；总门禁 run_gate.sh 按运维约定串行，
  待其收口后补跑全量（P66 运维条）。

## 回写

- 接口变更（applyOrientation/setInterfaceOrientation）→ `.ai/modules/camera.md`
- 坑（CI 行序 iOS 实证值、横屏映射实测定案）→ `.ai/memory/pitfalls.md` / `baselines.md`
- 当日日志 → `.workbuddy/memory/2026-10-05.md`
