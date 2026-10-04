# HANDOFF-004：相机模块会话交接

> 日期：2026-10-04（同日两次转向：跨端契约 → iOS 原生，**ADR-0014 已接受**）
> 上游：RESEARCH-002、SPEC-CAM-001 v1.1、ADR-0014、TASK-CAM-001~005、BACKLOG §9
> 状态核对基准：对着本轮实际改动与门禁数字写。

## 1. 关键结论（新会话先读这段）

1. **相机模块 = iOS 原生功能域**（ADR-0014）：Swift + AVFoundation + Vision/ARKit +
   Core Image/Metal，落 `apps/apple/ios/iOSApp/Camera/`。**不经 PAL、不加 C ABI**。
2. **编辑器内核维持 C++ 跨端**：本转向只豁免相机实时域；录制产物经既有
   `cq_session`/`importMedia` 进时间线。剪辑业务红线不松动。
3. **CAM-001 已回退**：`pal/camera.h`、`cq_sdk.h` 相机 ABI、3 个能力枚举当日删除
   （git checkout 7 文件 + 删 2 新文件），复跑门禁 **39/39**。别在旧文档里找相机契约。
4. **扬长清单**（选型依据）：ARKit 人脸网格(1220 顶点)/Vision 76 点、AVDepthData
   景深、Center Stage、Core Image、MetalFX(A17 Pro+)、MultiCamSession 硬件时间戳、
   CoreML(ANE) 直转——**不走** MediaPipe/tflite→mlpackage 管线（AI-013 只服务编辑器域）。

## 2. 本轮做完 / 未做

| 事项 | 状态 |
|---|---|
| RESEARCH-002 / SPEC-CAM-001 v1.1 / ADR-0014 / 任务卡重写 | **完成** |
| CAM-001（跨端契约）| **完成→回退留档**，门禁 39/39 |
| CAM-002~005（iOS 原生实现） | **代码全部写完**（11 个 Swift 文件，见 §4），验证见下 |
| 追加（同日晚）：拍照 + 基础美颜 | **完成**：照片/视频模式 + 双态快门 + AVCapturePhotoOutput；CameraBeauty 磨皮/美白纯函数三路共用（预览/拍照/录制 WYSIWYG）+ 单测；美型仍归 B 期（UI 如实标注） |
| Swift 语法解析（swiftc -parse，全部新文件） | **通过** |
| SharedUI swift test（含新增 CameraFilterTests） | **本机阻塞**：测试宿主需 xcframework，xcframework 的 ios-device 切片需 Xcode 16+（pitfalls P42b：iOS 17.2 SDK 无 VT 编码器常量） |
| iOS App 构建（xcodegen/pod/xcodebuild） | **本机阻塞**：xcodegen 未装、Ruby 2.6 跑不了 CocoaPods 1.17、SWIFT_VERSION 6.1 需 Xcode 16+（§3-3） |
| core 门禁（回退后） | **39/39** |

## 3. 坑（必读）

1. **本机 ≠ 原开发机**：macOS 13.7 / Xcode 15.2 / AppleClang 15。旧工具链兼容修复
   已做两处（log.cpp、test_perf.cpp，P36）；新代码别用 `std::va_list`、别对 volatile
   复合赋值。
2. **cmake**：`pip3 install --user cmake` + `export CMAKE_BIN=$(ls ~/Library/Python/*/bin/cmake | head -1)`（P37）。
3. **iOS 构建风险**：project.yml `SWIFT_VERSION: 6.1` 是 Xcode 16+ 的语言版本，
   本机 Xcode 15.2 可能编不了 iOS target——**不要悄悄降版本**去适配本机；
   如实记录，iOS 构建验证可在新 Xcode 机器上跑（SWIFT 层语法可先用 macOS 侧
   `swift build`/swift test 兜底检查）。
4. `AVCaptureMultiCamSession` 仅 iOS，macOS unavailable（P38）；双摄运行时查
   `isMultiCamSupported`。

## 4. CAM-002 装配形状（照做）

```
apps/apple/ios/iOSApp/Camera/
  CameraManager.swift    # AVCaptureSession 编排:前后切换(Stopped 态)、32BGRA+
                         # alwaysDiscardsLateVideoFrames、专用串行队列、权限三分支、
                         # 前后台停止/恢复;双摄留 CAM-021
  CameraRenderer.swift   # 帧槽(丢帧不排队) + CIContext + CIRenderDestination(drawable)
  CameraVideoView.swift  # MTKView isPaused=false 连续渲染(与编辑器按需单帧刻意不同)
  CameraRecorder.swift   # AVAssetWriter:视频 PixelBufferAdaptor(CVPixelBufferPool 预热)
                         # + 音频 append CMSampleBuffer;PTS 首样本对齐
  CameraViewModel.swift  # @MainActor 状态桥
SharedUI/Sources/SharedUI/Camera/CameraFilter.swift      # 滤镜预设纯函数(可单测)
SharedUI/Sources/SharedUI/Editor/EditorScreen.swift      # EditorViewModel 惰性创建
                                                         # (P8:先建值后包装)+initialMedia
apps/apple/ios/project.yml   # info.properties 补三个 Usage 权限
```

## 5. 任务状态总表（2026-10-04 收工时点）

| 任务 | 状态 |
|---|---|
| CAM-001 跨端契约 | 完成→**回退留档**（39/39） |
| CAM-002 采集管理器 | 未开工（下一会话第一个） |
| CAM-003 预览渲染 + 滤镜 | 未开工 |
| CAM-004 首页 + 相机页 + 惰性化 | 未开工 |
| CAM-005 录制 + 产出 | 未开工 |
| B 期 CAM-011~014 | **已拆卡**(2026-10-04 晚:检测桥/磨皮升级/美型 warp/贴纸道具) |
| C 期 CAM-021~024 | 未拆卡 |

## 6. 新会话开场指引(B 期从 CAM-011 开始)

开场说一句「继续相机模块 B 期,按 HANDOFF-004 从 TASK-CAM-011 开始」即可。
新会话按仓库惯例先读:AGENTS.md(真源)→ 本文件 → SPEC-CAM-001 v1.1 → TASK-CAM-011 →
`.ai/modules/ui-apple.md`。B 期处理链总序(写代码前记住):
**磨皮(012) → 美型 warp(013) → 滤镜(A 期既有) → 贴纸叠加(014)**,
四段全部走 latest-wins 帧槽 + 采集/渲染/检测三队列互不阻塞的既有线程模型。
