# TASK-MODEL-003：效果属性系统（B0 渲染地基第二块）

> **状态：🔧 代码完成 + 单测全绿；真机问卷未回收，不标记完成**（2026-10-12）。
> ctest：Debug **51/51**、Release **51/51**（含本任务 `model_property` 179 checks /
> `c_abi_property` 76 checks，0 failures）。全量 `run_gate.sh` 未跑（须传哲同意）。

```yaml
id:          MODEL-003
layer:       跨平台
goal:        效果属性即数据：属性值/属性袋/效果栈挂到 ChqClip；属性变更走 Command
             （红线 #5）；最小 C ABI 暴露（add/remove/enabled + 五类参数 setter +
             两段式查询）；digest 覆盖效果栈。渲染消费归 RENDER-011，本卡不应用效果
input:       [.ai/modules/model.md（EffectBinding 数据模型条目）, 红线 #4/#5,
             ADR-0034（B0 批次纪律）, tools/platform/check_platform_headers.py 契约头规则]
output:      [cq/model/chq_property.{h,cpp}(新), chq_timeline.{h,cpp}(挂栈+7方法),
             chq_command.{h,cpp}(4命令), chq_editor_model_state.cpp(指纹),
             chq_editor_session.{h,cpp}(4 Submit*), cq_sdk.{h,cpp}(11 ABI+2结构体),
             tests/unit/test_model_property.cpp(新), tests/unit/test_c_abi_property.c(新)]
write_set:   engine/core/cq/model/*、engine/core/cq/command/*、engine/core/cq/session/*、
             engine/core/cq/cq_sdk.{h,cpp}、engine/core/CMakeLists.txt、
             tests/unit/test_model_property.cpp(新)、tests/unit/test_c_abi_property.c(新)、
             tests/CMakeLists.txt、tests/unit/test_model_command.cpp(指纹覆盖)
read_set:    cq/base/*、cq/media/chq_asset_registry.h、tools/platform/check_platform_headers.py
deps:        [MODEL-001, MODEL-002, UIA-009 子步骤 1]
acceptance:
  - 属性值类型安全读取（不猜不转）；空 key 拒绝；五类工厂（i64/float/bool/color/vec2）
  - 属性袋指纹与插入顺序无关（std::map 保序；换 unordered_map 会漂 → 单测锁定）
  - 效果栈保序（顺序即渲染顺序）；重复 effect_id 拒绝；移除不影响其余相对顺序
  - 时间线分码：clip 缺失 kInvalidArgument / 效果缺失 kIoNotFound
  - 四条命令 Do/Undo/Redo；「新建参数」撤销走擦除（不留幽灵参数）；
    失败命令不入栈不清 redo；50 深往返后指纹回初始态
  - digest 真断言：改参数/改启用位 → 指纹变；同值 set → 指纹不变（内容语义）
  - 属性命令不碰轨级 enabled/muted（与音频线约束正交）
  - C ABI 端到端：异步提交语义 + DrainAfter 同步 + 两段式查询 + undo 整栈还原
  - 契约头门禁 PASS（标量用 float 不用 double，见下）
verification:
  - tools/build/build_core.sh --platform=apple --config=Debug   # 0 error 0 warning
  - tools/build/build_core.sh --platform=apple --config=Release
  - ctest --test-dir build -R model_property   # 179 checks
  - ctest --test-dir build -R c_abi_property   # 76 checks
risk:        效果目录（哪些 effect_id 存在/默认参数）未定义（EFFECT-001）；UI 无属性面板，
             C ABI 的消费方是测试而非 App（与 set_canvas 等同批先例一致）；
             Swift 绑定未同步（既有惯例：BIND-001 之后的 ABI 增长不进 Swift 层）
parallel:    true（与 RENDER-001/SHADER-001 写集不相交）
```

## 两个关键纪律（评审时先看这两条）

1. **标量用 `float` 不用 `double`**：`tools/platform/check_platform_headers.py` 对
   `model/`（以及 `cq_sdk.h` 本身）禁 `double` token。本卡**没有改门禁脚本** ——
   与 `platform/chq_gfx.h` 的 `clear_color[4]` / `SetViewport(float)` 同一先例：
   非时间量允许浮点，时间永远不进属性（红线 #4 的前提）。
2. **效果应用不进 B0**：装配器对带**启用**效果的片段如实上报 `effects_dropped`
   （Warn，Release 可见），消费归 RENDER-011（B7）。禁用效果不上报 ——
   禁用效果不影响像素，"丢弃"它是无信息噪声。
