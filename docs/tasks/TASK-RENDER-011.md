# TASK-RENDER-011：多轨画面合成（按轨序 Z-order 叠合）

```yaml
id:          TASK-RENDER-011
layer:       跨平台
goal:        RenderGraph 支持多条视频轨同时命中并按轨序叠合，预览与导出仍是同一张图
input:       [ADR-0040（B5.5 → B7）、TASK-MODEL-004（transform/opacity/layer 字段）、
              docs/research/RESEARCH-016]
output:      [合成节点类型、装配器多命中路径、混合状态、单测、golden 夹具、真机取证钩子]
write_set:   engine/core/cq/render/{chq_render_graph.h,chq_graph_assembler.cpp,chq_render_evaluator.cpp}、
             engine/core/cq/gfx/*、engine/platform/apple/gfx/*、
             tests/unit/render/、tests/CMakeLists.txt、tests/golden/、
             ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/AppEntry.swift（CQ_DEMO_TRACKS）
read_set:    engine/core/cq/model/chq_timeline.h、MODEL-004 新增的 transform 头、
             engine/shaders/portable/blit.{frag,vert}、engine/core/cq/render/chq_clock_source.h
deps:        [MODEL-004, SHADER-010, RENDER-010]
acceptance:
  - 两轨同时命中时装配结果 `multi_track_ignored == false`，那条 Warn 不再出现（单测断言）
  - 图节点数 = 命中层数 + sink，且过 `kMaxGraphNodes` 上限检查；新节点种类在 Validate 与 Encode 两路都有分支
  - golden：两层叠合帧与夹具一致，新夹具登记进 tests/golden/manifest.toml
  - 静音/禁用轨不进合成，与 `engine/core/cq/audio/chq_preview_mixer.cpp` 的 `!enabled || muted` 同语义
  - 真机：`CQ_DEMO_TRACKS=2` 起 App 能同时看到两层 —— **这一条是收池 [30] 的唯一取证路径**
  - 画中画（传哲 21:3x 裁定要交付）：第二层按 clip transform 定位/缩放，变换值只从模型读、UI 不直接改模型（红线 5）
verification:
  - tools/build/build_core.sh --platform=apple --config=Debug --test --skip-label=heavy
  - ctest --test-dir build -R render
  - "${PYTHON_BIN:-python3}" tests/golden/verify.py --json
  - tools/ci/check_apple_shells.sh --shell=ios（gfx 改动只有双壳能判红，P181）
risk:        逐层不透明度与 transform 都经 SHADER-010 的 Portable 通道（先跑 `cq-shader-portability`、
             生成产物不入库，红线 6）；叠合层数与每帧 GPU 成本线性相关，但**不设拍脑袋阈值**，
             先按 `.ai/memory/baselines.md` 的实测口径记账
parallel:    false
```

## 背景

**音频早就是真多轨，画面不是。** `engine/core/cq/render/chq_graph_assembler.cpp:65-78` 遍历视频轨
但只保留第一条命中的片段，命中第二条即打 Warn；`engine/core/cq/preview/chq_preview_renderer.h` 同处自陈。
传哲 2026-10-17 追加裁定把这条线插进 v0.2.0，排在导出之前 —— 目的是让导出交付的就是"所见"画面，
而不是先导出一个"只有一层"的成品再返工。

前置有三张：[TASK-MODEL-004](TASK-MODEL-004.md) 提供数据槽（`ChqClip` 现在没有任何变换/层级字段，
`engine/core/cq/model/chq_timeline.h` 只有转场与效果栈）、[TASK-SHADER-010](TASK-SHADER-010.md) 提供
Portable 变换 shader、[TASK-RENDER-010](TASK-RENDER-010.md) 提供消费它的 TransformNode。合成器拿不到
"第二层画在哪、多大、多不透明"时，本卡只能空转。

## 范围裁决（建卡时判的两件事）

| 问题 | 判定 |
|---|---|
| BACKLOG §3.3 那行把「效果节点」也挂在 RENDER-011 上，拆不拆 | **拆**，而且拆出三件事：变换 = [TASK-RENDER-010](TASK-RENDER-010.md)、转场 = RENDER-012（未开工）、**效果栈消费**（`ChqEffectStack`，装配器现在只报 `effects_dropped`）**根本没有号** —— 它不是本卡射程，建议号 RENDER-013，立项时现取现核 |
| MVP 做不做到"可拖动/可缩放画中画" | ✅ 已裁（2026-10-17 21:3x 传哲）：**做到**。链上补 SHADER-010 + RENDER-010 两张，本卡消费它们的产物 —— 所以本卡必须排在这两张**之后** |

## 实现要点

1. `ChqRenderNodeKind` 只有 kSource/kBlit/kSink，`kMaxNodeInputs = 4` 与 `kMaxGraphNodes = 32`
   是 B0 时就为多轨预留的余量 —— 本卡第一次真正用到，预留是否够要在单测里判出来（不够就当场提出，别默默塞满）。
2. 装配层：把"保留第一条"改成"按轨序收集全部命中层 → 逐层入图"，轨序 = Z 序（与 UIA-030 的既定语义一致）。
3. 执行层：`engine/core/cq/render/chq_render_evaluator.cpp` 目前只对 kBlit 编码，新节点要同时补 Validate 与 Encode。
4. **红线 9 不破**：导出与预览共用这份装配代码，只换输出目标与时钟源（`chq_clock_source.h` 的
   kRealtime / kStepped 已备好），不许为导出另开一条装配分支。

## 回写

`.ai/modules/render.md`（节点表 + 多轨状态）、`docs/tasks/TASK-BACKLOG.md` §3.3 行状态、
池 **[30]** 关闭（真机两轨取证）、`.ai/memory/baselines.md`（叠合层数 vs 每帧成本实测）、
动了 shader 则 `.ai/modules/gfx.md` + 新 ADR 视情况。
