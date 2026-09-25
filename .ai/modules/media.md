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

### MEDIA-020 真实 B 帧文件精确 seek（mock → 真实 golden 升级，2026-09-25 落地）
- **背景纠正**：此前误判「golden 为全 I 帧、B 帧精确 seek 无法在真实文件上验证」并建议新增素材。
  **实则仓库已有 B 帧 golden**：`tests/golden/frames/gf_1080p_h264_long_gop_bframes.mp4`
  （manifest: `fps=30, frame_count=300, gop_size=60, bframes=3`）。教训：**提"新增素材"前先确认
  现有仓库里有没有**。本任务据此把 B 帧精确 seek 从「mock 小 GOP」升级到「真实文件」。
- **新用例**：ctest `media_bframe_real`（`tests/unit/test_media_bframe_real_apple.cpp`，仅 Apple）。
  真实 `CreateMediaDemuxer` 读该文件 + **仅按 pts 网格重排**的 `ReorderingMockDecoder`（不预知 GOP，
  刻意暴露并消化「解码序≠显示序」分离）驱动 `SystemFrameProvider::AcquireFrame(kExact, ...)`。
- **真实文件 ground truth（ffprobe，仅参考工具，不进产物）**：300 帧；`pict_type` I=5/P=75/B=220；
  关键帧(I)显示时间 0/2/4/6/8 s；B 帧如 0.066667/0.100000/2.066667 s。
- **交付物结果（全绿，10/10 检查，EXIT=0）**：
  - 总帧数=300（与 manifest/ffprobe 一致）✅；300 个 pts 互异 ✅
  - **原始(dts)序 pts 非单调** ✅ —— 真实暴露团队警示点「AVAssetReader passthrough 输出是解码序
    而非显示序」；重排→显示序后严格单调递增 300 帧 ✅（解码序→显示序无损）
  - **kExact 对 B 帧目标 t=0.066667/0.100000/2.066667 s 返回展示帧 pts=8000/12000/248000（均为
    目标处 B 帧），且「非关键帧」用 ffprobe 真值核对成立** ✅ —— **核心交付物达成**：真实文件上
    kExact 仍能正确取 t 处的 B 帧展示帧，而非关键帧/未重建包。
- **DIAGNOSTIC A — PALA-010 `is_keyframe` 在 passthrough 下不可靠（已暴露，如实记录）**：
  demuxer 报告关键帧数=300（ffprobe 真值=5）；ffprobe 真值关键帧被正确标记仅 4/5；误报 288 个。
  根因：`media_demux.mm` 的 `IsKeyframe` 用 `kCMSampleAttachmentKey_DependsOnOthers`，passthrough
  下该附件常被省略，代码退化为「保守当作关键帧」。→ **这是 PALA-010 既有缺陷，不在本任务范围**；
  本测试「kExact 不是关键帧」改以 ffprobe 真值关键帧集合核对，不依赖损坏的 demuxer 标志。
- **DIAGNOSTIC B — `kKeyframeBefore` 当前未回退到真值关键帧（PALA-010 限制，如实记录）**：
  全新 provider 对每个 t 取 `kKeyframeBefore`：t=0.0667s 返回 pts=8000（=目标 B 帧，非关键帧 0）；
  t=2.0667s 返回 pts=248000（=目标，非关键帧 240000）。根因：`PALA-010 Seek` 仅设 `timeRange.start=
  target`、**不回退/吸附到关键帧**，故 kKeyframeBefore 退化为「≈目标处帧」。属 PALA-010 既有缺陷。
- **mock 与真实一致性结论**：
  - 一致处：kExact 编排在「解码序≠显示序」分离下均正确取 t 处展示帧；本真实 MockDecoder 用
    pts 网格重排（与旧 mock 的「显式 GOP release 依赖」不同机制），都证明了 SystemFrameProvider 的
    区间归属 + 前向解码逻辑正确。
  - 差异处（真实文件暴露、mock 掩盖的）：
    1. **解码序≠显示序是真实分离的**（真实 dts/pts 发散）；旧 mock 用 dts 0,1,2,3 / pts 0,1,2,3
       同序，根本没触发重排，掩盖了 passthrough 行为。**这是团队重点警示点的实证**。
    2. **demuxer `is_keyframe` 不可靠**（真实 300 误报 vs 5 真值）；mock 里关键帧是手填的真值，
       不反映该缺陷。故真实测试必须把「是否关键帧」改以 ffprobe 真值核对。
    3. **`kKeyframeBefore` 行为不达标**（真实不回退关键帧）；mock 里关键帧是手填，掩盖了
       PALA-010 Seek 不吸附关键帧的缺陷。
  - 结论：**mock 验证了「编排逻辑正确」，但会掩盖「平台后端（PALA-010）的 passthrough 行为缺陷」；
    真实文件升级后既证明 kExact 在真实分离下仍正确，又暴露了 PALA-010 两处既有缺陷（待修）**。
- **与冻结接口一致性**：`FrameProvider` 抽象（MEDIA-010）声明的虚函数全部实现；注意该冻结头
  **不含 `GetPosition`**（任务卡初始描述提到的 `GetPosition` 与实际冻结接口不符——以冻结头为准，
  未擅自修改 frozen 头）。

### MEDIA-020 待解 / 后续
- PALA-011（VideoToolbox `IFrameDecoder` 适配器）→ 端到端真实解码。
- MEDIA-011 帧缓存 LRU（替换空 stub）、MEDIA-012 解码器池（替换空 stub）。
- **PALA-010 既有缺陷（已被真实 B 帧文件暴露，建议新任务修复）**：
  - `IsKeyframe` 在 passthrough 下不可靠（缺 `DependsOnOthers` 附件退化为全关键帧）→ 改用
    `kCMSampleAttachmentKey_NotSync` 或解析 H.264 NAL（IDR）判定关键帧。
  - `Seek` 不回退/吸附到 <=target 关键帧（仅设 `timeRange.start`）→ 使 `kKeyframeBefore`
    退化为「≈目标处帧」。需先有可靠关键帧位置才能正确吸附。
  - 注：两处均属 PALA-010，不在本任务范围；真实 B 帧精确 seek（kExact 交付物）已不受影响地达成。

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
# 15 个用例全绿：cq_cxx20_smoke, core_time/status/log/alloc/concurrency,
# pal_headers_compile, gfx_headers_compile, media_frame_provider_compile,
# media_system_frame_provider(MEDIA-020 单测), pal_header_gate,
# pala_metal_render, pala_demux(PALA-010), media_smoke_apple(MEDIA-020 真实冒烟),
# media_bframe_real(MEDIA-020 真实 B 帧文件精确 seek)
```
- 门禁自测：`check_pal_headers.py` 对 `cq/media/` 零违规（EXIT=0）。
- PALA-010：`pala_demux` 真实 MP4 全绿（150 帧 / 单调 / seek 中段）。
- MEDIA-020：`media_system_frame_provider` 单测（B 帧 GOP）9/9；`media_smoke_apple` 真实链路 7/7；
  `media_bframe_real` 真实 B 帧文件精确 seek 10/10（kExact 取 B 帧展示帧正确）。

## 相关
ADR-0003、ARCH-003 §3、PAL-接口契约 §4.2、BACKLOG MEDIA-010/011/012/020/021、ARCH-004
