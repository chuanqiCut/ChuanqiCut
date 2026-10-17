# TASK-PALA-030：Apple 音频引擎收口（射程已收窄为「导出的音频落盘」）

```yaml
id:          TASK-PALA-030
layer:       跨平台+PALA
goal:        把 AVAudioEngine 后端**真正剩下**的那块做完 —— 导出路径的音频与视频同网格落盘
input:       [TASK-EXPORT-001（先建接缝）、ADR-0040 B2/B4、AUDIO-004 的「全仓只有一套混音路径」裁决]
output:      [core 导出音频切片、平台侧离线渲染、对齐单测]
write_set:   engine/core/cq/export/chq_export_audio.{h,cpp}（新建，EXPORT-001 卡里明让的空位）、
             engine/core/cq/audio/chq_preview_mixer.{h,cpp}、
             engine/platform/apple/media/{audio_engine.mm,media_encode.mm}、
             tests/unit/audio/、tests/unit/export/、tests/CMakeLists.txt
read_set:    engine/core/cq/base/chq_concurrency.h、engine/core/cq/render/chq_clock_source.h
deps:        [EXPORT-001, AUDIO-001, AUDIO-004]
acceptance:
  - 导出的音频与预览走**同一条**混音实现（`MixAccumulateRange` / `MixClipRange`），不得出现第二套求和
  - 音频样本数与视频帧数在同一 timescale 网格上对齐（无浮点秒，红线 4）；末段不截不断
  - 静音/禁用轨不进导出混音，与预览同语义（`!enabled || muted`）
  - 取消即止：`ChqCancelToken` 置位后不留半写文件（接 EXPORT-001 的清理判据）
  - 无锁无分配边界不破：实时音频回调内只有环读 + 原子量（红线 8），离线路径不得复用实时回调的锁
verification:
  - tools/build/build_core.sh --platform=apple --config=Debug --test --skip-label=heavy
  - ctest --test-dir build -R audio
  - ctest --test-dir build -R export
  - tools/ci/check_apple_shells.sh --shell=ios   # audio_engine.mm 只在壳里编译，SPM 档判不到（P181）
risk:        离线渲染音频若图省事直接复用 `AVAudioEngine` 的实时源节点，会把"实时线程零分配"
             那条红线拖进导出路径 —— 离线应该**不经平台音频引擎**，直接由 core 混音写 PCM 给编码器。
             这条判断要在动手前写在实现要点里，不能等 CR 才发现。
parallel:    false
```

## 建卡时核出来的三件事（都跟账面不一致，按这里改）

1. **PALA-030 的主体早已落地**：`engine/platform/apple/media/audio_engine.mm` 第 1 行自陈
   「AppleAudioEngine —— `ChqIAudioEngine` 的 Apple 实现（PALA-030）」，由 **AUDIO-002**
   的提交 `07e6cba`（2026-10-11）带进来。所以本卡**不是**从零做后端，射程收窄为上表的离线音频切片。
2. **三处过期陈述要订正**：`.ai/modules/audio.md` 的「未落地：… PALA-030」、
   `.ai/modules/ui-apple.md` 里 UIA-015 段落引的 ADR-0022 理由「自研预览线无声（PALA-030 未实现）」、
   `docs/research/RESEARCH-010` 同句。前两条是本卡的回写项，第三条在 legacy 域之外才改。
3. **连带后果已核并已裁**：`docs/tasks/PLAN-播放器进阶.md:59-60` 的立项触发条件是**两件的合取**（连接词在下一行）
   （PALA-030 落地 **且** 产品要求"成片预览与导出画面一致"或三端统一播放行为）。
   按 1 的事实只满足**前一件**，后一件没被提出过 → **整体未触发**。
   传哲 2026-10-17 21:3x 裁定：**先记账，v0.2.0 不动播放器线**（不自研替换 AVPlayer）。

## 明确不做（写进代码注释，不只在对话里说）

- `OpenInput` / `Read` 仍返回 `kDecodeUnsupported`：采集侧走 `AVAssetWriter` 自有链路，
  本期无消费者；旁白/配音落地时再实现。
- 规格只支持 Float32 交错 stereo（与预览混音器输出锁定），其它规格 `kInvalidArgument` 拒绝，
  **不做静默转换**。
- iOS 打断恢复已在更早的提交里做过（`b471b8c` 的 #18），本卡只补回归单测，不重做。

## 回写

`.ai/modules/audio.md`（落地状态节 + 订正第 2 条）、`.ai/modules/media.md`（平台引擎行）、
`docs/tasks/TASK-BACKLOG.md` §4.2 行状态、`docs/tasks/PLAN-播放器进阶.md` 触发条件行（改为"前件已满足、合取未触发，v0.2.0 不动"）。
