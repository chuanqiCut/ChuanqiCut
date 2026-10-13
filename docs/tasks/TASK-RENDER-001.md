# TASK-RENDER-001：RenderGraph 最小落地（B0 渲染地基）

> **状态：🔧 代码完成 + 单测全绿；真机问卷未回收，不标记完成**（2026-10-12）。
> ctest：Debug **51/51**、Release **51/51**（含本任务 `render_graph` 49 号用例）；
> `preview_renderer` 51 项全过（像素一致：contain 清屏黑 / 真值像素保持）。
> 全量 `run_gate.sh` 未跑（须传哲同意）；iOS/Mac 壳构建与真机未验。

```yaml
id:          RENDER-001
layer:       跨平台
goal:        落地最小 RenderGraph（节点 DAG + 拓扑排序 + 结构指纹）与三用途装配器
             （kPreview/kExport/kAudioOnly 同源，红线 #9 的可执行形式）+ 两阶段执行器，
             替换预览的手写单条 blit 路径；B0 不引入多轨合成/效果应用/节点缓存
input:       [RESEARCH-014 §6（Push/Pull 裁决）, ADR-0014（两套渲染路径的代价）,
             ADR-0034（B0 批次纪律）, .ai/modules/render.md, docs/specs/ARCH-001]
output:      [cq/render/*（7 头 + 4 实现）, cq/preview/chq_preview_renderer.*（改走图）,
             tests/unit/test_render_graph.cpp, engine/core/CMakeLists.txt 登记]
write_set:   engine/core/cq/render/*(新)、engine/core/cq/preview/chq_preview_renderer.{h,cpp}(改)、
             engine/core/CMakeLists.txt、tests/unit/test_render_graph.cpp(新)、
             tests/CMakeLists.txt
read_set:    cq/model/chq_timeline.h、cq/media/chq_asset_registry.h、cq/gfx/chq_gfx_device.h、
             cq/preview/chq_preview_frame_source.h、cq/base/*
deps:        [MODEL-001, GFX-002, BIND-003 子步骤 4/5]
acceptance:
  - 图结构校验：空图/无 sink/双 sink/blit 无输入/有环全部拒绝（kInvalidArgument）；
    重复 Connect 去重（不假报有环）
  - 拓扑序 Kahn；结构指纹 FNV-1a（装配缓存判据：同输入不重建图）
  - 装配器三用途同源：预览/导出/纯音频；空隙返回 kIoNotFound 不产节点；
    多轨命中 Warn + 只取第一条（既有像素行为不变）
  - 执行器两阶段：Prepare（CPU 取帧、回填源尺寸）+ Encode（GPU 拓扑序 blit）；
    视口取**上游 source 节点**尺寸（取 blit 自身尺寸是 2026-10-12 实测踩过的坑）
  - 时钟源：步进钟 t = start + n·frame_duration（每帧从 start 重算，防长导出漂帧）；
    实时钟 Advance 拒绝
  - 预览改走图后**像素一致**：既有 preview_renderer 像素断言全部保持
  - effects_dropped 诚实上报（带启用效果的片段为真，Warn Release 可见）
verification:
  - tools/build/build_core.sh --platform=apple --config=Debug   # 0 error 0 warning
  - tools/build/build_core.sh --platform=apple --config=Release
  - ctest --test-dir build -R render_graph
  - ctest --test-dir build -R preview_renderer
risk:        多轨合成/效果应用/节点缓存均不在 B0（归 RENDER-011/B7）；Pull 模型与音频线
             push 30Hz 的汇流点尚未验证（MEDIA-030 前不做结论）
parallel:    true（与 MODEL-003/SHADER-001 写集不相交；音频线 agent 已 429 失败）
```

## 背景与边界

红线 #9「预览与导出共用同一张 RenderGraph」在 B0 之前没有任何可执行形式：预览是一条
手写路径（取帧 → 导入 → 一次 blit），导出不存在。继续往上堆多轨/滤镜必然逼出第二条
渲染路径 —— ADR-0014 已为此付过一次代价。本卡落地「图」本身：

- **Pull 而非 Push**（RESEARCH-014 §6 要求立卡前必须回答）：预览现状就是请求驱动
  （泵线程请求 pts → 渲染一帧），Pull 与之逐该厂商一致，「与原 blit 路径像素一致」
  这个出口标准才能成立；音频线 push 30Hz 是另一条时间线，由 `ChqIClockSource`
  在同一装配器下区分用途，不混塞进同一套节点语义。
- **B0 边界**：只装配命中轨；命中多轨 Warn + 取第一条；效果/转场只如实上报
  （`effects_dropped`），不应用；无节点缓存、无 pass 合并、无纹理别名
  （模块册那五项是目标架构，不是本卡范围）。

## 关键实现决策

1. `ChqFitMode` 下沉到 `cq/render/chq_fit_mode.h`（避免 render 反向依赖 preview）。
2. `ComputeFitViewport` 从 preview 移入 `cq/render/chq_fit_viewport.h` ——
   两份实现必然漂移（memory 既有教训）。
3. `ChqRenderEvaluator` 实现 `ChqIFrameEncoderClient`，Prepare 非 const
   （图里唯一运行期可变字段 = 取帧后回填的源尺寸）。
