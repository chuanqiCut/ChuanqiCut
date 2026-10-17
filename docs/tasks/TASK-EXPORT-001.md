# TASK-EXPORT-001：导出控制器（状态机 / 进度 / 取消 / 错误码）

```yaml
id:          TASK-EXPORT-001
layer:       跨平台
goal:        把"逐帧步进渲染 → 编码 → 封装"收成一个可取消、可报进度、错误码明确的导出控制器
input:       [ARCH-001 §7（预览与导出共用图）、ADR-0040 B4、RENDER-001 ✅、红线 8/9]
output:      [core 导出目录与控制器、编码器接缝、cq_export_* ABI、单测、接口文档]
write_set:   engine/core/cq/export/{chq_export_controller,chq_export_state}.{h,cpp}（新建目录；
               **音频切片明让给 PALA-030**，本卡不建 `chq_export_audio.*`，只留接缝）、
             engine/core/cq/cq_sdk.{h,cpp}（`cq_export_*`，高冲突=集成机）、
             engine/core/cq/platform/chq_media.h（编码器接缝）、
             engine/platform/apple/media/{media_encode.h,media_encode.mm}（实现该接缝）、
             tests/unit/export/（新建）、tests/CMakeLists.txt、docs/api/engine-api.md
read_set:    engine/core/cq/render/*、engine/core/cq/preview/*、engine/core/cq/audio/chq_preview_mixer.{h,cpp}、
             engine/core/cq/base/chq_concurrency.h
deps:        [RENDER-011, MEDIA-012, CORE-005, AUDIO-004]
acceptance:
  - 导出帧数 = 时长 × fps，一帧不漏（步进时钟断言）；**误用实时时钟必须在第一次调用就报错**而不是静默多渲
  - 取消：`ChqCancelToken` 置位后 ≤1 帧内停下，返回 kCancelled 且**不当作错误**（不弹红、不计失败率）
  - 取消与失败路径把临时文件清干净（单测建临时目录、导出后断言为空）
  - 进度回调单调不减、终态恰好一次（不会既 complete 又 error）
  - 装配代码只有一份：导出与预览共用 `chq_graph_assembler`，只换输出目标与时钟源（红线 9，grep 级核验）
  - 公共头零平台类型：`media_encode.h` 里的 `CVPixelBufferRef` 不得出现在 `cq_sdk.h` / `chq_media.h` 可见面
verification:
  - tools/build/build_core.sh --platform=apple --config=Release --test   # 导出走 heavy 例，Release 才跑满
  - ctest --test-dir build -R export
  - "${PYTHON_BIN:-python3}" tests/golden/verify.py --json
  - tools/ci/check_apple_shells.sh            # 动了公共头，双壳必须真编（池 [18] 就是为这个洞开的）
  - tools/ci/gate_scope.sh                    # 本卡闭环前按它吐的窄检跑，L3 归批末那一趟
risk:        **编码器接缝是新增抽象**：core 侧今天没有任何 encoder 接口，
             `engine/platform/apple/media/media_encode.h` 的 `AppleVideoEncoder` 是一个平台裸类。
             先立接缝、再接控制器 —— 顺序反过来会把平台类型漏进公共头（红线 2），
             而那是要改集成机的高冲突文件才能回滚的错误。
parallel:    false
```

## 背景

编辑器的导出按钮自 UIA 早期就是置灰（`ui/.../EditorScreen.swift` 里 `.disabled(true)`），
因为内核从来没有导出线。B4 的交付物就是这个按钮能用。

链上排在 [TASK-RENDER-011](TASK-RENDER-011.md) 之后：先让画面合成对了，再导出"所见"。

## 依赖实况（2026-10-17 建卡时逐个核过）

| 依赖 | BACKLOG 声明 | 实况 |
|---|---|---|
| MEDIA-012 | 未标状态 | ✅ 已落地（`ChqDecoderPool`，2026-09-27），**磁盘无卡**，归口在 `.ai/modules/media.md` |
| CORE-005 | 未标状态 | ✅ 已落地（`ChqCancelToken` / `ChqBoundedQueue`，2026-09-25），磁盘无卡 |
| RENDER-001 | — | ✅ 但**真机问卷未回收**（ADR-0034）；本卡不因此阻塞，批末那次真机一起收 |
| RENDER-003（LOD） | EXPORT-002 的依赖 | ❌ 未落地，且号有漂移（`.ai/modules/render.md` 记作 RENDER-004/005）→ **EXPORT-002 不在 v0.2.0 射程**，本卡不依赖它 |

## 范围之外（写明，别在编码时临时加）

- 导出**音频**落盘 = [TASK-PALA-030](TASK-PALA-030.md) 的剩余射程（本卡只留接缝）。
- GIF / LivePhoto 导出 = EXPORT-010/011，依赖尚未定稿的 ADR-0028 与相册授权口径。
- 4K / 长片 / 失败恢复的端到端测试 = EXPORT-003。

## 回写

`.ai/modules/core.md`（新目录 + 命令表）、`docs/api/engine-api.md`（`cq_export_*` 全签）、
`docs/tasks/TASK-BACKLOG.md` §3.6 行状态、`.ai/memory/baselines.md`（导出耗时 vs 分辨率实测）、
公共头变更走集成机面客流程（不新增 ADR 则写明理由）。
