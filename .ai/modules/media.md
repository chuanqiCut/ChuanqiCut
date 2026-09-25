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

三个实现：
- `SystemFrameProvider`（MEDIA-020，**已落地 2026-09-25**）：核心编排，聚合 PAL 解封装 +
  解码接缝 `IFrameDecoder`；精确 seek 语义（kExact/kKeyframeBefore/kNearest）完整实现并经
  B 帧 GOP 单测验证。Apple 解码后端经 `IFrameDecoder` 接缝接入（PALA-011 未做，见下）。
- `FFmpegFrameProvider`（MEDIA-021，规划）：精确 seek / 倒放 / 速度曲线，与系统后端**同 seek 同结果**。
- 两者行为必须一致（同 seek 请求同帧，PSNR≥45dB，BACKLOG MEDIA-021 验收）。

`TimeMap(timelineTime) -> sourceTime`（MEDIA-013，规划）：恒速 / 速度曲线 / 倒放，三实现同一接口。

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

## 实现进度与真跑记录（PALA-010 + MEDIA-020，2026-09-25 落地）

### PALA-010 — Apple 解封装后端（AVFoundation / AVAssetReader）✅ 完成
- **实现文件**：`pal/apple/media_demux.mm`（类 `AppleDemuxer`，工厂 `CreateMediaDemuxer`）。
- **机制**：`AVURLAsset` + `AVAssetReader` + `AVAssetReaderTrackOutput`（outputSettings=nil
  ⇒ passthrough 压缩数据，不含解码，符合「demux 不含解码」契约）。
- **CMTime→RationalTime**：统一 `Rescale` 到项目网格 **120000**，非整除显式 `RoundMode`
  （时间戳用 `kRound`、关键帧锚点用 `kFloor`），绝不默认舍入（ADR-0009）。
- **零字节样本过滤**：passthrough 会吐出 H.264 参数集/priming 等**零字节样本**，会破坏
  pts 单调性；`ReadPacket` 内部 `do/while` 跳过 `size==0` 的样本，只对外吐有效编码包。
- **真实 MP4 验收**（ctest `pala_demux`，样本 `tests/golden/frames/gf_1080p_h264.mp4`）：
  - 流数量=1、codec=H.264、1920×1080 ✅
  - 时长 `600000/120000`（=5.0s），与 manifest 一致 ✅
  - **总帧数=150**（与 manifest `frame_count=150` 完全一致）✅
  - **pts 全程单调递增**（零字节过滤后）✅
  - **Seek(2.5s) 后首包 pts=240000/120000（2.0s）**，确认从中段继续而非从头 ✅
  - 关键帧识别：用 `kCMSampleAttachmentKey_DependsOnOthers`，缺失时保守当关键帧。
- **红线**：零 FFmpeg 类型；平台类型（AV*/CM*/`__strong`）仅出现在本 `.mm`；core 头零平台类型。
- **未做**：PALA-011（VideoToolbox 解码后端）不在本次范围。

### MEDIA-020 — SystemFrameProvider（跨平台编排）✅ 完成
- **实现文件**：`core/include/cq/media/system_frame_provider.h` + `core/src/media/system_frame_provider.cpp`
  （类 `SystemFrameProvider : public FrameProvider`；工厂 `CreateSystemFrameProvider`）。
- **解码接缝 `IFrameDecoder`**：把「压缩包→展示帧」抽象成平台无关接口，真实实现属 PALA-011；
  `StubDecoder` 为真实链路占位（Feed 诚实返回 `kDecodeUnsupported`）；`MockDecoder`（带 B 帧 DPB
  重排）用于单测。core 不反向依赖 PAL：demuxer（`PalPtr<IMediaDemuxer>`）与 decoder 均外部注入。
- **精确 seek 机制（kExact）**：先 `demuxer.Seek(<=t 最近关键帧)` + 重置 DPB，再从关键帧前向
  解码、丢弃显示序在 t 之前的帧，直到命中「显示区间归属」`pts <= t < pts+duration` 的帧；B 帧
  依赖（其后 P 帧）在其可重建前不会由解码器弹出，故 provider 自然「继续解码到 t 帧及其依赖
  可重建」才返回。
- **kKeyframeBefore**：seek 后弹出的**首帧**即 <=t 关键帧（缩略图语义，不重建到 t）。
- **kNearest**：解码窗口内返回 `|pts - t|` 最小的可解码帧。
- **取消语义**：循环每轮检查 `CancelToken::IsCancelled()`，取消返回 `kCancelled`，`IsError()==false`。
- **钩子**：`SetFrameCache`/`SetDecoderPool` 为**空 stub 钩子**（MEDIA-011/012 后续接入）。
- **单测真跑**（ctest `media_system_frame_provider`，MockDemuxer + MockDecoder，4 帧 GOP
  `I P B B` 解码序 dts 0,1,2,3 / 显示序 pts 0,1,2,3）：
  - kExact t=0/1/2/3 → 返回 pts 0/1/**2**/3，且每帧满足区间归属 ✅（**t=2 命中 B 帧**证明
    前向解码穿越 P 帧依赖，精确 seek 正确）
  - kKeyframeBefore t=2 → 返回关键帧 pts=0（非精确帧 pts=2）✅
  - kNearest t=2 → 返回 pts=2 ✅
  - 取消 → `kCancelled` 且 `IsError()==false` ✅（9/9 检查通过）
- **真实链路冒烟**（ctest `media_smoke_apple`，真实 PALA-010 demux + `StubDecoder`）：
  - demux 侧真实打通：Open/流=1/H.264/1920×1080/时长≈5.0s ✅
  - `AcquireFrame` 在解码后端缺失下**如实返回 `kDecodeUnsupported`**，阻塞点被识别在「解码」
    而非「解封装」，**未用 mock 伪造** ✅（7/7 检查通过）
- **诚实报告**：真实视频解码被 PALA-011（VideoToolbox）阻塞；本任务 deliberately 不伪造，
  解码接缝已就位，PALA-011 落地后只需实现 `IFrameDecoder` 适配器即可端到端打通。
- **与冻结接口一致性**：`FrameProvider` 抽象（MEDIA-010）声明的虚函数全部实现；注意该冻结头
  **不含 `GetPosition`**（任务卡初始描述提到的 `GetPosition` 与实际冻结接口不符——以冻结头为准，
  未擅自修改 frozen 头）。

### MEDIA-020 待解 / 后续
- PALA-011（VideoToolbox `IFrameDecoder` 适配器）→ 端到端真实解码。
- MEDIA-011 帧缓存 LRU（替换空 stub）、MEDIA-012 解码器池（替换空 stub）。
- 真实 B 帧 GOP MP4（当前 golden 为全 I 帧 150 帧）→ 端到端精确 seek 真跑（替代 mock）。

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
# 14 个用例全绿：cq_cxx20_smoke, core_time/status/log/alloc/concurrency,
# pal_headers_compile, gfx_headers_compile, media_frame_provider_compile,
# media_system_frame_provider(MEDIA-020 单测), pal_header_gate,
# pala_metal_render, pala_demux(PALA-010), media_smoke_apple(MEDIA-020 真实冒烟)
```
- 门禁自测：`check_pal_headers.py` 对 `cq/media/` 零违规（EXIT=0）。
- PALA-010：`pala_demux` 真实 MP4 全绿（150 帧 / 单调 / seek 中段）。
- MEDIA-020：`media_system_frame_provider` 单测（B 帧 GOP）9/9；`media_smoke_apple` 真实链路 7/7。

## 相关
ADR-0003、ARCH-003 §3、PAL-接口契约 §4.2、BACKLOG MEDIA-010/011/012/020/021、ARCH-004
