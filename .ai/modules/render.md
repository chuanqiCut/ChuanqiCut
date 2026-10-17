# 模块：RenderGraph 与效果

> **归属**：C 线（内核/媒体/渲染） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

> **落地状态（编码 2026-10-12 / 提交 `6ccf29b` 2026-10-13，RENDER-001 / B0）**：目标架构的**第一步**已落地 ——
> 节点 DAG + 拓扑排序（Kahn，含环检测）+ 结构指纹（FNV-1a）+ 三用途装配器
> （kPreview/kExport/kAudioOnly）+ 两阶段执行器（CPU Prepare / GPU Encode）+ 时钟源
> （步进/实时）。实现在 `engine/core/cq/render/`（ADR-0033 共置布局；本册路径
> `core/src/graph/` 是 ADR-0033 前的旧布局，未同步更新）。**Pass 合并 / 纹理别名 /
> LOD / 效果节点均未实现**（归 RENDER-011，B7）；Pull 模型（预览请求驱动），音频线
> push 30Hz 由 ChqIClockSource 在同一装配器下区分。效果只如实上报 effects_dropped。

**边界**：`engine/core/cq/render/`（原 `core/src/graph/`）、`engine/core/cq/effect/`、`engine/core/cq/color/`

## 职责
效果节点 DAG 调度、pass 合并、中间纹理别名分配、LOD；各类效果节点（变换/合成/转场/调色/LUT/抠像/美颜/美型/文字/贴纸）。

## RenderGraph 五项职责
1. 节点依赖分析与拓扑排序（含环检测）
2. **Pass 合并**：相邻且输出仅被下一 pass 消费的节点合并为单 pass
3. 中间纹理生命周期与别名复用（受内存预算约束）
4. **LOD**：预览可跳过标记 `expensive` 的节点（超分、降噪）
5. 导出模式禁用 LOD，全量执行

> 为什么必须有：4K 下效果链若逐 pass 各自 render target，纹理带宽是瓶颈，60fps 不可能。Pass 合并是刚需不是优化。

## 效果节点接口
```cpp
class RenderNode {
  virtual Status declare(NodeDeclaration&) = 0;          // 拓扑与内存规划
  virtual Status evaluate(const FrameContext&, CommandEncoder&) = 0;  // 每帧只更新 uniform/绑定
  virtual CapabilityRequirement requirements() const = 0; // 能力探测与降级方案
};
```
美型 MeshWarp 与 UV Offset Map 是同一接口的两个实现，切换不换调用方。

## 色彩
- Working color space 内计算；输入/输出各做一次转换
- LUT 应用顺序固定：**先校正（Color）后风格化（Filter）**
- 预览与导出必须一致（PSNR ≥ 40dB）

## 硬约束
1. 预览与导出走**同一张 RenderGraph**，只换输出目标与时钟源
2. `evaluate()` 内不得分配内存
3. 效果节点不得直接依赖平台 API，一律经 GFX 抽象

## 验证
```bash
ctest -R graph_topology
tools/qa/golden_compare.sh --case=<effect>
tools/perf/render_bench --resolution=4K --tracks=3
```

## 相关
ARCH-003 §5/§6/§8/§9、ADR-0005（美型实现切换）

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| Task ID | 标题 | 状态 |
|---|---|---|
| GFX-001 | GFX 抽象 | ✅ |
| **RENDER-001** | RenderGraph **第一步（B0）** | ✅ **已落地**（编码 2026-10-12，提交 `6ccf29b` 2026-10-13，62 文件 / +5727 −346）：节点 DAG + Kahn 拓扑与环检测 + FNV-1a 结构指纹 + 三用途装配器（kPreview/kExport/kAudioOnly）+ 两阶段求值 + 时钟源；预览已改吃该图且 `preview_renderer` 51/51 与原 blit 路径**像素一致**。⚠️ 按 ADR-0034 **真机问卷未回收前不标记验收完成** |
| RENDER-004/005 | Pass 合并 / 纹理别名 / LOD | ❌ 未开工（性能优化项，随 RENDER-011 一起评估） |
| RENDER-011 | 效果节点 + **多轨合成** | ❌ 未开工。**当前渲染仍只画第一条命中视频轨**（`chq_graph_assembler.cpp:77` 与 `chq_preview_renderer.h:24` 双自陈）；001 落地后本项成为多轨/导出（EXPORT-002）的新瓶颈。**2026-10-17 追加裁定排进 v0.2.0 射程第 3 张**（CORE-011 ✅ → MODEL-004 → **本卡** → EXPORT-001 → …），排在导出之前是为了让导出交付的就是"所见"画面。⚠️ **磁盘无卡**、BACKLOG 那行写集 `core/src/effect/composite.*` 已过期；且这行把「效果节点」与「多轨 blend」混挂一张，建卡时判拆 |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| 2026-10-13 | B0 合并快检（本机 Intel x86_64 / macOS 26.7.1 / Xcode 26.6） | `build_core.sh` Debug **3m49s、0 错 0 警**（-Werror）；`ctest` **52/52**（78.66s）；`render_graph` / `model_property` 179 检查 / `c_abi_property` 76 检查均 0 失败；`preview_renderer` **51/51** 像素一致 |
| 2026-10-13 | AUDIO-004 同批窄检 | 平台头门禁 **43 头 0 违规**；`ctest -R audio` 5/5 |
| ⚠️ 未做 | 全量 `run_gate.sh`（最后一次 = 2026-10-12 PASS=14）、golden `verify.py` | 均**未跑**（真机已在 2026-10-17 单独上过一趟，见下一行）；池 [18] 已随 INFRA-037 解决 |
| 2026-10-17 20:3x | **真机趟**（iPhone 17 Pro 无线配对，CORE-011 build Debug-iphoneos） | 编辑页不崩；硬解生效 `hw=YES out=1920x1080`；`pump_req/s=120 → pump_rendered/s=112~120`、`pump_nonok/s=0`、`mtk_draw/s=120`、`tick_p95=0ms`、`footprint 87.0→92.9MB`。⚠️ **多轨命中那条 Warn 没出现** —— 演示钩子只铺一轨一片段，构造不出两轨同时命中 → 池 **[30]**（RENDER-011 的验收基线目前无可复现路径）。配方与失败趟数字见 baselines「真机趟」+ **P182** |

### 调研 · 决策 · 池指针

- ADR-0002（GPU 抽象）· PLAN-素材库草稿混排多轨（RENDER-011/012 依赖）
- **[RESEARCH-014](../../docs/research/RESEARCH-014-主流NLE引擎架构综合调研与RENDER-001规划建议.md)**（2026-10-11）：GBU 综述 + FCP/Premiere/Resolve/该厂商系横向对比；RENDER-001 范围修订建议（+装配器三图同源/时钟源接口/Push-Pull 拍板）——**已采纳并随 B0 落地**（装配器 + 时钟源 + Pull 模型，见本册头部落地状态；2026-10-13 传哲拍板）
- **[ADR-0040](../../docs/decisions/ADR-0040-空间与交互地基批次引入.md)**（2026-10-13）：B5.5 空间与交互地基（`MODEL-004` transform/layer/speed/keyframe）排在 B4 之后、B6/B7 之前 —— RENDER-011 效果节点的数据结构前置
