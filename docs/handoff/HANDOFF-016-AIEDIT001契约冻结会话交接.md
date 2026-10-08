# HANDOFF-016：AIEDIT-001 契约冻结收口会话交接（2026-10-08）

> 接手人开第一步前**必读本文件 + `.ai/modules/ai.md`「AIEDIT-001 落地形状」节**。
> 本轮 = 编辑域查进度后转开工 A 线 AIEDIT 智能成片（UIA-028~031 全被
> C 线地基卡死：LIB-002/005、PROJ-005、RENDER-011、EXPORT-001 全未开工）。

## 当前状态（对着工作区 commit 核过）

- **AIEDIT-001（智能成片契约冻结）：编码完成**。四契约头 + 校验器 + 58 例 golden +
  单测 + CMake 登记，全部落盘待提交（本条写就时 commit 尚未推，见 git log）。
- **验证状态**：本机 clang 13 直编最小组合跑过（117 检查 0 失败：合法 18/18、
  非法 40/40 错误码精确匹配）；**ctest 通道与 build_core.sh 未跑**（本机无
  cmake/ninja）= 池 [8]，构建机第一优先。
- 编辑域 UIA-032~038 全部编码完（037/038 验证挂池 [6]），无新活。

## 交付物地图（全在 engine/core 与 tests）

| 文件 | 内容 |
|---|---|
| `engine/core/include/cq/ai/feature_report.h` | cq.featurereport/1 类型（聚合统计，上云唯一载荷） |
| `engine/core/include/cq/ai/edit_plan.h` | cq.editplan/1 类型 + 动词集 9 + op/转场名映射声明 |
| `engine/core/include/cq/ai/llm_client.h` | ILlmClient / LlmConfig（key 引用不落明文） |
| `engine/core/include/cq/pal/net.h` | INetTransport（PostJson/PostSse）+ SSE 拆帧边界 |
| `engine/core/include/cq/base/status.h` | +kAiPlan* 段 9500~9513 + 分类 11（只追加） |
| `engine/core/src/ai/plan/edit_plan_validator.{h,cpp}` | 三层校验：手写 JSON → 结构 → 语义（私有头） |
| `engine/core/src/ai/plan/edit_plan_golden/` | 58 JSON 夹具 + manifest.txt（append-only） |
| `tests/unit/test_edit_plan_validator.cpp` | manifest 驱动 + 码值 static_assert + 往返 |

## 下一步（按序）

1. **池 [8]**：构建机 cmake 配置 + `build_core.sh --platform=apple`（-Werror）+
   `ctest -R ai_edit_plan`；本机直编已绿，风险点只在 CMake 注册（测试目标需要
   `-I engine/core/src` 拿私有头，tests/CMakeLists 已写）。
2. **AIEDIT 下一批（依赖 001 已解，可并行排）**：
   - AIEDIT-002 视觉特征（消费 feature_report.h，产出方）
   - AIEDIT-004 ILlmClient 实现 + pal/apple/net（消费 net.h/llm_client.h）
   - AIEDIT-011 本地规则引擎（输出同 schema EditPlan，generator="local_rules"）
   - AIEDIT-005 依赖 004+011；AIEDIT-006 依赖 001 可先行（command.h 批次内独占）
3. 真机无涉（纯 C++ 契约层）。

## 冻结裁定与坑（下游卡开工前必读）

- **动词集 = 9 个**（SPEC §6.1 行文"八个"系笔误；select×3 + 落地×6，枚举清单为准）。
  模块册硬规则第 2 条已同步修正。
- **浮点秒双形态拦截**：`"timeline_start": 0.5`（直接浮点）与
  `{"value": 0.5}`（对象内浮点）都必须报 `kAiPlanFloatTime`——形状检查之前识别。
- **宽松/严格分界**：未知**字段**忽略；未知 **op / 转场 / schema 版本**拒绝。
  扩展走 schema 版本号，不走私加字段。
- **校验器无时间线上下文**：trim_clip/remove_range/set_transition 对真实时间线的
  落点校验归执行器 AIEDIT-006。
- **EditPlanAction 用 has_asset/has_shot 等存在性标志**判字段，别用空串/缺省值判。
- op/转场名映射实现在 validator.cpp 的 `namespace cq` 直层（与头声明一致）——
  曾放 `namespace cq::ai` 里导致歧义调用，已修；下游别再犯。
- golden 的 gen_cases.py 用后即删：manifest.txt 是 append-only 真源，防再生成覆盖。
- 任务卡/模块册行文 `core/` = 仓库实际 `engine/core/`（全仓简写约定，非漂移）。

## 记录索引

- 模块册：`.ai/modules/ai.md`（任务表 + AIEDIT-001 落地形状 + 门禁记录 2026-10-08 行）
- 任务卡：`docs/tasks/TASK-AIEDIT-001.md`（进度表 + 实际写集 + 冻结裁定）
- 池：`docs/tasks/TODO-POOL-门禁真机待办池.md` [8]
- baselines：`.ai/memory/baselines.md`「AIEDIT-001」段（零性能基线，如实记）
- Spec/ADR：`docs/specs/AIEDIT-001-智能成片.md` §4-§7 / ADR-0020
