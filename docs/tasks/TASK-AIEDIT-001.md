# TASK-AIEDIT-001：智能成片契约冻结（FeatureReport / EditPlan / LLM 接口 + 校验器）

```yaml
id:          AIEDIT-001
layer:       SDK
goal:        冻结智能成批次的全部跨任务契约：FeatureReport/EditPlan JSON schema、ILlmClient/INetTransport 抽象头，并交付 EditPlan 校验器
input:       [SPEC AIEDIT-001 §4-§7, ADR-0020 决策 2/3/7, .ai/modules/ai.md, core/include/cq/pal/inference.h（接口风格参照）]
output:      [契约头文件, EditPlan 校验器实现, golden 样例集, 单测, 模块文档更新]
write_set:   core/include/cq/ai/{feature_report.h, edit_plan.h, llm_client.h}(新)、
             core/include/cq/pal/net.h(新)、core/src/ai/plan/edit_plan_validator.{h,cpp}(新)、
             core/src/ai/plan/edit_plan_golden/(新, JSON 夹具)、core/tests/test_edit_plan_validator.cpp(新)、
             core/CMakeLists.txt(登记新文件)
read_set:    core/include/cq/base/{time.h,status.h}, core/include/cq/pal/inference.h, docs/decisions/ADR-0009
deps:        []
acceptance:
  - 校验器 golden 样例集 ≥ 40 例全过：合法 plan 全接受；非法样例（浮点秒时间/越界 source_in/未知 asset/重叠段/未知 schema 版本/未知 op）全拒绝且错误码精确
  - `timescale != 120000` 的时间对象判非法；任何浮点秒字段判非法（红线 4 的机器检查）
  - ILlmClient/INetTransport 头文件零平台类型、零第三方类型（红线 2/7，grep 审查）
  - ctest -R edit_plan 全绿；build_core.sh --platform=apple -Werror 通过
verification:
  - ctest --test-dir build -R edit_plan
  - tools/build/build_core.sh --platform=apple
  - grep -rn "double\|float" core/include/cq/ai/ | grep -iv "ratio\|score\|motion\|quality\|lufs" # 仅统计类字段允许浮点，时间字段不允许
risk:        schema 冻结后变更成本高 → 设计 `extensions{}` 扩展位 + schema 版本字段，校验器对未知版本"拒绝并降级"而非崩溃
parallel:    false（批次 1，先行）
```

## 背景

ADR-0020 决策 3：LLM 输出必须是有界动词集的 `EditPlan`，C++ 是唯一权威校验方。本任务是全批次的地基——002~011 全部消费这里冻结的类型。

## 实现要点

1. **类型分层**：`feature_report.h`/`edit_plan.h` 是**纯 POD + 解析/序列化**（hand-written JSON 解析，参照 core 现状不引 nlohmann——若引库走 dependency-governance 另议，P0 手写）；`llm_client.h`/`net.h` 是**抽象接口**（风格对齐 `pal/inference.h`：CancelToken、纯虚、工厂、opaque 句柄）。
2. EditPlan 动词集 P0 八个：`select_intro/select_highlight/select_outro/place_clip/remove_range/trim_clip/reorder/set_transition/set_bgm_placeholder`（见 Spec §6.1）；`op` 未知值非法。
3. 校验器错误码进 `cq_status` 语义域（新增 `CQ_AI_PLAN_*` 段，登记在 base/status.h 注释表——**只加注释与枚举值，不动既有段**）。
4. golden 夹具放 `core/src/ai/plan/edit_plan_golden/`（JSON 文本，每例 ≤ 2KB，登记清单文件便于增量）。

## 验收

逐条对应 acceptance；`ctest -R edit_plan` 输出样例计数（≥40 passed, 0 failed）。

## 回写

- `.ai/modules/ai.md` 增补"智能成片管线"节（schema 位置、动词集、扩展位规则）。
- 实测数据（无）→ 在 baselines.md 标"未实测，P0 联调后回填"。

## 进度（2026-10-08 回写）

**状态：编码完成，构建机门禁未跑（池[8]）**

| 子步骤 | 状态 | 证据 |
|---|---|---|
| 契约头 feature_report.h / edit_plan.h / llm_client.h / pal/net.h | ✅ | 四头 include smoke 过 clang13 项目警告集零警告 |
| 错误码 CQ_AI_PLAN_* 段 | ✅ | status.h 9500~9513 + kAiPlan 分类(11)，码值 static_assert 锁定 |
| EditPlan 校验器（JSON 解析/结构/语义三层） | ✅ | edit_plan_validator.{h,cpp}；浮点秒双形态拦截 |
| golden 样例集 | ✅ 58 例（验收 ≥40） | 合法 18 + 非法 40，manifest.txt 增量登记 |
| 单测 | ✅ 本机 | clang13 直编：117 检查 0 失败（非法 40/40 错误码按码名精确匹配） |
| ctest -R edit_plan（ctest 通道） | ❌ 未跑 | 本机无 cmake/ninja；CMake 已登记（测试名 ai_edit_plan）= 池[8] |
| build_core.sh -Werror | ❌ 未跑 | 同上（新增 TU 已过等价警告集自证）= 池[8] |

实际写集（任务卡写 core/，按仓库实际落 engine/core/，两 CMake 例外为登记必需）：

- engine/core/include/cq/ai/{feature_report.h, edit_plan.h, llm_client.h}（新）
- engine/core/include/cq/pal/net.h（新）
- engine/core/include/cq/base/status.h、engine/core/src/base/status.cpp（追加 AI 段，不动既有段）
- engine/core/src/ai/plan/edit_plan_validator.{h,cpp}（新）
- engine/core/src/ai/plan/edit_plan_golden/（新：58 JSON + manifest.txt；生成脚本用后即删）
- tests/unit/test_edit_plan_validator.cpp（新）
- engine/core/CMakeLists.txt、tests/CMakeLists.txt（源/测试登记）

冻结裁定（下游卡注意）：动词集按 **9** 个（SPEC 行文"八个"系笔误）；校验器不做
时间线落点校验（归 AIEDIT-006）；未知字段忽略 / 未知 op·schema 拒绝；EditPlanAction
字段存在性用 has_* 标志判。详见 `.ai/modules/ai.md`「AIEDIT-001 落地形状」。
