# TASK-MEDIA-021：顺序取帧不必每帧 seek（预览帧率的真瓶颈）

> 由 UIA-010 子步骤 5 的实测引出（2026-10-04）。
> **状态：✅ 已完成（2026-10-04）**，决策见 `docs/decisions/ADR-0014-顺序取帧快路径与解码器显示序重排.md`。

## 问题（有实测数字，不是猜测）

`SystemFrameProvider::AcquireFrame` 只要 `seek_target_ != req.at` 就 `Seek()`
（demuxer seek + `decoder_->Flush()`），随后 `AcquireExact` 从关键帧一路解码到目标。
顺序播放时 pts 每帧都在变 → **每帧都重解一个 GOP**。

| 场景 | acquire 均值 | 单帧 total | 上限帧率 |
|---|---:|---:|---:|
| 连续递进请求（每帧 +40ms），128x128，Release | **93.3 ms** | 99.3 ms | **10.1 fps** |
| 同上 Debug | 90.5 ms | 96.3 ms | 10.4 fps |
| 孤立请求单帧，128x128，Release | 5.0 ms | 8.2 ms | — |

App 侧（1280x720，Debug XCFramework）1 秒播放：请求 59 / **实际渲染 3** / 合并 54。

Debug 与 Release 几乎一样慢 → 不是编译器优化问题，是策略问题。
（数据出处：`.ai/memory/baselines.md`；埋点：`cq_preview_last_timings`）

## 结果（修复后实测，同素材同条件）

| 项 | 修复前 | 修复后 |
|---|---:|---:|
| 顺序 120 帧 acquire 均值（1080p GOP60/B帧3，Release） | ~93 ms/帧（128x128 渲染口径） | **4.45 ms/帧（14.8x vs 每帧 seek 对照 65.87ms）** |
| 逐帧 pts 严格递增 / 区间归属 | — | **120/120、120/120** |
| 快/慢路径逐帧 pts 一致 | — | **一致（kExact 语义不变）** |
| 学习期 seek 次数（多 GOP mock，16 帧） | 16 | **2**（此后全快路径） |

## 落地内容（超出原计划的部分：三个既有正确性 bug）

逐帧 pts 断言（验收要求）暴露了三个**慢路径同样中招**的既有 bug，全部修复：

1. **P39 VT 完成序回调**：VT 按完成序（≈dts 序）回调，B 帧在其参考 P 之后完成；
   旧「弹不出才喂」循环在 B 未喂入时只能弹 P → kExact 交付错帧 + **负 duration**。
   修复 = 先喂后弹循环（ADR-0014 D3）+ 显示序连续性重排（D4）。
2. **P40 首帧时长兜底用 pts 差**：B 帧文件前两个喂入包 pts 差 = (bframes+1) 帧
   （=16000 ticks），首帧区间报宽 4 倍 → 关键帧提前命中。修复 = 用 dts 差。
3. **P41 Flush 后旧在途帧污染**：Flush 后迟到的旧回调帧入队，首弹无约束弹出旧帧
   （实测 Seek(124000) 弹出旧 GOP 的 128000）。修复 = Flush 先等在途帧落地再清队。
4. **consumed_ 同帧重复修复**：seek 目标被消费后重复请求同目标必须重新 seek，
   否则「越过兜底」返回下一帧（违反 kExact）。

## 原设计要点（已验证）

1. **什么条件下跳过 seek**：`t >= 上次交付帧区间终点`，且跨度 ≤ `proven_span_`
   （自适应：只吸收「连续关键帧间隔」「关键帧到交付帧距离」两类实证，
   初始 0，最坏退化为旧行为，无拍脑袋常量）。
2. **回退必须 seek**：已实现（快路径拒绝回退）。
3. **与帧缓存的关系**：`IFrameCache` 仍未在预览链路注入（`PalFrameProviderFactory`
   未调 `SetFrameCache`）——维持原状，注入与否另行立项。

## 验收（全部达成）

- [x] 顺序递进请求逐帧 pts 断言：`media_sequential_acquire`（mock，46 断言）
      + `media_sequential_real`（真实硬解，7 断言）
- [x] 随机跳转/混合序列与「每帧都 seek」的实现逐帧一致（mock E 场景 +
      真实链路快/慢对照 120 帧一致）
- [x] 性能：acquire 均值显著下降（93.3ms → 4.45ms，14.8~31x，数字见 baselines）

## 门禁

```bash
./tools/build/build_core.sh --platform=apple --config=Debug --test    # 42/42
./tools/build/build_core.sh --platform=apple --config=Release --test  # 42/42
ctest -R media_sequential_acquire   # 46 断言
ctest -R media_sequential_real      # 7 断言（Debug/Release 均过）
ctest -R media_system_frame_provider / pala_decode / frame_provider_apple  # 回归全过
cd bindings/swift && swift test --disable-sandbox            # 23/23
cd apps/apple/packages/SharedUI && swift test --disable-sandbox  # 20/20
```

## 关联

- 上游：`TASK-UIA-010`（子步骤 5 已完成取帧泵，主线程不再被堵）
- 决策：`ADR-0014`；上游引用 `ADR-0013` §后果与已知限制 第 2 条（已闭环）
- 坑：`pitfalls P38（已修）/ P39 / P40 / P41`
