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

## 落地记录（2026-10-18，集成机编码轮）

状态：**编码完成 + 本机窄检绿**。L3 随 v0.2.0 批末那一趟。

形状（与卡片"实现要点"的差别，逐条说清）：

* 节点加 `kTransform = 3` 与两份 `ChqTransform`（片段级 + 轨级），`ChqRenderNodeDesc` 里没有
  裁剪矩形 —— 适配矩形由 `ChqFitMode` + 源/画布尺寸在烘焙时算，**与 blit 共用同一个
  `ComputeFitViewport`**（要点 1 说的"POD 参数形状"因此是变换 + 尺寸，不是绝对矩形）。
* **装配器无条件走 kTransform**（不是"非恒等才走"）：分两条路就是两套渲染逻辑（ADR-0034）。
  于是既有的像素断言（`preview_renderer` 的顶红底蓝 / smptebars 真值 / contain·cover / #21 旋转）
  本身就变成恒等回归的证据 —— 它们全绿。`kBlit` 分支保留但生产路径不再产出，
  登记为欠账，由 RENDER-011 决定是否退役。
* 几何**在 core 烘焙**（`chq_layer_geometry.{h,cpp}`）而不是在 shader 里算：
  各端 libm/GPU 三角函数末位不保证一致，且放 core 才能用普通单测逐位锁
  （`tests/unit/render/test_layer_geometry.cpp`，41 项）。旋转在**像素平面**做 ——
  归一化空间的 45° 在非正方画布上会变成斜切（单测第 3 节专抓这个）。
* 叠加顺序 `M(轨) ∘ M(片段)`：MODEL-004 把这一格让给本卡（`ChqTrack::transform` 注释即此）。
  轨级恒等时合成恒等，单测逐位比过。**有意不立 ADR**（同 INFRA-047 先例）：口径落在
  `chq_layer_geometry.h` 头部与 `.ai/modules/render.md`。
* 契约头加 `ChqIBlitPass::EncodeLayer(encoder, src, vertices, vertex_count)`：交错
  `pos.xy / uv.xy / alpha`（stride 20），平台不做几何算术。**alpha 走顶点不走 uniform 缓冲**
  —— `ChqICommandEncoder` 没有绑 constant buffer 的方法，加一个等于改契约头。
* **视口机制让位给顶点**：变换层不调 `SetViewport`（两套同时生效会让旋转中心跟着视口漂）。
  因此 `render_graph` 单测里"contain 设了视口"那三条断言换成了顶点 NDC 包围盒断言，
  数值与原视口矩形一一对应（1080×607.5，y=656.25 → ±0.31641）。**改的是机制不是像素。**

验收第 2 条换了判据形式（同 SHADER-010 偏差 1）：恒等 A/B 实测 **最大通道差 0**（逐位相同），
比 ≥40dB 更严；`layer_geometry` 41 项、`layer_identity` 21 项、`render_graph` 全绿。
风险条要的"单帧成本"拆成两半：CPU 侧 `BakeLayerQuad` **63 ns/层**（Release 配置；Debug 351 ns），
32 层上限最坏 ≈ 2.0 µs/帧；判据是松上界 20µs，只抓灾难级回归，数字在 `baselines.md`。**每层 GPU 编码成本未实测** —— 本机 `layer_identity` 只有 64×64 单例，
拿它当每帧成本是假数，归 **池 [30]** 真机趟。

写集欠账（本卡实际动到、但不在上面 write_set 里列出的文件 —— 高冲突文件归集成机，此处正是本机）：

| 文件 | 为什么必须动 |
|---|---|
| `engine/core/cq/platform/chq_gfx.h` | 契约：`EncodeLayer` 声明（不加就没有平台侧入口） |
| `engine/core/cq/render/chq_layer_geometry.{h,cpp}` | 新文件：几何烘焙的唯一事实来源 |
| `engine/core/CMakeLists.txt` | 高冲突文件：把新 .cpp 挂进 cq_core |
| `engine/core/cq/render/chq_render_evaluator.h` | 卡片只列了 `.cpp`；`EncodedTransforms()` 计数必须同批 |
| `tests/unit/preview/test_layer_identity.cpp` | 写集写的是 `tests/unit/render/`，但 GPU A/B 回归要 Metal，只能放 preview 目录 |
| `tests/CMakeLists.txt` 的 heavy 名单 | 见下 |

heavy 名单增量：本卡加 `layer_identity`（跑真 GPU）→ 分档判据不变（"需要素材文件 / 硬件 codec·Metal"），
`layer_geometry` 是纯 CPU 不标。名单真源在 `tests/CMakeLists.txt`，ADR-0046 §决定 3 与
TASK-INFRA-043 记的是当时那批，不回头改数（MODEL-004「活文档去死数」同一口径）。

本卡明确不做（照抄进代码注释，不只写在对话里）：多轨叠合与分槽顶点缓冲归 RENDER-011
（当前顶点缓冲共享一块，一帧内多次编码会互相覆盖）；关键帧求值归 B8，装配器对带关键帧的
片段**发 Warn 并按静态值取**；`ChqEffectStack` 不消费，`effects_dropped` 照旧。
