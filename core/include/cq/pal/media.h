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

// ---------------------------------------------------------------------------
// IMediaMuxer：封装（mux）与编码输出（与 IMediaDemuxer 对称）
// ---------------------------------------------------------------------------
// 职责：把解码/渲染产出的视频帧（opaque NativeImageHandle）封装进容器文件（MP4 等）
// 并完成平台编码（H.264 等）。这是导出能力在 PAL 层的平台无关接缝——上层（导出控制器
// EXPORT-001 等）只持有 IMediaMuxer，不接触任何 Apple/Android 内部编码器类型。
//
// 对称设计（与 IMediaDemuxer 呼应）：Open（开容器） → AddVideoTrack（加轨）
//   → WriteVideoFrame（写帧，按 PTS 非递减） → Finish（收尾）。
//
// 硬约束（与 CORE-006 一致）：
//   * 零平台类型：帧以 opaque `NativeImageHandle` 传入，绝不出现 CVPixelBufferRef /
//     jobject / AHardwareBuffer 等；零 FFmpeg 类型（AVAssetWriter/AVPacket 等只在 PAL 内）。
//   * 统一 base 类型：时间一律 `RationalTime`（项目 timescale = 120000，ADR-0009）；
//     错误一律 `Status`；长任务（写帧/收尾）接受 `CancelToken`；内核禁用异常。
//   * 取消语义：取消返回 `kCancelled`，其 `IsError()` 为 false（取消不是错误）。
//
// 时间约定（ADR-0009）：每一帧的呈现时间戳 pts 必须是 `RationalTime`，timescale 须等于
// 轨约定网格（本期 = kProjectTimeScale = 120000）。非整除（如 1001/30000 的 NTSC 帧周期）
// 在写入前由调用方显式 `Rescale(..., kRound/kFloor)` 对齐，接口本身不做静默舍入。
//
// 音频轨：本期已实现 AAC 封装（Apple 端 `AppleMediaMuxer` → `AppleVideoEncoder`，
// 走 AVAssetWriter 的 AAC `AVAssetWriterInput`，输入为线性 PCM）。`AddAudioTrack` 建立
// 音频轨；`WriteAudioFrame` 按 `PcmBuffer` 实际格式生成线性 PCM 样本缓冲，交由封装器内部
// 编码为 `AudioTrackConfig` 指定的 AAC。压缩 AAC 码流不能直接喂入（须先解码为 PCM，
// AUDIO-001 本期未实现）——这是与视频「传 opaque 像素句柄」对称的「传 PCM 缓冲」设计。

// 码率档位（而非精确 bps）：避免把平台特定的码率数值暴露到 core 冻结接口。
// 平台实现按分辨率/格式把档位映射到本机默认码率（如 kLossless → 交平台默认）。
enum class BitrateTier : int32_t {
    kUnknown = 0,
    kLow,     // 低码率（预览/草稿导出）
    kMedium,  // 中等（默认）
    kHigh,    // 高码率（高质量归档）
    kLossless, // 高保真（像素正确性敏感的导出，交平台默认最高可达质量）
};

// 视频轨配置（muxer 侧描述，对应 demux 侧 StreamInfo 的「写」版本）。
struct VideoTrackConfig {
    CodecId codec = CodecId::kH264;   // 编码格式（本项目枚举，与 FFmpeg 解耦）
    uint32_t width = 0;
    uint32_t height = 0;
    RationalTime frame_rate{30, 1};   // 名义帧率（仅用于期望帧率/码率假设，非 PTS 网格）
    BitrateTier bitrate = BitrateTier::kMedium;  // 码率档位（非精确 bps）
    int32_t max_keyframe_interval = 30;  // GOP 长度；=1 表示全 I 帧（all-intra）
    bool allow_hardware = true;       // 优先硬件编码；不可用时软件回退（诚实，不伪造）
};

// 音频轨配置（仅预留，Apple 实现当前不产出音频轨）。
struct AudioTrackConfig {
    CodecId codec = CodecId::kAac;
    uint32_t sample_rate = 48000;
    uint32_t channels = 2;
    BitrateTier bitrate = BitrateTier::kMedium;
};

class IMediaMuxer : public IPalResource {
public:
    // 打开容器准备向 output_path（UTF-8）写入。container 指定封装格式（MP4 等）。
    // output_path 若存在由实现删除后重建（与 IMediaDemuxer::Open 对侧）。
    virtual Status Open(const char* output_path, ContainerFormat container) = 0;

    // 添加视频轨。cfg 携带 codec/分辨率/帧率/码率档位/GOP/硬编偏好。
    // 必须在任何 WriteVideoFrame 之前调用一次（多视频轨本期不支持，仅首轨生效）。
    virtual Status AddVideoTrack(const VideoTrackConfig& cfg) = 0;

    // 添加音频轨：建立 AAC `AVAssetWriterInput`（采样率 / 声道 / 码率档位来自 cfg）。
    // 必须在任意 `WriteAudioFrame` 之前调用一次；本期要求视频轨已先 `AddVideoTrack`
    // （AVAssetWriter 由视频轨建立）。不支持的 codec 返回 `kEncodeUnsupported`（诚实，不伪造）。
    virtual Status AddAudioTrack(const AudioTrackConfig& cfg) = 0;

    // 写入一帧视频。image 为 opaque 原生图像句柄（零平台类型），实现内部按源格式
    // 1:1 拷贝后 append（不得做色彩空间转换，规避通道交换类 bug，PALA-002 教训）。
    // pts 为该帧展示时间戳（timescale 须等于轨约定网格，非整除须显式舍入）。
    // 调用方必须按 PTS 非递减顺序喂帧（封装器要求样本按展示序）。
    // 长任务，接受 CancelToken；背压等待期间若被取消返回 kCancelled（非错误）。
    virtual Status WriteVideoFrame(NativeImageHandle image, const RationalTime& pts,
                                  const CancelToken& token) = 0;

    // 写入一块音频（线性 PCM）。pcm 携带样本（SampleFormat / channels / sample_rate /
    // frame_count / data / data_bytes），pts 为该块首样本展示时间戳（timescale 须等于
    // 轨约定网格 120000；非整除须显式舍入）。封装器按 pcm 实际格式生成线性 PCM 样本缓冲，
    // 内部编码为 `AddAudioTrack` 指定的 AAC。当前支持 kFloat32 / kInt16；
    // 调用方须按 PTS 非递减顺序喂块；长任务接受 CancelToken，背压等待期间若被取消
    // 返回 kCancelled（非错误）。
    virtual Status WriteAudioFrame(const PcmBuffer& pcm, const RationalTime& pts,
                                  const CancelToken& token) = 0;

    // 正常收尾：标记输入完成并阻塞等待封装完成。返回错误若写入失败。
    virtual Status Finish(const CancelToken& token) = 0;

    // 取消：中止写入并删除半成品输出文件（不 Finish）。取消是独立停止信号（非错误）。
    // 已实现幂等：未 Open / 已收尾时调用安全返回 Ok。
    virtual Status Cancel() = 0;

    // 已成功写入的帧数（供诊断/测试）。
    virtual int64_t FrameCount() const = 0;

    // 本机是否支持硬件编码（运行时查询，诚实上报；不伪造）。
    virtual bool IsHardwareAccelerated() const = 0;
};

// 工厂（由 PAL 平台实现）。返回 PalPtr。
Status CreateMediaDemuxer(const MediaSource& src, PalPtr<IMediaDemuxer>& out_demuxer);
Status CreateFrameProvider(const MediaSource& src, PalPtr<IFrameProvider>& out_provider);
Status CreateMediaMuxer(PalPtr<IMediaMuxer>& out_muxer);

}  // namespace cq

#endif  // CQ_PAL_MEDIA_H_
