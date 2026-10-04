# TASK-CAM-011：Vision 检测桥 + 帧间平滑（B 期）

```yaml
id:          TASK-CAM-011
layer:       UI(iOSApp)
goal:        Vision 系统能力桥:人脸关键点(76)/人体姿态/动物框的实时检测 + 关键点帧间平滑,输出给美型/道具/贴纸消费
input:       [SPEC-CAM-001 v1.1 §3 B 期, ADR-0014, RESEARCH-002 §4]
output:      [apps/apple/ios/iOSApp/Camera/Detection/VisionDetector.swift,
             apps/apple/ios/iOSApp/Camera/Detection/FaceObservation.swift, ctest 不可用→SharedUI 纯函数单测]
write_set:   apps/apple/ios/iOSApp/Camera/Detection/, apps/apple/packages/SharedUI/Sources/SharedUI/Camera/(平滑纯函数),
             apps/apple/packages/SharedUI/Tests/SharedUITests/(新增用例)
read_set:    .ai/modules/ui-apple.md, CameraManager.swift(帧队列节奏)
deps:        [TASK-CAM-002, TASK-CAM-003, TASK-CAM-004]
acceptance:
  - 观测结构(归一化坐标 0...1,与图像方向无关)纯函数单测:映射/平滑收敛
  - 检测降频可配置(默认 15Hz [E],真机可调);检测队列与采集/渲染队列互不阻塞
  - iOS 17+ 动物姿态用 @available 门控,低版本如实不可用(不做假能力)
  - swiftc -parse + SharedUI swift test(新 Xcode 机器)全过
verification:
  - swift test(SharedUI) + iOS 构建(命令同 CAM-002);真机检测耗时埋点入 baselines
risk:        Vision 每帧检测的 CPU/ANE 占用与预览争抢(缓解:降频+小图输入;真机实测定频)
parallel:    false
```

## 实现要点

- `VisionDetector`:对降采样帧跑 `VNDetectFaceLandmarksRequest`(76 点)+ `DetectHumanBodyPoseRequest`
  + `DetectAnimalsRequest`;结果转**中性观测结构**(归一化坐标 + yaw/pitch/roll + 置信度)。
- 帧间平滑放 SharedUI 纯函数(EMA 或 One-Euro 简化款),两端可测;参数(平滑强度)随美颜面板。
- ARKit 前摄 1220 顶点人脸网格**不在本卡**(归 CAM-013 的前摄增强);本卡输出是后摄/通用底座。

## 实现进度（2026-10-04，完成）

### 子步骤

| # | 子步骤 | 状态 |
|---|---|---|
| 1 | 观测结构 `FaceObservation.swift`（人脸 12 区域 / 人体 19 关节 / 动物+物种 / 快照） | ✅ |
| 2 | SharedUI 平滑纯函数 + 坐标映射 `DetectionSmoothing.swift`（One-Euro 简化款自适应 EMA） | ✅ |
| 3 | SharedUI 单测 `DetectionSmoothingTests.swift`（13 用例：直通/重置/保持/收敛/单调/映射/夹取） | ✅ 已写，随包级 swift test 在新 Xcode 机器跑 |
| 4 | 检测桥 `VisionDetector.swift`（降频闸门 + 三队列不阻塞 + 平滑状态 + 埋点计数器） | ✅ |
| 5 | 接线进 `CameraViewModel.wireCallbacks` / 渲染链 | ⏸ **归 CAM-013**（本卡 write_set 不含 CameraViewModel/CameraRenderer；首个消费方落地时接线） |

### 写集落地（与卡面一致）

- 新增 `apps/apple/ios/iOSApp/Camera/Detection/FaceObservation.swift`
- 新增 `apps/apple/ios/iOSApp/Camera/Detection/VisionDetector.swift`
- 新增 `apps/apple/packages/SharedUI/Sources/SharedUI/Camera/DetectionSmoothing.swift`
- 新增 `apps/apple/packages/SharedUI/Tests/SharedUITests/DetectionSmoothingTests.swift`
- 未动：`project.yml`（sources 递归收集）、`Package.swift`、既有任何文件

### 验证证据（2026-10-04，本机 macOS 13.7 / Xcode 15.2 / Swift 5.9.2）

| 项 | 命令 | 结果 |
|---|---|---|
| iOS 侧类型检查 | `xcrun swiftc -typecheck -sdk iphonesimulator -target x86_64-apple-ios16.0-simulator -I <stub>`（FaceObservation + VisionDetector，SharedUI 真源文件编成同名 stub 模块） | **0 错误 0 警告**（比 A 期的 `-parse` 强：抓出并修正 4 个 API 形状错误，见 pitfalls P46） |
| 单测文件类型检查 | 同上（macOS SDK + `-enable-testing` stub + XCTest 平台路径） | **0 错误**（抓出 `XCTAssertEqual(CGFloat?, accuracy:)` 重载不适用，已修——否则新机器 swift test 必挂） |
| 纯函数数学真实执行 | macOS 宿主 `swiftc` 编译执行 scratch harness（断言集复刻单测） | **19/19 PASS**（收敛残差 0.00045 < 输入抖动 0.003） |
| SharedUI `swift test` | 包级 | **本机阻塞**（双重：Package.swift tools 6.1 清单 Swift 5.9.2 解析不了 + xcframework 缺失，见 P46）——**待新 Xcode 机器**，非代码未完成 |
| iOS App 构建 | 同 CAM-002 命令 | 本机阻塞（既有结论 P42b，非本卡新增） |

### 锁定的契约（CAM-013/014 消费方必读）

1. **坐标约定**：图像归一化、origin 左上、两轴 0...1（Vision 左下原点由检测器经
   `visionPointToImageNormalized`/`visionRectToImageNormalized` 翻转，消费方不再翻）。
   ⚠️ Vision y 翻转方向是真机待校验项（hypothesis，冒烟时确认不镜像/不倒置）。
2. **回调线程**：`onResult` 在检测专用队列；offer 来自采集队列、永不阻塞（latest-wins）。
3. **平滑在检测器内**：`onResult` 交付的观测已平滑；`smoothingStrength` 随美颜面板（013 接 UI）。
4. **单目标策略**：人脸取最大框、人体取最高置信度、动物姿态只锚首只（多目标归 C 期）。
5. **点位数不硬编码 76**：Vision 12 区域有共享端点（如 medianLine 与鼻梁重合），
   各区域实际点数以真机对表为准 [E]；动物关节对表 SDK 头文件：耳分 Top/Middle/Bottom、
   鼻为 `nose`（无 snout）。
6. **诊断埋点**：`lastDetectionDurationMs` / `totalDetections` / `totalDroppedByRate` /
   `totalFailed`（baselines 回填数据源；默认 15Hz 为估算 [E]，真机调参）。

### 其他说明

- 动物检测用 `VNRecognizeAnimalsRequest`（iOS 14+，带物种标签）替代卡面写的
  `DetectAnimalsRequest`（iOS 13+，只有框）——贴纸选择需要物种，且 14+ ≤ 部署目标 16。
- 动物姿态（`VNDetectAnimalBodyPoseRequest`，iOS 17+）严格 `@available` 门控，
  类型引用全部收在门控分支/基类（VNRequest/VNObservation）里，低版本如实无 pose。
- **无新 ADR**：本卡未改变既有架构约束（ADR-0014 已覆盖相机 iOS 原生域）；
  坐标契约属模块接口约定，由本卡+`.ai/modules/ui-apple.md` 承载。
