# TASK-AIEDIT-011：本地规则引擎降级（离线成片）

```yaml
id:          AIEDIT-011
layer:       SDK
goal:        无网/无 key/LLM 三连失败时的本地成片引擎：静音剔除 + 质量排序 + 高光优先 + 固定节奏模板 → 合法 EditPlan（generator=local_rules）
input:       [AIEDIT-001 契约, SPEC §8 降级段, RESEARCH-003 §2.2（iMovie 离线对标）/§4.6, ADR-0016 决策 6]
output:      [规则引擎实现, 单测, 与 005 编排器的接缝]
write_set:   core/src/ai/fallback/*(新: rule_engine.{h,cpp}, rhythm_template.{h,cpp})、
             core/tests/test_rule_engine.cpp(新)、core/CMakeLists.txt(登记)
read_set:    core/include/cq/ai/feature_report.h, core/src/ai/plan/*, .ai/modules/ai.md
deps:        [AIEDIT-001]
acceptance:
  - 相同 FeatureReport 输入 → 输出确定性相同（规则引擎无随机性，同输入同输出断言）
  - 输出 plan 通过 001 校验器（零非法）；总时长 ∈ [预期区间]（节奏模板约束断言）
  - 静音剔除：含 3 段已知静音的样本，成片不含静音段（shot 边界断言）
  - 质量排序：高质量 shot 位于成片头部（高光优先断言）；audio 特征缺席（003 未合入）时退化为纯视觉排序仍出合法 plan
  - ctest -R rule_engine 全绿
verification:
  - ctest --test-dir build -R rule_engine
  - tools/build/build_core.sh --platform=apple
risk:        规则成片观感机械 → 模板参数（节奏/片长比例）集中可调；本任务只保"可用"，不追"好看"（好看是 LLM 路线的职责）
parallel:    true（批次 2；建议排在 002 后启动以便用真特征调试，依赖上仅 001）
```

## 背景

ADR-0016 决策 6 的落地：能力缺失降级是红线精神（中端机也可能缺能力，同理断网/无 key 不是少数场景）。规则引擎与 LLM 走同一条校验/执行链（005/006 不感知来源）。

## 实现要点

1. 管线：剔除（静音/低质 shot）→ 排序（质量×运动×人脸加权，特征缺席项权重归零）→ 模板节奏（快-慢-快，目标片长 = 素材 30%~50% [E] 可调）→ 输出 EditPlan。
2. `rhythm_template` 独立纯函数（输入 shot 列表 + 目标时长 → 时间线骨架），可单测。
3. 输出携带逐段 reason（"剔除：静音占比 92%""开场：质量 0.86 最高"）——离线模式也保持决策透明。

## 回写

.ai/modules/ai.md 增补 fallback 节；baselines 回填单素材成片耗时。
