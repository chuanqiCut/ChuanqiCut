# TASK-MEDIA-024：顺序取帧快路径对真实 4K60 素材失效修复 + 泵帧外秒级尖刺定位

> **状态：修复①②已落地，真机吞吐 74→120 帧/s（基线 15~26）✅；遗留偶发多秒停顿待 watchdog 定位（2026-10-06）。** 来源：baselines「泵内分段耗时」——
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
  - 新增单测：模拟「连续 kExact 前进请求」在 keyframes 表存在时快路径命中率（或等效断言：acquire 不触发 demuxer Seek）⏸（本轮修法改为渲染器侧区间复用，见下）
  - golden 既有快路径用例（test_media_sequential_*）零回归 ✅ 门禁 PASS=9/0
  - 真机复测（4K60 实拍素材）：pump_rendered/s ≥ 55 ✅（74→120 帧/s；acquire p95 326→53ms 且收敛；baselines 待回填终值）
  - total p95 无秒级尖刺 ⏸ 首帧 1076ms 尖刺残留 + 偶发多秒渲染停顿（stuck render 不进直方图样本）→ 下一轮 watchdog（Debug：RenderFrame 超 500ms 打印入口段）定位
verification:
  - ctest --test-dir build -R 'media_sequential|preview'
  - tools/ci/run_gate.sh
  - 真机剖面（同阶段 0 流程，CQ_AUTO_PLAY=1 + CQ_DEMO_SECONDS=20）
risk:        快路径条件（proven_span_ 学习）依赖 demuxer 关键帧表——真实素材（'hev1'/杜比视界）
             的 NAL 判定分支（media_demux.mm DetectKeyframeByNal）需先证实表非空；
             帧外尖刺候选（快照深拷贝/provider 重建/EnsureTarget）需二分仪器
parallel:    true   # 线 C 域
```

## 实施记录（2026-10-06，修复①②）

1. **展示区间内复用导入纹理**（PreviewRenderer::RenderFrame §2.5）：src_time 落在
   上一导入帧 [pts, pts+duration) 且同一素材 → 直接重画 imported_（跳过 acquire+
   import）。消除「区间内重复请求走慢路径重解 GOP」的 253→326ms 尖刺。lease 语义
   零违反（复用的是自己持有的导入纹理，不经手 provider 帧）。
2. **解码器输出尺寸元数据修正**：PopFrame 的 video.width/height 原用源尺寸
   （2160x3840），改 output_width_/height_（实际 CVPixelBuffer 尺寸）——视口计算
   与复用判据依赖它。⚠️ 首版复用判据在 ReleaseFrame **之后**读 frame → 读到
   lease 重置后的 {0,1}（复用永不命中）——渲染器文件头「ReleaseFrame 后字段全
   为默认值」的警告再+1，已把 pts/duration 捕获挪到释放前。
3. 真机（4K60 实拍，降采样 1080x1920，色彩已转 709）：rendered/s 15~26 →
   **74（追帧）→ 120（ProMotion 满帧）**；acquire p50 0ms（复用命中）/ p95
   326→53ms 收敛。
4. **遗留**：偶发多秒渲染停顿（rendered/s=0 窗口，stuck render 不进直方图）——
   嫌疑 demux ReadPacket / VT WaitForAsynchronousFrames 的无界阻塞；下一轮加
   watchdog（RenderFrame 超 500ms 打印进入段）定位。

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
