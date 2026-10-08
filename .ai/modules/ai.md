# 模块：AI 推理与智能效果

> **归属**：A/C 分子域（智能成片 AIEDIT→A；端侧推理效果链→C） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

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

---

# 智能成片管线（2026-10-04 立项；ADR-0020 / SPEC AIEDIT-001 / TASK-AIEDIT-000）

> 全仓首个大模型接入域。与"端侧推理效果链"（上文）是**两个独立子域**：
> 上文 = 帧级实时效果（人脸/磨皮），本节 = 素材级离线理解与决策。

## 分层（ADR-0020 决策 2）

```
core/include/cq/ai/     feature_report.h / edit_plan.h / llm_client.h   ← 契约（AIEDIT-001 冻结）
core/include/cq/pal/    net.h（INetTransport 抽象）
core/src/ai/analysis/   视觉特征（镜头/运动/质量，P0 零模型）             ← AIEDIT-002
core/src/ai/audio_analysis/  音频特征（静音/LUFS/包络，需解码扩档）      ← AIEDIT-003
core/src/ai/plan/       EditPlan 校验器 / Prompt 管线 / timeline 摘要    ← AIEDIT-001/005
core/src/ai/llm/        OpenAI-compatible 客户端（纯 C++）               ← AIEDIT-004
core/src/ai/fallback/   本地规则引擎（离线降级，同 schema 输出）          ← AIEDIT-011
core/src/ai/plan/plan_executor  EditPlan→Command 批次                    ← AIEDIT-006
pal/apple/net/          URLSession + SSE（零第三方）                     ← AIEDIT-004
```

## 硬规则（违反即 PR 驳回）

1. **原始素材默认不出设备**：上云只有 FeatureReport（KB 级聚合统计）+ 用户消息；人脸只报 count/area_ratio 布尔级，不做识别。
2. **LLM 输出 = EditPlan（`cq.editplan/1`）action 列表**，动词集 9 个封顶（SPEC §6.1 行文"八个"系笔误，枚举清单为准，2026-10-08 冻结时裁定）；时间字段一律 `{value, timescale}` 且 `timescale==120000`，浮点秒一律非法；未知 schema 版本拒绝并降级，不猜测解析。
3. **C++ 校验器是唯一权威**（schema + 引用 + 时间线合法性）；修复重试 ≤2 → 规则引擎降级（`generator: local_rules`）。
4. **AI 产物全走 Command**（与人手同一撤销栈，批次原子可撤销）；禁止 AI 链路直接改 ModelSnapshot。
5. 供应商可插拔（OpenAI-compatible 协议收敛），key 不落盘明文（Keychain，绑定层职责）。

## 与既有设施的关系

- 特征取帧走 FrameProvider（精确 seek），分析管线全程后台 + CancelToken。
- 人脸特征 P0 置 null；AI-010 模型就绪后经能力查询运行时替换（不走 `#if`）。
- 导出（EXPORT-001 未做）与 BGM 命令是 P0.5 缺口，P0 的"导出"按钮置灰。

## 验证
```bash
ctest -R "edit_plan|visual_analyzer|audio_analysis|llm_client|plan_pipeline|plan_executor|rule_engine|c_abi_ai"
tools/build/build_core.sh --platform=apple
```

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| Task ID | 标题 | 状态 |
|---|---|---|
| AIEDIT-001 | 智能成片契约冻结（FeatureReport/EditPlan/ILlmClient/INetTransport + 校验器） | **编码完成（2026-10-08）**：本机 clang13 直编单测 117 检查 0 失败（golden 58 例：合法 18/18、非法 40/40 错误码精确匹配）；**构建机门禁未跑 = 池[8]** |
| AIEDIT-002~011 | 其余管线卡 | 未开工（002/004/005/011 依赖 001 已解，可排期） |
| AIEDIT-012~015 | 号段 | 预占 |

### AIEDIT-001 落地形状（2026-10-08；下游卡开工前必读）

- **契约头**：`engine/core/include/cq/ai/{feature_report.h, edit_plan.h, llm_client.h}` +
  `engine/core/include/cq/pal/net.h`（INetTransport/SSE 拆帧边界冻结：空行分事件、剥
  data: 前缀、跳注释行，"[DONE]" 哨兵原样送达）。
- **动词集按 9 个冻结**（select_intro/highlight/outro + place_clip/remove_range/trim_clip/
  reorder + set_transition/set_bgm_placeholder）——SPEC §6.1 行文"八个"系笔误，两处枚举
  清单一致按 9 落（见 edit_plan.h 文件头注记）。op 名 ↔ 枚举映射实现在
  edit_plan_validator.cpp（`namespace cq` 直层，与头声明一致）。
- **校验器**：`engine/core/src/ai/plan/edit_plan_validator.{h,cpp}`（内核私有头，不进
  PUBLIC include）。三层：手写 RFC 8259 JSON 解析（转义/代理对/无尾逗号/无前导零/嵌套
  深度 64 上限/int64 溢出检测）→ 结构（schema/必填/类型/per-op 字段齐全）→ 语义
  （引用/值域/__int128 防溢出边界/段重叠/排列）。浮点秒两种形态（直接浮点与对象内
  浮点）都在形状检查**前**识别为 kAiPlanFloatTime。
- **错误码**：status.h 9500~9513（kAiPlan* 段）+ StatusCategory::kAiPlan(11)；码值
  static_assert 锁定，manifest.txt 按码名断言。
- **宽松策略**：未知**字段**忽略（向前兼容），未知 **op/转场/schema 版本**拒绝——
  扩展必须走 schema 版本号，不走私加字段。校验器无时间线上下文，trim/remove 落点
  校验归执行器（AIEDIT-006）。
- **golden**：`engine/core/src/ai/plan/edit_plan_golden/`（58 例 + manifest.txt 增量
  登记处，append-only；生成脚本已删防覆盖手加用例）。测试目标 cq_tests_ai_edit_plan
  需 `-I engine/core/src`（私有头）。
- **EditPlanAction 用 has_asset/has_shot 存在性标志**（与空串/缺省区分）——下游执行器
  判字段时用 has_*，不要用字符串空判。

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| 2026-10-08 | AIEDIT-001 单测（本机 clang 13 直编最小组合：validator + status + test，非 ctest 通道） | 117 检查 0 失败：golden 合法 18/18、非法 40/40（错误码按码名精确匹配）；编译零警告（-Wall -Wextra -Wconversion -Wshadow -Wold-style-cast）；**build_core.sh / ctest -R ai_edit_plan 未跑（本机无 cmake/ninja）= 池[8]** |

### 调研 · 决策 · 池指针

- ADR-0020/0005 · RESEARCH-003/RESEARCH-001 F8 · SPEC-AIEDIT-001

- HANDOFF-017（2026-10-08）：AIEDIT-001 编码完成、构建机门禁未跑（池 [8]）；后续卡承接见 `docs/tasks/TASK-AIEDIT-001.md`「冻结裁定」。
