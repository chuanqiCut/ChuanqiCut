# ADR-0014：相机模块采用 iOS 原生栈（不经 PAL/C ABI）

- **状态**：已接受（2026-10-04，传哲指示"重点发挥 iOS 平台优势，不一定非采用跨端逻辑，扬长避短"）
- **相关**：ADR-0010（Apple 优先）、ADR-0013（被本 ADR 取代其落层方案）、ADR-0005（编辑器 AI 链路仍有效）、SPEC-CAM-001
- **影响**：CAM-001 已冻结的 PAL 相机契约 + C ABI **当日回退**（死代码不留仓）

## 背景

CAM-001 曾按"跨端契约先行"冻结了 `pal/camera.h` + `cq_camera_*` ABI。
传哲随后明确：相机模块不必硬套跨端抽象。两条路线的真实差异：

| | 跨端契约路线（原 CAM-001） | iOS 原生路线（本 ADR） |
|---|---|---|
| 美型数据源 | MediaPipe 468 点模型 + 转换链（AI-013 spike 门控，iOS 侧还要复现后处理） | **ARKit 人脸网格（1220 顶点实时，TrueDepth）/ Vision 76 点**——系统能力，零模型管线 |
| 滤镜 | 自写 Portable/MSL LUT 管线 | **Core Image**（GPU 加速、色彩管理白送）+ 需要时自写 Metal |
| 背景/人像 | 自训分割或 AI 分割节点 | **AVDepthData 真实景深**（前后摄均支持）+ Vision 人像分割 |
| 自动构图/前摄 | 自做跟踪裁切 | **Center Stage** 系统能力 |
| 双摄 | PAL 契约抽象后接 MultiCamSession | 直接 `AVCaptureMultiCamSession`（硬件时间戳同步） |
| 性能余量 | 契约层不感知 | **MetalFX 升采样**（A17 Pro+）低分辨率渲染→原生画质 |
| Android 复用 | 契约保证可移植 | 无——届时按 Android 原生重写（CameraX + ML Kit/自训模型） |

结论：相机域的 iOS 优势几乎全部是**平台独有 API**，跨端契约要么把它们剥掉、
要么把平台类型泄漏进契约——两条都违背"扬长避短"。且当前单人开发、Android 排期
在 Phase 3（ADR-0010），为尚未启动的端预付抽象成本不划算。

## 决策

1. **相机模块 = iOS 原生**：Swift + AVFoundation（采集/录制）+ Vision/ARKit（检测）+
   Core Image/Metal（特效渲染），落在 `apps/apple/ios/iOSApp/`（沉淀稳定后可下沉
   SharedUI，仍 iOS 专属）。**不经过 PAL 契约、不新增 C ABI**。
2. **编辑器内核维持 C++ 跨端不动**：本 ADR 只豁免"相机采集→特效→录制"这条
   实时功能域。剪辑业务（时间线/模型/命令/渲染）红线不松动；录制的视频经既有
   `cq_session` 导入路径进时间线，两条管线在此汇合。
3. **红线边界澄清**（不架空红线，划清适用域）：
   - 红线 #1（业务下沉 C++）：相机页的**会话/预览/录制编排**是 UI 功能域实现细节，
     豁免；但"录制产物 → 时间线素材"仍走 Command/Session。
   - 红线 #6（Shader 双层）：管的是 **SDK 的渲染资产**（`shaders/src/` +
     `pal/<platform>/shaders/`）。相机页特效 shader 属 **App 层资产**，不进入
     SDK shader 资产清单；若未来某特效要进 SDK（如时间线滤镜），按红线 #6 重写为
     Portable 先行。ADR-0013 的"欠账记账"对象随 CAM-001 回退而消失。
   - 红线 #3（能力运行时查询）：相机能力直接查询系统能力
     （`isMultiCamSupported` / `@available`），不新增内核能力枚举。
4. **检测路线**（修订 ADR-0005 在相机域的适用）：iOS 相机域直接用 Vision/ARKit
   系统能力，**不引入** MediaPipe 模型管线；AI-013 spike 只服务编辑器域的 AI
   功能（AI-020+），不再是相机的前置。
5. CAM-001 的 `pal/camera.h`、`cq_sdk.h` 相机 ABI 段、三个相机能力枚举**回退删除**；
   保留的工具链兼容修复（log.cpp / test_perf.cpp）与本决策无关，继续有效。

## 后果

- 正面：相机 MVP 交付路径大幅缩短；真深度、人脸网格、Center Stage 等能力可用；
  省掉 AI-013/SHADER-001 两条基建对相机的阻塞。
- 负面/成本：**相机功能对 Android 零复用**（Phase 3 时按 Android 原生重写，
  预估为独立任务群）；相机特效与编辑器特效是两套实现（编辑器特效仍等
  RENDER-001/红线 #6），"相机滤镜"不会自动出现在时间线里。
- 反转条件：Android 阶段启动且产品要求三端相机行为一致 → 届时重新抽契约
  （以两端原生实现的经验为输入抽，比现在凭空抽更准）。

## 落地任务

TASK-CAM-002~005（已按本 ADR 重写为 iOS 原生任务卡）；TASK-CAM-001 标记"已回退"。
