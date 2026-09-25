# ADR-0005：AI 推理共享模型资产，不共享推理 SDK

- **状态**：提案（待批准）
- **日期**：2026-09-23
- **相关**：RESEARCH-001 F8、ARCH-004 §1

## 背景

原方案对 AI 能力的规划是「MediaPipe → CoreML (ANE)」，并把 Vision 65 点不足、MediaPipe 468 点够用的分析做得很扎实（这部分结论保留）。但该规划隐含一个未言明的假设：**MediaPipe 可以作为一个跨端 SDK 集成**。

在 Android 必须支持的前提下这个假设不成立：
- MediaPipe 在 iOS 上走 TFLite，Android 上也是 TFLite，但**鸿蒙没有 TFLite**；
- 完整 MediaPipe SDK 体量巨大，而我们只需要几个模型；
- 各平台最优推理后端本就不同：iOS 是 CoreML (ANE)，Android 是 TFLite(NNAPI/GPU/XNNPACK)，鸿蒙是 MindSpore Lite。

同时核验发现两个被低估的风险（RESEARCH-001 F8）：
1. CoreML 是否真的把模型调度到 ANE **由运行时决定，无法保证**，必须实测；
2. MediaPipe face_landmark 的**模型输出不是可直接使用的 468 个屏幕坐标**，需要复现其 post-processing（含 attention/iris crop 逆变换与 face geometry 的 metric→screen 换算）。这部分工作量原方案完全未计入。

## 决策

### 0. MediaPipe 到底引不引入 —— 明确回答

**SDK 不引入，模型资产引入。** 这是两件事，原表述含糊导致误解，此处明确：

| | 结论 | 理由 |
|---|---|---|
| **MediaPipe SDK**（C++ 框架、calculator graph、官方集成方式） | ❌ **不引入** | ① 体量巨大（完整 SDK 数百 MB，我们只需要几个模型）；② 鸿蒙无 TFLite 支持；③ 各平台有更优后端（CoreML/ANE、NNAPI），MediaPipe 的封装反而绕远；④ 它的 calculator graph 会绑架我们的渲染管线结构 |
| **MediaPipe 的模型文件**（`face_landmark.tflite` 468 点、`face_detection_short_range.tflite`） | ✅ **引入，作为模型资产** | Apache-2.0 协议友好；468 点精度是美颜美型所需（Vision 65 点不够，原调研这个结论正确且采纳） |

所以：**模型要，框架不要。** 我们拿到 `.tflite` 后，在各平台用自己的推理运行时跑：
- iOS/macOS → 首选构建期转 `.mlpackage` → CoreML（力争 ANE）；回退方案见下方 §0.1
- Android → LiteRT(TFLite) 直接跑（NNAPI / GPU / XNNPACK）
- HarmonyOS → MindSpore Lite（P2）

> **术语**：Google 已把 TensorFlow Lite 更名为 **LiteRT**，官方文档与 API 名称逐步切换。本文与工程内统一写作
> **LiteRT（原 TensorFlow Lite）**，`.tflite` 作为**文件格式名**保持不变（不叫 `.litert`）。

### 0.1 Apple 端的两条路径 —— 必须实测，不得假定

ADR 第一版只写了「转 `.mlpackage`」一条路，这是**未经核实就选定的路径**。核验后 Apple 端实际有两条：

| | 路径 A：构建期转换 | 路径 B：运行时 delegate |
|---|---|---|
| 做法 | `coremltools` 把 `.tflite` 转成 `.mlpackage`，只随包发 `.mlpackage` | 直接随包发 `.tflite`，用 **LiteRT 的 CoreML delegate** 跑 |
| 运行时依赖 | **零第三方**，纯系统 CoreML | 需引入 LiteRT 运行时（体积 + 依赖登记） |
| ANE | `MLModelConfiguration.computeUnits` 可显式声明，但**是否真落 ANE 仍由系统决定** | delegate 默认仅在 **A12 及以上**（iPhone XS 及以后）创建，较老设备自动回退 CPU |
| 精度 | FP16 / INT8 可脚本化控制 | 官方说明仅支持 **FP32 / FP16** 浮点模型 |
| 主要风险 | `coremltools` 对 `.tflite` 的输入支持**不是官方文档主列的 source framework**（官方主列 PyTorch / TF2 SavedModel / TF1 Frozen Graph / ONNX），算子覆盖与数值一致性必须实测 | 多一个第三方运行时；与「不共享推理 SDK」不冲突（仍是各端自选后端），但依赖治理成本上升 |
| 体积 | 只发一份模型 | 模型 + 运行时 |

**选择：以路径 A 为目标方案，路径 B 为已核准回退。** 理由是 A 在 Apple 端运行时零第三方依赖，符合「iOS/macOS 重点支持 + 最小第三方面」；
但 A 的可行性**必须先用 spike 验证**（`AI-013`），不得边写业务边发现转不动。验证通过前，路径 B 视为随时可切换。

**Spike 判定标准（`AI-013`，一次性、不写业务代码）**：
1. `ct.convert()` 能吃进 `face_landmark.tflite` 与 `face_detection_short_range.tflite` 并产出 `.mlpackage`；
2. 转换后与 LiteRT 原始输出做**数值比对**，逐点误差在容忍阈值内（阈值由 spike 产出并写入 `.ai/memory/baselines.md`）；
3. 该 `.mlpackage` 在目标设备上能跑通，并实测**是否落在 ANE**（对应 `AI-002`）。

任一条不通过 → 立即切路径 B，并在本 ADR 追加修订记录。

### 1. 共享的是模型资产，不是推理 SDK
   - 模型文件纳入 `third_party/models/manifest.toml`，登记来源、许可、SHA-256、输入输出张量规格、实测耗时。
   - **模型是依赖，按依赖治理**（ARCH-002 §7.1）。
2. **统一 `IInferenceBackend` 抽象**，各平台实现：
   - Apple → CoreML
   - Android → TFLite
   - HarmonyOS → MindSpore Lite
3. **后处理逻辑在 C++ 内核实现并共享**（landmark 后处理、坐标变换、帧间平滑），不依赖任何推理 SDK。这是保证三端结果一致的关键。
4. **模型转换是构建期产物，纳入 CI**：`.tflite → .mlpackage` 用 coremltools 脚本化，转换失败必须构建失败，不允许手工转换后提交二进制。
   **前置条件：`AI-013` spike 必须先通过**（见 §0.1）；spike 未过不得把转换链设为 CI 必过项。转换链必须在 `manifest.toml` 中登记 coremltools 版本，版本敏感是已知风险。
5. **能力查询与降级**：`CQ_CAP_NPU_INFERENCE` 返回 yes/no/degraded；NNAPI 在 Android 上碎片化严重，必须有 XNNPACK(CPU) 回退。
6. **美型实现同一接口**：Mesh Warp 与 UV Offset Map 是同一 `RenderNode` 接口的两个实现，切换不换调用方（对应 RESEARCH-001 C5）。

## 备选方案

| 方案 | 否决理由 |
|---|---|
| 跨端集成 MediaPipe **SDK** | 鸿蒙无支持；体积巨大；无法利用各平台最优后端；calculator graph 会绑架管线结构 |
| 连 MediaPipe **模型**也不要，完全自训 | 自训需要数据集与周期，MVP 阶段不现实；468 点模型的精度已满足需求 |
| 各端独立实现 AI 能力 | 三端结果不一致；后处理逻辑重复三遍 |
| 只用 Vision（Apple） | 65 点不足以做精细美型（原调研结论，采纳）；且 Android 无对应物 |

## 后果

**正面**
- 三端共享后处理逻辑，结果一致性有保证
- 各端能用上最优硬件加速（ANE / NNAPI / NPU）
- 模型可独立升级，不受 SDK 版本绑定

**负面 / 成本**
- 模型转换链条需要脚本化与 CI 化（coremltools 版本敏感），且**转换可行性本身尚未验证**（`AI-013`）
- MediaPipe landmark 后处理需要自己复现 —— **这是被原方案遗漏的工作量，必须单独估期**
- 多后端意味着多套降级路径需要测试覆盖
- 路径 B（LiteRT + CoreML delegate）作为回退保留，意味着 Apple 端存在「引入一个第三方运行时」的可能性，需预留依赖登记与体积预算

## 修订记录

| 版本 | 日期 | 修订内容 |
|---|---|---|
| v1 | 2026-09-23 | 初稿：共享模型资产，不共享推理 SDK |
| v1.1 | 2026-09-23 | 补 §决策 0「MediaPipe 到底引不引入」明确回答；补 §0.1 Apple 端双路径（A 转换 / B delegate）与回退条件；统一 LiteRT 术语 |

## 反转条件

- 出现一个真正跨三端且性能不劣于原生后端的推理运行时；
- ANE 实测不可用且 CoreML GPU 路径性能不达标 → 需重新评估 iOS 端模型方案；
- **`.tflite → .mlpackage` 转换链 spike 未通过 → 切换路径 B（LiteRT + CoreML delegate）**，并重新评估 Apple 端运行时依赖与体积预算。

## 落地任务
`AI-0xx`（推理抽象与后端）、`AI-1xx`（landmark 后处理与美颜美型）、`AI-013`（转换链可行性 spike，**最优先**）
