# TASK-AIEDIT-005：Prompt 管线与决策解析/修复

```yaml
id:          AIEDIT-005
layer:       SDK
goal:        FeatureReport + 对话上下文 → Prompt → ILlmClient → EditPlan（校验/自动修复重试 ≤2 → 降级引擎），含增量对话的上下文组装
input:       [AIEDIT-001 契约, AIEDIT-004 客户端, AIEDIT-011 降级引擎(接口), SPEC §6.4/§8, RESEARCH-003 §4.4（决策透明）]
output:      [Prompt 构建器, 响应解析器, 重试/降级编排, 单测（合成特征 + 假 LLM）]
write_set:   core/src/ai/plan/plan_pipeline.{h,cpp}(新: prompt_builder, response_parser, pipeline_orchestrator)、
             core/src/ai/plan/timeline_digest.{h,cpp}(新: ModelSnapshot→时间线摘要)、
             core/tests/test_plan_pipeline.cpp(新)、core/tests/fixtures/ai/prompts/(新)
read_set:    core/include/cq/ai/*, core/src/ai/fallback/*, core/include/cq/model/model_snapshot.h, .ai/modules/ai.md
deps:        [AIEDIT-001, AIEDIT-004, AIEDIT-011]
acceptance:
  - 假 LLM（可编程响应注入）下四路径全过：一次合法响应直通；非法 JSON → 带错误重试 → 成功；重试 2 次仍非法 → 降级引擎接管且 EditPlan.generator=="local_rules"；网络不可达 → 直接降级
  - 增量对话：给定 timeline_rev 不匹配的 plan，pipeline 拒绝应用并触发全量重排请求（断言）
  - Prompt 组装含系统约束（动词集/schema/拒绝浮点秒）且 token 预算 [E] ≤ 6k（3 素材场景，实测回填）；对话历史截断策略（K=6）有断言
  - assistant_message 与逐 action reason 完整透传（决策透明，UI 消费）
  - ctest -R plan_pipeline 全绿
verification:
  - ctest --test-dir build -R plan_pipeline
  - tools/build/build_core.sh --platform=apple
risk:        Prompt 质量决定成片质量但不可机器验收 → 本任务只验"结构正确性"；质量验收走 SPEC §12.4 的 10 组真实素材人工评测（AIEDIT-008 阶段执行）
parallel:    false（批次 3；依赖 004/011 完成）
```

## 背景

管线编排器是"AI 决策"的中枢：所有失败路径最终都收敛到"出一份合法 EditPlan"（无论来自 LLM 还是规则引擎），下游 006/007 不感知来源。

## 实现要点

1. `timeline_digest`：ModelSnapshot → 紧凑文本/JSON 摘要（轨/clip/start/duration/transition），供增量对话；`changes_since`（既有 ABI）用于增量更新摘要。
2. Prompt 模板文件化（`fixtures/ai/prompts/` 亦可作运行时资产模板的单一真源），中文系统提示 + schema 精简描述（不整份塞 schema，注入动词集说明）。
3. 修复重试：把 validator 错误码 + 原响应回传 LLM（"修复以下错误"），≤2 次；每次重试独立计时。
4. 编排器暴露同步语义接口 `GeneratePlan(request, CancelToken)`，内部异步；结果携带 `generator: llm|local_rules` 与诊断信息（重试次数/耗时）。

## 回写

.ai/modules/ai.md 增补管线形状；baselines 回填 token 用量/延迟实测；prompt 迭代记录进 HANDOFF。
