---
name: cq-perf-baseline
description: 建立与维护性能基线。用于替换估算数字、判断优化是否有效、防止性能回归。
---

# 性能基线

## 触发
- 任何性能相关改动的前后对比
- 定期（每个里程碑）
- 有人引用性能数字时（**必须确认该数字来自本文件，而不是来自调研文档的估算**）

## 铁律
**调研文档里的性能数字一律是估算 [E]，不得作为验收阈值或设计依据。**
唯一被认可的数字来源是 `.ai/memory/baselines.md`，由本技能产出。

## 流程

### 1. 测量
```bash
tools/perf/media_bench  --cases=decode,encode,seek
tools/perf/render_bench --resolution=<1080p|4K> --tracks=<n>
tools/perf/infer_bench  --model=<m>
tools/perf/mem_profile  --scenario=<preview|export>
```

### 2. 取数约定
- **P50 / P95 / P99，不取平均值**（P99 才对应卡顿体验）
- 每项 3 次取中位
- 样本固定（`tests/golden/` 素材），设备预热 5 秒
- 记录设备型号、系统版本、电量与温度

### 3. 与基线对比
- 超出阈值 → 阻断（门禁）
- 改善 → 更新基线并在 PR 说明原因
- **跨平台对比**：iOS vs Android 同项目导出，PSNR ≥ 36dB、SSIM ≥ 0.98

### 4. 回写
更新 `.ai/memory/baselines.md`，附：日期、设备、测量方法、样本。
同步更新 `.ai/memory/device-matrix.md`（若新增设备）。

## 检查清单
- [ ] 用了 P50/P95/P99，不是平均值
- [ ] 设备与环境信息完整
- [ ] 与既有基线对比，判定是否触发门禁
- [ ] 数据已回写 `baselines.md`
- [ ] 若替换了调研文档中的估算数字，在该文档标注"已被实测替换"

## 输出
机器可读 JSON（`tools/perf/` 产出）+ `baselines.md` 条目更新。
