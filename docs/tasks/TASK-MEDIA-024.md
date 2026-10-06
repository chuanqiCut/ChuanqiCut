# TASK-MEDIA-024：顺序取帧快路径对真实 4K60 素材失效修复 + 泵帧外秒级尖刺定位

> **状态：待开工（2026-10-06 立项，数据已定案）。** 来源：baselines「泵内分段耗时」——
> 用户真机播放卡顿的两大根因（UI 与解码本身均已排除）。

```yaml
id:          TASK-MEDIA-024
layer:       SDK
goal:        4K60 实拍素材顺序播放时泵 rendered/s ≥ 55（消除 acquire 段 GOP 重解码爆发与渲染帧外秒级尖刺）
input:       [baselines「泵内分段耗时」「预览播放吞吐」、ADR-0017、MEDIA-021、pitfalls P38]
output:      [core/src/media/system_frame_provider.cpp 修复、core/src/preview/preview_renderer.cpp 尖刺定位修复、单测]
write_set:   core/src/media/system_frame_provider.cpp、core/include/cq/media/system_frame_provider.h（如需）、
             core/src/preview/preview_renderer.cpp、core/src/preview/preview_pump.cpp（仪器）、
             tests/unit/test_media_sequential_*.cpp、tests/unit/test_preview_*.cpp
read_set:    ADR-0017、.ai/modules/{media,preview}.md、pal/apple/media_demux.mm（ScanKeyframes）
deps:        []
acceptance:
  - 新增单测：模拟「连续 kExact 前进请求」在 keyframes 表存在时快路径命中率（或等效断言：acquire 不触发 demuxer Seek）
  - golden 既有快路径用例（test_media_sequential_*）零回归
  - 真机复测（4K60 实拍素材）：pump_rendered/s ≥ 55 且 acquire p95 < 40ms（回填 baselines）
  - total p95 无秒级尖刺（尖刺根因修复或定位到下一层）
verification:
  - ctest --test-dir build -R 'media_sequential|preview'
  - tools/ci/run_gate.sh
  - 真机剖面（同阶段 0 流程，CQ_AUTO_PLAY=1 + CQ_DEMO_SECONDS=20）
risk:        快路径条件（proven_span_ 学习）依赖 demuxer 关键帧表——真实素材（'hev1'/杜比视界）
             的 NAL 判定分支（media_demux.mm DetectKeyframeByNal）需先证实表非空；
             帧外尖刺候选（快照深拷贝/provider 重建/EnsureTarget）需二分仪器
parallel:    true   # 线 C 域
```

## 背景（数据定案，2026-10-06）

真机分段（baselines「泵内分段耗时」）：acquire 段 p50 17.6→32.5ms、**p95 253ms**；
total p95 **1068ms**（尖刺不在 acquire/import/draw 三段内）；VT 裸解码 p50 仅 8-10ms。

两个待修点：
1. **acquire GOP 重解码**：ADR-0017 顺序快路径在真实 4K60 素材上未生效。查证顺序：
   a. demuxer `ScanKeyframes` 是否为该素材建立了关键帧表（'hev1'/'dvh1' 的
      `DetectKeyframeByNal` IRAP 判定）；b. `TrySequentialAcquire` 的
      `proven_span_` 学习条件；c. 请求序列是否被 resize/快照重载打断。
2. **帧外秒级尖刺**：RenderFrame 中三段之外的耗时（快照 `CurrentSnapshot()` 拷贝、
   `GetProvider` 重建、`EnsureTarget`）。二分计时定位后修复。

## 媒体管线六问
1. 线程：改动全在泵线程路径；主线程零接触。2. 时序：RationalTime/kExact 语义不变。
3. 内存：无新增缓存；快路径减少重复解码反而降峰值。4. 取消：CancelToken 检查点不变。
5. 错误码：快路径拒绝时回退慢路径（既有语义），错误码不变。6. 一致性：kExact「展示
区间归属」不变；golden 像素断言锁定。

## 验收
acceptance 四条全过。

## 回写
baselines 真机复测数字；ADR-0017 若条件修订则补记；pitfalls 新坑。
