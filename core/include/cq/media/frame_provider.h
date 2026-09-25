// ChuanqiCut — 跨平台 FrameProvider 抽象与精确 seek 语义（MEDIA-010）
//
// ┌────────────────────────────────────────────────────────────────────────┐
// │ 与 PAL `IFrameProvider` 的关系（务必先读，避免与 PAL 混淆）                │
// ├────────────────────────────────────────────────────────────────────────┤
// │ PAL `IFrameProvider`（pal/media.h，CORE-006 冻结）是**平台解码后端**：      │
// │ 在 demux+解码之上提供「按 pts 取帧」，承诺精确 seek，采用 lease 模型        │
// │ （AcquireFrame / ReleaseFrame）。由各平台实现（PALA-010/011 Apple、       │
// │ MEDIA-021 FFmpeg）落地，是「平台能力」层。                                │
// │                                                                        │
// │ 本文件的 `FrameProvider`（MEDIA-010）是**跨平台媒体编排层**，位于 PAL 之上：│
// │   * 持有（或聚合）一个 PAL `IFrameProvider`，把「精确 seek 策略选择」       │
// │     （精确 / 最近关键帧 / 最近帧）、帧缓存（MEDIA-011）、解码器池          │
// │     （MEDIA-012）的*编排*收口到一处，供编辑侧（retiming / 预览 / 导出）使用。│
// │   * 规定「精确 seek 的正确性契约」：返回帧必须是 target 处**真正的展示帧**， │
// │     而非关键帧（B 帧/GOP 让这件事不平凡，见 §「精确 seek 语义」）。         │
// │ 具体实现 = MEDIA-020 SystemFrameProvider（系统解码后端）。                 │
// └────────────────────────────────────────────────────────────────────────┘
//
// 硬约束（与 CORE-006 一致）：
//   * 零平台类型：只使用 base 层 + PAL 的 opaque 句柄与类型，绝不出现任何平台类型、
//     不 include 平台头、不出现 AV* / ffmpeg 类型。
//   * 统一 base 类型：时间 RationalTime、错误 Status、长任务 CancelToken。
//   * 内核禁用异常：无 throw。
//
// 本任务只定义接口 + 语义契约，不实现（实现由 MEDIA-020 落地）。

#ifndef CQ_MEDIA_FRAME_PROVIDER_H_
#define CQ_MEDIA_FRAME_PROVIDER_H_

#include <cstddef>
#include <cstdint>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/status.h"       // Status
#include "cq/base/time.h"         // RationalTime
#include "cq/pal/common.h"        // opaque 句柄、平台无关枚举
#include "cq/pal/media.h"         // PAL IFrameProvider / MediaSource / MediaFrame（本层之下）

namespace cq {

// ===========================================================================
// 1. 精确 seek 策略（MEDIA-010 的核心决策点）
// ===========================================================================
// 视频编辑对「按时间戳取帧」有强正确性要求：给定 t，预览/导出必须拿到 t 处那一帧。
// 但 B 帧/GOP 让「精确取到 t 的展示帧」不平凡——解码顺序(DTS) ≠ 显示顺序(PTS)，
// 一个 B 帧可能引用其后的 P 帧，故要重建 t 处的展示帧，往往需解码到 t *之后*。
enum class SeekPolicy : int32_t {
    // 精确：返回 target 处真正的展示帧（见下方「语义」）。编辑默认、导出/单帧必备。
    kExact = 0,
    // 回退到 target 之前最近关键帧：最快，但返回的**不是** target 展示帧。
    // 用于缩略图擦除、对精确性不敏感的预览占位。
    kKeyframeBefore,
    // 实现自行选择前/后最近可解码帧（速度优先，精确性次之）。用于快速 scrub 占位。
    kNearest,
};

// 取帧请求（编辑侧驱动 seek 的入参）。
struct FrameRequest {
    RationalTime at = {};                 // 目标时间戳（项目 timescale 网格 120000）
    SeekPolicy policy = SeekPolicy::kExact;  // 默认精确 seek（编辑正确性优先）
    // 预留：代理/原片质量档（EDIT-006 代理工作流驱动），本任务留位不展开。
    bool proxy_quality = false;
};

// ===========================================================================
// 2. 精确 seek 语义（写在契约里，实现由 MEDIA-020 保证）
// ===========================================================================
// 定义「t 处的帧」：采用**展示区间归属**——即 pts <= t < pts + duration 的那一帧
// （duration 取自该帧显示时长；末帧用流时长收尾）。这是编辑侧最自然的语义：
// 时间轴上的点落在哪一帧的展示区间内，就取哪一帧。
//
// kExact 的内部机制（交由 PAL 后端 + MEDIA-020 实现，此处规定契约）：
//   1. 把 demuxer seek 到「<= t 的最近关键帧」（PAL 吸收各平台差异：Android
//      MediaCodec 只能关键帧级 seek、AVFoundation/VB 可更细，PAL 统一为「先到关键帧」）。
//   2. 从关键帧起前向解码，**丢弃**显示顺序在 t 之前的所有帧。
//   3. 解码到「展示区间为 t 的那个帧」：由于 B 帧可能引用其后帧，必须继续解码到
//      t 帧及其解码依赖（参考帧）全部可重建为止，才返回 t 帧的展示结果。
//      —— 即实现不得在「拿到 t 的压缩包」时即返回，必须确认 t 帧已可正确重建。
//   4. 返回该帧（lease 模型，见 FrameProvider）。
//
// kKeyframeBefore：跳过上面对「重建到 t」的要求，直接返回 <= t 最近关键帧
//   （不保证是 t 的展示帧）；用于可牺牲精确性的快速场景，避免无谓解码开销。
//
// kNearest：实现在「解码开销」与「接近 t」间自行权衡，返回前或后最近可解码帧。
//
// ★ 取消语义：所有长任务（Seek / AcquireFrame）接受 CancelToken；检测到取消返回
//   kCancelled（Status::IsError()==false），调用方据此做清理而非报错。
//
// ★ 待评审确认（已标出，hypothesis）：「t 处帧」采用展示区间归属（pts<=t<pts+dur）
//   还是「PTS 最近匹配」。区间归属更契合连续预览；倒放/速度曲线（MEDIA-013）下两
//   者边界行为需评审拍板。本契约默认区间归属，但 FrameRequest 不带额外 flag，
//   若评审要求切换语义，仅改策略映射、不改接口形状。

// ===========================================================================
// 3. IFrameCache — 帧缓存抽象（MEDIA-011 实现；MEDIA-010 仅定义接口位置）
// ===========================================================================
// 帧缓存 LRU 是跨平台核心逻辑（MEDIA-011，write_set core/src/media/cache.*）。
// 内存上界由 CORE-004 TextureBudget / MemoryBudget 约束（ARCH-002 §10.2：
// 1080p 三轨预览 ≤400MB，4K ≤1.2GB）。FrameProvider 实现持有 IFrameCache 做 LRU 回收。
// 缓存键为 pts（RationalTime），值为解码后 MediaFrame 的缓存副本/引用。
class IFrameCache {
public:
    virtual ~IFrameCache() = default;

    // 查找 at 处是否已有缓存帧；命中写入 out 并返回 true（out 复用 PAL lease 语义，
    // 内存归缓存所有，调用方用毕须经缓存归还，不重复释放）。
    virtual bool Find(const RationalTime& at, MediaFrame& out) = 0;

    // 存入一帧（lease 语义：缓存接管 frame 的 ownership 直到被回收/Release）。
    virtual Status Insert(const RationalTime& at, const MediaFrame& frame) = 0;

    // 当前缓存占用字节（用于超预算 LRU 淘汰决策）。
    virtual int64_t UsedBytes() const = 0;
};

// ===========================================================================
// 4. IDecoderPool — 解码器池抽象（MEDIA-012 实现；MEDIA-010 仅定义接口位置）
// ===========================================================================
// 解码器池是跨平台核心逻辑（MEDIA-012，write_set core/src/media/decoder_pool.*）。
// 超硬解路数时降级不崩溃：池满则排队或降级软解。FrameProvider 实现用它获取解码能力。
// 解码器本身是不透明句柄（跨平台层不暴露平台解码器类型）。
struct CqDecoder;
using DecoderHandle = CqDecoder*;

class IDecoderPool {
public:
    virtual ~IDecoderPool() = default;

    // 借一个解码器（按 codec）。池满且无法降级时返回 kResourceExhausted（不崩溃，
    // 调用方据此背压/排队）。out 为不透明解码器句柄。
    virtual Status AcquireDecoder(CodecId codec, DecoderHandle& out_decoder) = 0;
    virtual void ReleaseDecoder(DecoderHandle decoder) = 0;

    // 当前在用路数 / 硬解路数上限（来自能力查询 Capability，运行时，红线 #3）。
    virtual int32_t ActiveCount() const = 0;
    virtual int32_t MaxHardwarePaths() const = 0;
};

// ===========================================================================
// 5. FrameProvider — 跨平台「按时间戳取帧」编排抽象（MEDIA-010 核心）
// ===========================================================================
// 编辑侧消费的唯一媒体帧接口。位于 PAL IFrameProvider 之上：聚合平台解码后端，
// 收口精确 seek 策略、帧缓存（MEDIA-011）、解码器池（MEDIA-012）编排。
// 抽象类：具体实现 = MEDIA-020 SystemFrameProvider（系统解码后端）。
// 生命周期：跨平台对象，由调用方以 std::unique_ptr 等持有（非 PAL 资源，不用 PalPtr）。
class FrameProvider {
public:
    virtual ~FrameProvider() = default;

    // 打开媒体源（复用 PAL MediaSource；图片走 GFX 导入，不在此）。
    virtual Status Open(const MediaSource& src) = 0;

    // 精确 seek（编辑核心能力）。语义见文件头「精确 seek 语义」一节。
    //   policy 默认 kExact；长任务接受 CancelToken；取消返回 kCancelled（非错误）。
    virtual Status Seek(const RationalTime& target, SeekPolicy policy,
                        const CancelToken& token) = 0;

    // 取 target 处帧（lease 模型，与 PAL 一致）：video.image / audio.pcm 由 provider
    // 内部池所有，调用方使用期间不得释放；用毕必须 ReleaseFrame 归还，供 MEDIA-011 LRU 回收。
    virtual Status AcquireFrame(const FrameRequest& req, MediaFrame& out_frame,
                                const CancelToken& token) = 0;

    // 归还帧（image / pcm 内存回到 provider 池）。
    virtual void ReleaseFrame(MediaFrame& frame) = 0;

    // 查询时长（复用 RationalTime，项目 timescale 网格）。
    virtual Status GetDuration(RationalTime& out) const = 0;

    // 注入帧缓存（MEDIA-011）/ 解码器池（MEDIA-012）。不注入则退化为无缓存 / 单路解码。
    virtual void SetFrameCache(IFrameCache* cache) = 0;
    virtual void SetDecoderPool(IDecoderPool* pool) = 0;
};

}  // namespace cq

#endif  // CQ_MEDIA_FRAME_PROVIDER_H_
