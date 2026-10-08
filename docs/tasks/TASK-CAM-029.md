# TASK-CAM-029：磨皮/美白算法升级——保边、细节回注、唇齿保护（C 期，效果追平核心）

```yaml
id:          TASK-CAM-029
layer:          UI(iOSApp)
goal:           磨皮从「双边平滑」升级到主流口径：①细节回注（高频层按强度回注，防
                「磨皮=糊」）；②唇齿/眉眼保护（色域+语义双保护）；③肤色域自适应 σr
                （按亮度分档，暗部少磨亮部多磨）；④美白唇色保护
input:          [传哲 2026-10-07 定则, RESEARCH-009 §差距3, TASK-CAM-012(kernel 基础),
                baselines.md(磨皮 9.85ms 宿主 / 剪映 ~2ms [E] 行业传闻)]
output:         [ChuanqiCutCameraImpl/Effects/beauty_bilateral.metal(pass 融合+细节回注),
                ChuanqiCutCameraImpl/Effects/BeautyKernel.swift(参数面),
                beauty_harness 对比剖面]
write_set:      apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/Effects/beauty_bilateral.metal,
                apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/Effects/BeautyKernel.swift
read_set:       .ai/modules/camera.md, RESEARCH-009, .ai/memory/baselines.md, TASK-CAM-027(语义保护)
deps:           [TASK-CAM-012]
acceptance:
  - 保边保持率 ≥60%（beauty_harness 边缘剖面口径，与 012 同基准）；细节回注后
    高频能量恢复 ≥80% [E]
  - 唇/齿/眉眼区域磨皮强度 ≤ 全脸的 20% [E]（语义蒙版就位后由 027 供给）
  - 全脸磨皮链真机 ≤8ms（现有验收阈值不变，pass 融合后维持）
  - GPU 剖面 + 真机观感 A/B（对比 CAM-012 版本）归传哲
verification:   beauty_harness 剖面 + iOS 构建 + 真机 A/B
risk:           pass 数量增加与 8ms 预算冲突——靠 pass 融合（细节回注并入 up pass）
                而非新增 pass；宿主 harness 与真机色彩域差异已由 018 对齐
parallel:       false
```

## 实现要点

- 细节回注：`out = 平滑层 + (原图 − 平滑层) × detailGain(strength)`——高频层在
  up_v_mix pass 内联计算（零新增 pass）；detailGain 随滑杆递减（磨越狠回注越少）。
- 唇齿保护：唇域由 026 的唇蒙版/027 语义供给，kernel 内按 mask 降低双边权重 + mix。
- 性能纪律：任何新逻辑并入既有两 pass（down_h / up_v_mix），预算见 baselines。



## 进度（2026-10-08 回写，HANDOFF-017 收口轮）

**状态：只做了 4 项里的②后半 + ③，且分布不对称 —— 池 [9]**

| 卡上的验收项 | 状态 | 现状 |
|---|---|---|
| ① 细节回注（高频层按强度回注） | ❌ **完全没做** | 卡要求并进 `up_v_mix` pass 内联实现，实际该 pass 仍是原始 `mix(o, blurred, mix_t)` |
| ② 唇齿/眉眼保护 | ⚠️ 只做了**色域兜底** | 新增 `cq_beauty_protect`（唇=红主导 / 牙眼白=高亮低饱和，最多降到 0.15× 权重）；卡里写明语义保护应由 **026 唇蒙版 / 027 语义供给**——现在两路都没接上 |
| ③ 肤色域自适应 σ（按亮度分档） | ⚠️ 只在一个 pass | 新增 `cq_beauty_sigma_local`（暗部 0.6× / 亮部 1.4×，**只在 `cq_beauty_down_h` 生效**；`cq_beauty_up_v_mix` 仍用原始 `sigma_range`） |
| ④ 美白唇色保护 | ❌ 未做 | — |

接手动工前必须确认的三件事（详见 HANDOFF-017 §3.3）：

1. **pass2 要不要跟着改**：保护与自适应 σ 只在 pass1 生效，是有意保留 pass2 干净，
   还是漏改 —— **这条要传哲定，不要自己猜**。
2. **参数面没动**：卡 write_set 里的 `BeautyKernel.swift` 本轮没改，`protect` 的 0.85 与
   σ 的 0.6×～1.4× 目前是 **写死在 metal 里的常量**。
3. **缺 harness 实测**：卡片三项数字（保边保持率 ≥60%、高频能量恢复 ≥80% [E]、全脸 ≤8ms）
   全部没有 `beauty_harness` 剖面数据；baselines「磨皮 9.85ms」是 **CAM-012 旧版本**的值，
   不能拿来当升级后的验收阈值。
