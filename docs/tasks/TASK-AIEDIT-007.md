# TASK-AIEDIT-007：C ABI 扩展与 Swift 绑定（Integrator）

```yaml
id:          AIEDIT-007
layer:       SDK
goal:        将 002/004/005/006/011 的能力以 C ABI 暴露并接通 Swift 绑定，形成"analyze → generate → apply"可调用链
input:       [AIEDIT-001 契约, AIEDIT-002/004/005/006/011 产物, ADR-0020, .ai/modules/session.md（observer 模式）]
output:      [cq_sdk.h 新函数组, Swift 绑定, C ABI 测试, SharedUI 侧可消费的句柄/回调]
write_set:   core/include/cq/cq_sdk.h(高冲突——独占批次)、core/src/abi/(新文件 ai 段)、
             bindings/swift/Source/(新 AiPlan.swift 等)、bindings 测试、core/tests/test_c_abi_ai.c(新)
read_set:    core/include/cq/ai/*, core/src/ai/*, pal/apple/net/*, bindings/swift/*, docs/decisions/ADR-0012
deps:        [AIEDIT-002, AIEDIT-004, AIEDIT-005, AIEDIT-006]
acceptance:
  - 新 C ABI 函数组（命名 cq_ai_*）：analyze_assets / generate_plan / apply_plan / cancel / llm_config_set / progress_observer —— 全部 opaque 句柄 + C 类型，零平台类型（红线 2/7 grep 审查）
  - 异步交付走既有 task_runner/observer 模式（对照 cq_session_submit 风格），回调线程有断言
  - 003/011 未就绪能力：ABI 返回 CQ_STATUS_UNAVAILABLE 而非崩溃（软依赖声明）
  - ctest -R c_abi_ai 全绿；bindings swift test 全绿；build_core.sh -Werror 通过
verification:
  - ctest --test-dir build -R c_abi_ai
  - swift test（bindings + SharedUI）
  - tools/build/build_core.sh --platform=apple
risk:        cq_sdk.h 高冲突（ Integrator 性质独占批次）；ABI 设计错 → 回调泄漏 → 进度 observer 显式 destroy 语义 + 泄漏断言
parallel:    false（批次 4，独占）
```

## 背景

UI（008/009）只经 C ABI 触达内核。本任务是 Integrator 性质的汇聚点：把批次 2/3 的 core 能力冻结为稳定 ABI。

## 实现要点

1. 进度/结果双 observer：analyze 进度（0~100 分素材粒度）、generate 完成（plan JSON + generator 标注）、apply 完成（批次 id + snapshot rev）。
2. plan 以 JSON 字符串跨 ABI 传递（校验后的 canonical 形式），Swift 侧不解析结构、只透传 UI 展示（reason 列表展示需要轻量读取——提供 `cq_ai_plan_narrative_get` 读 narrative 字段，Swift 不做 JSON 深解析）。
3. 新增 Swift 文件后必须 `pod install`（pitfalls P34 的既有坑，写进任务步骤）。

## 回写

.ai/modules/session.md 或新建 ai ABI 小节；HANDOFF 记录 ABI 函数清单。
