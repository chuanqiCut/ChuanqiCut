# 模块：AI 推理与智能效果

**边界**：`core/src/ai/`、`core/include/cq/infer/`、`pal/<platform>/infer_*`

## MediaPipe 引不引入？（常被问，明确回答）

| | 结论 |
|---|---|
| **MediaPipe SDK** | ❌ **不引入**。体积大、鸿蒙无支持、各平台有更优后端、calculator graph 会绑架管线结构 |
| **MediaPipe 模型文件**（`face_landmark.tflite` 468 点、`face_detection_short_range.tflite`） | ✅ **引入**，Apache-2.0 |

**模型要，框架不要。** 拿 `.tflite` 后各平台用自己的运行时跑：
iOS/macOS 转 `.mlpackage` 走 CoreML（路径 A，另有回退路径 B）；Android 直接 LiteRT；鸿蒙 MindSpore Lite（P2）。

### 术语（别混）
- **`.tflite` 是文件格式**（FlatBuffer：算子图 + 权重 + 元数据），是静态资产，自己跑不起来。
- **LiteRT 是运行时**（Google 已把 TensorFlow Lite 更名 LiteRT），提供解释器 + 算子内核 + delegate。
- 两者不是一回事。我们引入的是**前者**；后者是否引入取决于 Apple 端走哪条路径。

### Apple 端双路径（ADR-0005 §0.1）
| | A 构建期转换（目标方案） | B 运行时 delegate（回退） |
|---|---|---|
| 做法 | `coremltools` 转 `.mlpackage`，只发 `.mlpackage` | 发 `.tflite`，用 LiteRT 的 CoreML delegate 跑 |
| 运行时依赖 | 零第三方 | 需引入 LiteRT 运行时 |
| ANE | `computeUnits` 可声明，仍由系统决定 | 默认仅 A12+ 创建 delegate，老设备回退 CPU |
| 精度 | FP16 / INT8 可脚本控制 | 官方仅支持 FP32 / FP16 |

**AI-013 spike 必须先过**（转得出 / 数值对得上 / 跑得通），不过就切 B，不许边写业务边试。

## 核心决策：共享模型资产，不共享推理 SDK（ADR-0005）

| 平台 | 后端 |
|---|---|
| Apple | CoreML（力争 ANE） |
| Android | TFLite（NNAPI / GPU / XNNPACK 回退） |
| HarmonyOS | MindSpore Lite（P2） |

模型文件纳入 `third_party/models/manifest.toml`（来源、许可、SHA-256、张量规格、实测耗时）。**模型是依赖，不是资源。**

## 被原方案低估的两个风险（RESEARCH-001 F8）
1. **CoreML 是否真的跑在 ANE 上无法保证**，由运行时决定 → 必须实测（`AI-002`），不成立则记录回退方案。原调研"~0.5ms ANE"属于未验证估算。
2. **MediaPipe landmark 的模型输出不是可直接使用的 468 个屏幕坐标** → 必须自己实现后处理（含 attention/iris crop 逆变换、face geometry 的 metric→screen 换算）。这部分工作量原方案完全未计入。

## 硬约束
1. **后处理逻辑在 C++ 实现并跨端共享**（这是三端结果一致的关键）
2. 模型转换（.tflite → .mlpackage）**脚本化并纳入 CI**，禁止手工转换后提交二进制
3. 能力查询 `CQ_CAP_NPU_INFERENCE`，必须支持 CPU 回退（NNAPI 碎片化严重）
4. 美型 MeshWarp 与 UV Offset Map 同一接口，可切换

## 效果清单
人脸检测 → landmark（+后处理）→ 帧间平滑 → 磨皮（频率分解）/ 美型 / 抠像（Chroma Key + AI 分割）

## 验证
```bash
ctest -R ai_landmark_post     # 后处理正确性
ctest -R ai_smooth            # 帧间抖动抑制
tools/qa/golden_compare.sh --case=beauty
tools/perf/infer_bench --model=<m>   # 实测耗时与是否命中 NPU
```

## 相关
ADR-0005、ARCH-004 §1
