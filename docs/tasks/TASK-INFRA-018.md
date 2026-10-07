# TASK-INFRA-018：ChuanqiCutCamera Pod 迁移（相机全域 + metallib 管线；阶段 4 提前）

```yaml
id:          TASK-INFRA-018
layer:       基建
goal:        ADR-0031 阶段 4（传哲指定提前）：iOSApp/Camera（App target 直编）+ SharedUI/Camera（契约层）迁入独立 iOS Pod，metallib 管线随迁并保持真机可用
input:       [ADR-0031, ADR-0021, ADR-0014, PLAN-壳工程与功能Pod, pitfalls P83]
output:      [packages/ChuanqiCutCamera/{podspec,Package.swift,Sources,Tests}, SharedUI 删 Camera 契约, iOSApp 删 Camera 目录, project.yml 显式 schemes + 管线改源]
write_set:   apps/apple/packages/ChuanqiCutCamera/**、SharedUI/Sources/SharedUI/Camera/**（迁出）、SharedUI/Tests/SharedUITests/Camera*Tests.swift DetectionSmoothingTests FaceMaskTests（迁出）、SharedUI/Sources/SharedUI/Common/EditorEntryInjector.swift、apps/apple/ios/{project.yml,Podfile,iOSApp/HomeView.swift,iOSApp/ChuanqiCutApp.swift}
read_set:    docs/decisions/ADR-0021-CoreImage-kernel不走Xcode内建Metal阶段.md
deps:        [TASK-INFRA-013]
acceptance:
  - 测试守恒：SharedUI 52 + Player 52 + Camera 36 = 140（对齐迁移前 HEAD）
  - metallib 产物落 App bundle 且非空壳（大小 ~8.4KB + kernelNames 含 cq_beauty_down_h / cq_beauty_up_v_mix）
  - 双壳构建过；mac 壳不引相机 Pod 且编译不受影响
verification:
  - (cd apps/apple/packages/ChuanqiCutCamera && swift test --disable-sandbox --scratch-path <root>/build/spm/ChuanqiCutCamera)
  - xcodebuild -workspace apps/apple/ios/ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -sdk iphonesimulator build   # 36/36 契约测试在 mac 侧跑
  - strings <app>/beauty_bilateral.metallib | grep cq_beauty
risk:    metallib 管线（已实测三个坑：.metal 不得进 source_files；静态 Pod script_phase 产物到不了 App bundle；scheme 住 xcuserdata 会被 xcodegen 重生成丢失）——详见 pitfalls P85
parallel:    false
```

## 背景
传哲 2026-10-07 指定「拍摄怎么还在工程」→ 阶段 4 从 PLAN 顺序中提前。相机域是四个
Pod 中唯一**有构建期生成资源**的（CIKernel metallib），也是唯一 **iOS 专属**的
（mac 壳不引）。

## 实现要点
- 结构：`Sources/ChuanqiCutCamera/`（契约层 4 文件，进 SPM test host，macOS 可编译）
  + `Sources/ChuanqiCutCameraImpl/`（实现层，iOS 专属，不进 SPM target）+ `Tests/`。
- 契约层零外引、实现层零基座符号（CameraView 的 EditorScreen 除外）→ 解耦：
  `SharedUI/Common/EditorEntryInjector`（@MainActor 注入器），iOS 壳装配
  `EditorScreen(initialMediaURL:)`；CameraView 经注入点进入编辑器，录制产物丢弃语义不变。
- metallib：管线**留在壳工程**（iOS project.yml postBuildScripts，SRC 指向 Pod 内
  .metal 源）——静态库 Pod 的 script_phase 产物到不了 App bundle（实测假绿）；.metal
  绝不进 source_files（会被 CocoaPods 挂进 Xcode 内建 Metal 阶段，air-lld 未解析
  coreimage:: 符号）。两条实测案底记 P85。
- iOS project.yml 增显式 `schemes:`（原 ChuanqiCutApp scheme 住 xcuserdata，xcodegen
  重生成即丢；自动补的 "ChuanqiCut" scheme 不含 App target = BUILD SUCCEEDED 假成功）。

## 验收（2026-10-07 实测）
- Camera 包 swift test **36/36**；SharedUI swift test **52/52**（88−36，守恒 ✓）。
- iOS BUILD SUCCEEDED；App bundle 内 beauty_bilateral.metallib **8431B**、kernel
  `cq_beauty_down_h` / `cq_beauty_up_v_mix` 齐全（script 时间戳 = 构建时刻，非残留）。
- macOS BUILD SUCCEEDED（3 pods，无相机）。
- 全量门禁 **PASS=12 / FAIL=0 / SKIP=0**（+artifacts、+apple-camera 新步首跑即绿）。

## 回写
- `.ai/modules/camera.md` / `ui-apple.md` 模块册；pitfalls P85；BACKLOG §14 ✅。
- 真机验收（预览/滤镜/磨皮/区域化/录制颜色）= 池 [2]，攒一趟执行。
