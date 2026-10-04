# TASK-MEDIA-021：顺序取帧不必每帧 seek（预览帧率的真瓶颈）

> 由 UIA-010 子步骤 5 的实测引出（2026-10-04）。**未开工**，等排期。
> 不在 UIA-010 的写集内 —— 它改的是取帧的**正确性语义边界**，必须有针对性用例，
> 混在"挪线程"那次提交里会让它逃过针对性审查。

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

## 目标

顺序（前进）取帧时**不要重新 seek**：解码器已停在目标之前，继续往前解码到目标即可 ——
这仍然是 `kExact` 语义（拿到的仍是包含 t 的那一帧），只是不再重复解码已解过的帧。

## 关键设计点（开工前先定）

1. **什么条件下跳过 seek**：`t >= 上一次交付帧的 pts`，且前进幅度在阈值内
   （超过阈值说明是跳转，seek 更划算）。需要在 `SystemFrameProvider` 里记录
   `last_delivered_pts_`（`Finalize` 时写）。
2. **回退必须 seek**：`t < last_delivered_pts_` 时解码器已在目标之后，只能 seek。
3. **阈值取多少**：需要实测（GOP 长度 vs 逐帧解码成本）。不要拍脑袋写常量 ——
   这是本项目踩过 6 次的坑（E6 同族：编造数值）。
4. **与帧缓存的关系**：`IFrameCache` 已存在但未在预览链路注入
   （`PalFrameProviderFactory` 未调 `SetFrameCache`）。是否顺带注入要单独立项讨论。

## 验收（必须逐帧断言，不能只看"播起来了"）

- 连续递进请求 30 次（每帧 +40ms）：每次返回帧的 pts **严格落在请求的展示区间内**
  （对照 `AcquireExact` 的 `FrameContains` 判定），且不等于上一帧。
- 随机跳转（前后跳）序列：结果与「每帧都 seek」的实现**逐帧一致**。
- 混合序列（前进 10 帧 → 后退 5 帧 → 前进 20 帧）同上。
- 性能：连续递进请求的 `acquire` 均值应显著下降（目标待实测后定，不预先写死）。

## 风险

- 改的是**精确取帧**这个编辑器的核心不变量；错了会以「画面差一帧」的形式出现，
  静态彩条素材根本看不出来 —— 必须用 `LastFramePts()` 逐帧断言，不能靠像素。
- GOP / B 帧边界：跳过 seek 后解码器的 DPB 状态与「刚 seek 完」不同，
  `AcquireExact` 的 `FrameContains / before` 逻辑要重新过一遍。

## 关联

- 上游：`TASK-UIA-010`（子步骤 5 已完成取帧泵，主线程不再被堵）
- 决策：`ADR-0013` §后果与已知限制 第 2 条
- 坑：`pitfalls P38`
