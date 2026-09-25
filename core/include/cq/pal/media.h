// ChuanqiCut — PAL Media 抽象接口（CORE-006 / MEDIA-010 / MEDIA-020 / MEDIA-021）
//
// 职责：demux（解封装）、精确 seek、帧提供。
// 下游 MEDIA-010（FrameProvider 接口与语义）将基于此实现；MEDIA-020（SystemFrameProvider）
// 与 MEDIA-021（FFmpeg demux 后端）共享同一语义。MediaCodec/AVFoundation/FFmpeg 的差异
// 由各 PAL 实现在内部吸收，core 层看到的是统一接口。
//
// ★ 零 FFmpeg 类型：本文件不出现任何 AV* 类型、不 include 任何 ffmpeg 头。
//   demux 产物是本项目自己的 MediaPacket / MediaFrame，而非 AVPacket / AVFrame。
//   ContainerFormat / CodecId 是本项目枚举，与 AVCodecID 解耦（FFmpeg 后端在 PAL 内映射）。
//
// ★ HEIC/HEIF 不在 FFmpeg 支持范围内（FFmpeg 9.0.2 无该 demuxer），而 HEIC 是 iPhone
//   默认照片格式。故「图片导入」不塞进 IMediaDemuxer，而是走 GFX 的 INativeImageImporter
//   （ImageIO/Photos/CoreGraphics 等原生 API）。本契约把图片与视频容器分离。
//
// 红线：零平台类型、统一 base 类型（RationalTime / Status / CancelToken）。

#ifndef CQ_PAL_MEDIA_H_
#define CQ_PAL_MEDIA_H_

#include <cstdint>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/time.h"          // RationalTime
#include "cq/pal/audio.h"          // PcmBuffer（音频帧复用）
#include "cq/pal/common.h"

namespace cq {

// 媒体来源：视频/音频容器文件的 UTF-8 路径。图片（HEIC 等）不走此路径，走 GFX 导入。
struct MediaSource {
    const char* path = nullptr;
    size_t path_len = 0;
};

// 单条轨道信息。
struct StreamInfo {
    MediaType type = MediaType::kUnknown;
    CodecId codec = CodecId::kUnknown;
    RationalTime time_base;  // 该轨道时间基（有理数）
    uint32_t width = 0;      // 视频：宽
    uint32_t height = 0;     // 视频：高
    uint32_t sample_rate = 0;// 音频：采样率
    uint32_t channels = 0;   // 音频：声道数
    PixelFormat pixel_format = PixelFormat::kUnknown;  // 视频建议像素格式
    ColorSpace color_space = ColorSpace::kUnknown;      // 视频色彩属性（ARCH-003 §8）
};

// 压缩包（demux 产物，不含 AVPacket）。data 由 demuxer 所有，生命周期见实现约定
// （通常对下次 ReadPacket / Close 之前有效）。
struct MediaPacket {
    int32_t stream_index = -1;
    RationalTime pts;
    RationalTime dts;
    CodecId codec = CodecId::kUnknown;
    const uint8_t* data = nullptr;
    size_t size = 0;
    bool is_keyframe = false;
};

// 解码后视频帧（image 为 opaque 原生图像句柄，零拷贝可达）。
struct VideoFrame {
    NativeImageHandle image = nullptr;
    PixelFormat pixel_format = PixelFormat::kUnknown;
    ColorSpace color_space = ColorSpace::kUnknown;
    uint32_t width = 0;
    uint32_t height = 0;
    RationalTime pts;
    RationalTime duration;
};

// 解码后音频帧（复用 PcmBuffer）。
struct AudioFrame {
    PcmBuffer pcm;
    RationalTime pts;
    RationalTime duration;
};

// 统一媒体帧（tagged）。type 决定 video/audio 哪个有效。
struct MediaFrame {
    MediaType type = MediaType::kUnknown;
    VideoFrame video;
    AudioFrame audio;
};

// ---------------------------------------------------------------------------
// IMediaDemuxer：解封装（仅容器层，不含解码）
// ---------------------------------------------------------------------------
class IMediaDemuxer : public IPalResource {
public:
    virtual Status Open(const MediaSource& src) = 0;
    virtual Status GetDuration(RationalTime& out_duration) const = 0;
    virtual int32_t GetStreamCount() const = 0;
    virtual Status GetStreamInfo(int32_t index, StreamInfo& out_info) const = 0;

    // 精确 seek（统一语义）：各平台内部差异（如 Android 只关键帧级 seek）由 PAL 吸收，
    // 调用方拿到的一定是「目标时间处」的帧。长任务，接受 CancelToken。
    virtual Status Seek(const RationalTime& target, const CancelToken& token) = 0;

    // 读下一个压缩包。data 生命周期见 MediaPacket 注释。队列末尾返回 kIoNotFound（非错误计数）。
    virtual Status ReadPacket(MediaPacket& out_packet) = 0;
};

// ---------------------------------------------------------------------------
// IFrameProvider：在 demux + 解码之上提供「按 pts 取帧」语义
// ---------------------------------------------------------------------------
// 生命周期约定（lease 模型，避免跨层句柄所有权混乱）：
//   * AcquireFrame 填出的 MediaFrame 中，video.image / audio.pcm.data 由 provider 的
//     内部池所有；调用方在使用期间不得释放。
//   * 用毕必须调用 ReleaseFrame 归还，provider 才能回收池（MEDIA-011 缓存/LRU）。
//   * 支持正放/倒放/速度曲线：由调用方驱动 Seek，本接口本身中立。
class IFrameProvider : public IPalResource {
public:
    virtual Status Open(const MediaSource& src) = 0;

    // 精确 seek 到目标时间。Accept CancelToken。
    virtual Status Seek(const RationalTime& target, const CancelToken& token) = 0;

    // 取目标时间处的帧（经 provider 内部解码）。结果以 lease 形式返回（见类注释）。
    virtual Status AcquireFrame(const RationalTime& at, MediaFrame& out_frame,
                                const CancelToken& token) = 0;

    // 归还帧（image / pcm 内存回到 provider 池）。
    virtual void ReleaseFrame(MediaFrame& frame) = 0;
};

// 工厂（由 PAL 平台实现）。返回 PalPtr。
Status CreateMediaDemuxer(const MediaSource& src, PalPtr<IMediaDemuxer>& out_demuxer);
Status CreateFrameProvider(const MediaSource& src, PalPtr<IFrameProvider>& out_provider);

}  // namespace cq

#endif  // CQ_PAL_MEDIA_H_
