# TASK-CAM-018：美颜色彩空间修正——workingColorSpace 域对齐 + 录制色彩对齐 + 引擎状态日志

> ⚠️ **曾号 TASK-CAM-015**（2026-10-07 撞号裁定让位，见文末）。git 历史中本任务
> 提交（3d5600f 等）用旧号 `CAM-015/016`，追溯按此桥接。曾用 SPEC 文件名
> `SPEC-CAM-015-016`，现名 `SPEC-CAM-018-019`。

```yaml
id:          TASK-CAM-018
layer:       UI(iOSApp)
goal:        消除磨皮真机闪烁的根因（kernel 输入域 = harness 定标域）；预览与录制颜色一致；磨皮引擎激活/回落可观察
input:       [SPEC-CAM-018-019 §1.1/1.2, TASK-CAM-012 剩余风险栏, BeautyKernelProfile 定标注释]
             CameraRenderer.swift(输出 sRGB 显式化), BeautyKernel.swift(一次性状态日志)]
write_set:   apps/apple/ios/iOSApp/Camera/{CameraViewModel,CameraRecorder,CameraRenderer,Camera/Effects/BeautyKernel}.swift
read_set:    beauty_bilateral.metal, CameraBeauty.swift, tools/qa/beauty_harness/
deps:        [TASK-CAM-012]
acceptance:
  - CIContext 创建显式带 workingColorSpace = gamma sRGB（代码 grep + typecheck）
  - 预览渲染与录制渲染输出色彩空间显式 sRGB；录制池缓冲带色彩空间标记（池不接受时按 §开放问题 备选）
  - BeautyKernel 安装成功/回落（metallib 缺失/kernel 缺失）各路径一次性日志
  - 真机人工：磨皮闪烁消失、保边恢复（归传哲）
verification:
  - iOS typecheck（P46 技法，构建机）；真机 log 冒烟；黄金命令 tools/build/build_core.sh 不涉及（纯 App 层）
risk:        workingColorSpace 改动会影响滤镜预设(CIColorControls 等)的观感基线——如滤镜颜色偏移，
             以"真机无闪烁 + 颜色自然"人工定案；σr 数值本身不动（域对了参数即对）
parallel:    false
```

## 实现要点

- `CIContext(mtlDevice:device, options: [.workingColorSpace: CGColorSpace(name: .sRGB)!])`：
  相机帧色彩匹配到 gamma 域 → kernel 的亮度差回到 σr 定标时的语义（harness 用未标记
  BGRA 实测 gamma 域）。
- 录制：`AVAssetWriterInputPixelBufferAdaptor.sourcePixelBufferAttributes` 追加
  `kCVPixelBufferColorSpaceKey`（sRGB）；若池实际不接受（真机冒烟确认），备选自建
  `CVPixelBufferPool`（SPEC §6 开放问题 3）。
- 日志：`os_log`/`print` 一次性（installSharedSmoothingIfNeeded 内），不逐帧。

## 进度（2026-10-06 代码落地，本机宿主验证；真机待传哲）

| 子步骤 | 状态 |
|---|---|
| `CameraViewModel.init` CIContext 显式 `.workingColorSpace` = gamma sRGB | 完成（`CGColorSpace(name:)` 失败时回退无 options 默认，不 force unwrap） |
| 预览渲染输出色彩空间显式 sRGB（CameraRenderer） | 完成（DeviceRGB 语义含糊，替换为显式 sRGB） |
| 录制池缓冲 `kCVPixelBufferColorSpaceKey`（CameraRecorder） | 完成；池是否实际接受该键 = 真机冒烟项（SPEC §6-3 备选：自建带色彩空间的池） |
| 引擎安装三路径一次性 os_log（INSTALLED/FALLBACK+原因） | 完成（BeautyKernel 内 `Logger(subsystem:com.chuanqi.cut, category:beauty)`） |
| iOS typecheck（P46 技法） | **未跑**（本机 Swift 5.5 连 SE-0345 简写 parse 都不支持，构建机执行） |
| 真机人工：磨皮不闪、保边恢复；滤镜观感基线复核 | **未做**（归传哲） |

## 验证证据（2026-10-06，本机）

- 代码 grep：`workingColorSpace` / `outputColorSpace` / `kCVPixelBufferColorSpaceKey`
  三处落位；os.log import + 三路径日志落位。
- 宿主脚本验证与本卡无直接耦合（色彩域为真机行为）；随 CAM-019 的宿主脚本
  一并跑通（区域化 14/14，见 TASK-CAM-019）。

## 剩余风险与待办

- 真机无构建环境：typecheck/真机冒烟须在构建机执行（P46/P42b 同口径）。
- 滤镜观感基线可能随 workingColorSpace 变化（LUT/CIColorControls 从线性域回到
  gamma 域执行，浓淡可能变化）——真机人工定案；若观感漂移过大，回退方案是
  仅在美颜链路用独立 CIContext，滤镜链维持原状（不优先）。
- 录制池缓冲对 `kCVPixelBufferColorSpaceKey` 的接受度未验证（hypothesis）；
  备选方案见 SPEC §6-3。

---

## 撞号裁定记录（2026-10-07）

本卡原占用 `TASK-CAM-015`，与远端（相机线）更早入库的「预览 CI→drawable 渲染修复」撞号。
裁定：远端线保留原号（先入库 + 活线：CAM-017/021 挂在其编号体系上）；
本机美颜线（已完结）让位迁至 `TASK-CAM-018`，人脸区域化卡迁至 `TASK-CAM-019`。
同批：pitfalls 本机线 P62/P63 → P80/P81。
