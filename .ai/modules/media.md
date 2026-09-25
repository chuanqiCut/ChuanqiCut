# 模块：媒体管线

**边界**：
- 接口定义（跨平台层，MEDIA-010）：`core/include/cq/media/frame_provider.h`
- 跨平台实现（MEDIA-011/012/020 阶段）：`core/src/media/`、`core/src/retime/`
- 平台实现（PALA-/PALD-）：`pal/<platform>/media_*`

**权威契约**：`docs/specs/PAL-接口契约.md` §4.2（Media demux + 精确 seek + IFrameProvider）、
`docs/specs/ARCH-003` §3（零拷贝路径）。**本文件**：模块运行记录 + 设计取舍摘要
（MEDIA-010 接口冻结于 2026-09-25）。

## 两层架构（2026-09-25 确立）

| 层 | 类型 | 是什么 | 谁实现 |
|---|---|---|---|
| **PAL Media 后端** | `pal/media.h` 的 `IFrameProvider` | 平台解码后端：demux+解码之上「按 pts 取帧」，承诺精确 seek，lease 模型 | PALA-010/011 Apple、MEDIA-021 FFmpeg |
| **跨平台媒体编排** | `media/frame_provider.h` 的 `FrameProvider` | 编辑侧帧接口：聚合 PAL 后端，收口精确 seek 策略 / 帧缓存 / 解码器池 | MEDIA-020 SystemFrameProvider |

- PAL `IFrameProvider` = **平台能力**（系统/FFmpeg 解码进代码库）。
- `FrameProvider` = **上层编排**（编辑侧消费的唯一帧接口，位于 PAL 之上）。
- 精确 seek 的*机制*由 PAL 后端 + MEDIA-020 实现；MEDIA-010 规定*正确性契约*与*策略 API*。

## 核心抽象（MEDIA-010 落地）

```cpp
enum class SeekPolicy { kExact, kKeyframeBefore, kNearest };  // 精确 seek 策略
struct FrameRequest { RationalTime at; SeekPolicy policy = kExact; bool proxy_quality; };

class FrameProvider {                 // 跨平台帧接口（抽象，MEDIA-020 实现）
  Status Open(const MediaSource&);
  Status Seek(t, SeekPolicy, CancelToken);
  Status AcquireFrame(FrameRequest, MediaFrame&, CancelToken);  // lease 模型
  void   ReleaseFrame(MediaFrame&);
  Status GetDuration(RationalTime&) const;
  void   SetFrameCache(IFrameCache*);      // MEDIA-011 钩子
  void   SetDecoderPool(IDecoderPool*);    // MEDIA-012 钩子
};
```

三个实现（规划）：
- `SystemFrameProvider`（MEDIA-020，MVP 默认）：Apple=AVAssetReader/VB，Android=MediaExtractor+MediaCodec。
- `FFmpegFrameProvider`（MEDIA-021）：精确 seek / 倒放 / 速度曲线，与系统后端**同 seek 同结果**。
- 两者行为必须一致（同 seek 请求同帧，PSNR≥45dB，BACKLOG MEDIA-021 验收）。

`TimeMap(timelineTime) -> sourceTime`（MEDIA-013）：恒速 / 速度曲线 / 倒放，三实现同一接口。

## 精确 seek 语义（MEDIA-010 核心，评审重点）

- 「t 处的帧」= 展示区间归属：**pts <= t < pts + duration** 的那一帧（默认；倒放/曲线边界待评审拍板）。
- `kExact` 机制：demux→最近关键帧（PAL 吸收平台差异）→ 前向解码丢弃 t 之前的帧 →
  继续解码到「t 帧及其解码依赖（B 帧参考帧）全部可重建」才返回 t 展示帧。**绝不**在拿到
  t 的压缩包即返回。
- `kKeyframeBefore`：返回 <=t 最近关键帧（快，非 t 展示帧），用于缩略图/占位。
- `kNearest`：实现自行权衡速度/接近度，返回前或后最近可解码帧。
- 取消：`Seek`/`AcquireFrame` 接受 CancelToken，取消返回 `kCancelled`（非错误）。

## 平台差异（务必注意，与上版本一致）

| 差异 | 处理 |
|---|---|
| Android seek 只能到关键帧 | 统一为「精确 seek 语义」：内部到关键帧后向前解码到目标帧 |
| YUV stride 对齐不同 | 在 PAL 内统一，上层无感 |
| 硬解实例数受限 | DecoderPool（MEDIA-012）调度 + 降级软解，超路数不崩溃 |
| iOS 无 FFmpeg 也能跑 | FFmpeg 是可选后端，非必需 |

## 为下游留的接口位置（MEDIA-010 定义，后续实现）

- **MEDIA-011（帧缓存 LRU）**：实现 `IFrameCache`（write_set core/src/media/cache.*），
  内存上界接 CORE-004 TextureBudget/MemoryBudget（1080p≤400MB / 4K≤1.2GB）。
- **MEDIA-012（DecoderPool）**：实现 `IDecoderPool`（core/src/media/decoder_pool.*），
  用 opaque `DecoderHandle`；超硬解路数降级软解，返回 kResourceExhausted 而非崩溃。
- **MEDIA-020（SystemFrameProvider）**：实现抽象 `FrameProvider`，实现精确 seek 机制。
- **MEDIA-021（FFmpeg 后端）**：另一 `FrameProvider` 实现，与系统后端一致性自测。

## 硬约束满足方式

1. **零平台类型**：仅 base + PAL 类型；无平台类型、无平台头、无 AV* / ffmpeg 类型。
   门禁 `tools/pal/check_pal_headers.py` 已扩展覆盖 `cq/media/`（见 `pal_header_gate`）。
2. **统一 base 类型**：RationalTime / Status / CancelToken；lease 模型与 PAL 一致。
3. **`-Werror` 零警告**：编译 TU `tests/unit/media_frame_provider_compile.cpp` 干净编译。
4. **内核禁用异常**：无 throw。

## 待评审 / 风险（已标出）

- 「t 处帧」采用展示区间归属（pts<=t<pts+dur）还是 PTS 最近匹配——倒放/速度曲线下边界
  行为需评审拍板（hypothesis：默认区间归属）。
- `FrameProvider` 抽象类（非 PAL 资源），生命周期由调用方 unique_ptr 持有；若后续 C ABI
  暴露需统一句柄语义（BIND 层处理）。
- `DecoderHandle` 为 opaque 指针；MEDIA-012 在其后定义真实解码器包装（不暴露平台类型）。

## 验证（2026-09-25 真跑）
```bash
CMAKE_BIN=/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake
$CMAKE_BIN --build build -j4 && $(dirname $CMAKE_BIN)/ctest --test-dir build
# 原 8 + gfx_headers_compile + media_frame_provider_compile + pal_header_gate(已覆盖 gfx/media)
```
- 门禁自测：`check_pal_headers.py` 对 `cq/media/` 零违规（EXIT=0）。

## 相关
ADR-0003、ARCH-003 §3、PAL-接口契约 §4.2、BACKLOG MEDIA-010/011/012/020/021、ARCH-004
