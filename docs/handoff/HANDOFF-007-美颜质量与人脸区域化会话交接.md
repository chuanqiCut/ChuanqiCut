# HANDOFF-007：美颜质量修复与人脸区域化会话交接（CAM-015/016）

- 日期：2026-10-06
- 上游：SPEC-CAM-015-016、TASK-CAM-015、TASK-CAM-016、pitfalls P62/P63
- 触发：真机验收反馈"磨皮画面开闪、美白不基于人脸"（2026-10-06）

## 本轮做了什么（对着 commit 核）

1. **根因诊断**（对话轮完成，全部有 file:line 证据）：
   - 磨皮闪烁 = σr 定标域（harness 未标记 BGRA=gamma）≠ 真机运行域
     （默认 workingColorSpace=线性），双边权重塌陷 → 皮肤沸腾。P62。
   - 美白/磨皮全画面 = `CameraBeauty.apply` 无任何人脸区域参与（设计现状非 bug）。
   - 顺带发现：录制池缓冲无色彩空间标记，产物与预览颜色不一致（hypothesis）。
2. **CAM-015**：CIContext 显式 gamma sRGB working space（根因修复）；预览/录制
   输出显式 sRGB；录制池缓冲加 `kCVPixelBufferColorSpaceKey`；引擎安装三路径
   一次性 os_log（INSTALLED/FALLBACK 原因）。
3. **CAM-016**：`CameraBeautyParams.apply(to:faces:)` 三态契约（nil=全画面兜底 /
   []=直通 / 非空=蒙版区域化，默认参向后兼容）；`FaceMask.swift` 纯函数
   （ciRect 翻转外扩 / smoothedBox / mask 黑底+羽化椭圆）；检测接线
   （`detector.offer` → `FaceBoxStore`）；预览/拍照/录制三消费方同源传 faces。
4. **验证**：本机宿主脚本 14/14 PASS（含区域化端到端：脸内 76→115、背景 76→76）；
   `FaceMaskTests.swift` 13 用例落盘。**swift test / iOS typecheck 未跑**
   （本机 Swift 5.5，P45/P46）；真机人工验收未做。

## 下一步（按优先级）

| 谁 | 事项 |
|---|---|
| 构建机 | `swift test`（SharedUI 全量 + FaceMaskTests）；相机模块 iOS typecheck（P46 技法） |
| 传哲（真机） | ① 磨皮不闪、保边恢复（CAM-015 核心验收）；② 滤镜观感基线复核（workingColorSpace 域变化的连带影响）；③ 美白只在脸/背景不糊/无脸不处理/跳帧不抖；④ 预览 vs 录制颜色一致性（池缓冲色彩空间键接受度）；⑤ 真机 log 确认 `beauty engine INSTALLED` |
| 回填 | baselines.md：检测耗时（CQ_DEBUG_PROFILE）、蒙版观感参数定案（boxExpansion 0.15 / solidCoreRatio 0.56 均 [E]） |
| 未决 | 池若不接受色彩空间键 → SPEC §6-3 备选（自建 CVPixelBufferPool） |

## 装配形状（新会话接手需知）

- **美颜三态契约是公开接口**：`faces: [CGRect]?`（图像归一化、左上原点）。
  CAM-013 美型将来若改区域语义，走同一蒙版基础设施（FaceMask），不要另起炉灶。
- **引擎注入签名未变**：`(CIImage, Double) -> CIImage?`——蒙版在 SharedUI
  `apply` 内施加，BeautyKernel 与默认 CI 实现都保持全帧输出。
- **检测链线程模型**：采集队列 offer（永不阻塞）→ 检测串行队列（15Hz 降频 +
  忙丢弃）→ `onResult` 检测队列 → `FaceBoxStore`（锁）；渲染/录制线程只读。
- 处理链顺序不变：美颜（磨皮→美白，区域化）→ 滤镜；CAM-013 的美型 warp
  将来插在磨皮后不受影响。

## 坑与教训

- P62（harness 定标域必须钉进真机 CIContext）——本坑根因链完整，防复发规则
  已写；真机验收结果出来后回填"修复有效"。
- P63（CIImage DAG 宿主脚本先行）——本轮抓出 2 个 API 假设错；新 CI 几何/渐变
  代码照此流程。
- 本机 Swift 5.5 连 `guard let x` 简写都 parse 不过（SE-0345），宿主脚本要写
  5.5 兼容语法；产物代码按构建机 5.9+ 口径。
