# TASK-RENDER-010：TransformNode（把 clip 的变换变成一个渲染节点）

```yaml
id:          TASK-RENDER-010
layer:       跨平台
goal:        新增一种 RenderNode：按片段的位移/缩放/旋转/裁剪绘制一张纹理，供多轨叠合与画中画使用
input:       [TASK-SHADER-010（Portable 变换 shader）、TASK-MODEL-004（clip 的 transform 字段）、
              docs/research/RESEARCH-016（对标产品的叠加层能力）]
output:      [节点种类 + 参数、装配器产出该节点、执行器 Validate/Encode 两分支、单测与 golden]
write_set:   engine/core/cq/render/{chq_render_graph.h,chq_graph_assembler.cpp,chq_render_evaluator.cpp}、
             engine/core/cq/model/（读 MODEL-004 的 transform，若需接缝则同批）、
             engine/platform/apple/gfx/blit_pass.mm、
             tests/unit/render/、tests/CMakeLists.txt、tests/golden/
read_set:    engine/shaders/portable/transform.{vert,frag}、engine/core/cq/preview/chq_preview_renderer.{h,cpp}、
             engine/core/cq/render/chq_clock_source.h
deps:        [SHADER-010, MODEL-004, RENDER-001]
acceptance:
  - `ChqRenderNodeKind` 新增变换种类，**同一提交内**补齐 `chq_render_graph.h` 的校验与执行分支
    （该文件头部明写"别只加枚举"，只加枚举是当场可判的红）
  - 恒等变换下输出与现有 blit 逐像素一致（golden 回归，同平台 ≥40dB）—— 证明它是加法而不是改写
  - 变换参数一律归一化坐标 + `ChqRationalTime` 取点，**不得出现浮点秒或平台点单位**（红线 4）
  - 预览与导出共用同一装配（红线 9）：步进时钟下变换按帧取点结果与实时预览一致
  - 效果栈仍**不在本卡**：`effects_dropped` 那条 Warn 照旧如实上报，本卡不消费 `ChqEffectStack`
verification:
  - tools/build/build_core.sh --platform=apple --config=Debug --test --skip-label=heavy
  - ctest --test-dir build -R render
  - "${PYTHON_BIN:-python3}" tests/golden/verify.py --json
  - tools/ci/gate_scope.sh（本卡闭环前按它吐的窄检跑；L3 归批末那一趟）
risk:        节点数与每帧 GPU 成本随叠合层数上升；上限 32 张是 B0 预留，本卡第一次真正消耗它 ——
             不够用要当场提出而不是默默塞满。
             `blit_pass.mm` 属平台层：可改实现，**不得把 Metal 类型漏进 `engine/core/cq/` 可见面**（红线 2）。
parallel:    false
```

## 为什么单独成一张卡

传哲 2026-10-17 21:3x 裁定多轨画面在 v0.2.0 要交付到"可定位、可缩放"的画中画档。
叠合（RENDER-011）负责"两层怎么盖"，本卡负责"每层画在哪、多大" —— 混在一张里会让 RENDER-011 的
写集同时吃掉 shader 生成链、图校验、平台编码三处，CR 面过大且失败时无法二分定位。

## 实现要点

1. 参数形状：归一化中心/尺寸 + 旋转角 + 裁剪矩形 + 不透明度，POD、可整体指纹化（跟 `ChqRenderNodeDesc` 现有口径一致）。
2. 装配层从 `ChqClip` 的 transform 取点，**UI 不得直接改模型**（红线 5）：写路径归 MODEL-004 的命令。
3. 执行层：`engine/core/cq/render/chq_render_evaluator.cpp` 目前只对 kBlit 编码，本卡加第二条分支并同步校验。
4. 恒等变换回归是本卡的安全带 —— 没有它，"多轨画面"出问题时分不清是叠合错了还是变换错了。

## 回写

`.ai/modules/render.md`（节点表 + 变换参数形状）、`.ai/modules/shader.md`（变换 shader 的消费方落地）、
`docs/tasks/TASK-BACKLOG.md` §3.3 行状态、`.ai/memory/baselines.md`（恒等变换回归 + 单帧成本实测）。
