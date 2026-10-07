# 模块：RenderGraph 与效果

> **归属**：C 线（内核/媒体/渲染） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`core/src/graph/`、`core/src/effect/`、`core/src/color/`

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
| RENDER-001/004/005 | RenderGraph | 未开工（001=多轨/导出共同瓶颈，关键路径） |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| — | 未实测（本模块无独立阶段批记录） | — |

### 调研 · 决策 · 池指针

- ADR-0002（GPU 抽象）· PLAN-素材库草稿混排多轨（RENDER-011/012 依赖）
