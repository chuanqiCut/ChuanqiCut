// ChuanqiCut — PALA-012 Apple 封装接缝实现（IMediaMuxer 的 Apple 实现）
//
// 见 media_muxer.h 的设计说明。要点：
//   * 组合 AppleVideoEncoder（AVAssetWriter + PixelBufferAdaptor，已验证的 60 帧导出）。
//   * WriteVideoFrame 把平台无关 NativeImageHandle 经 GetCvPixelBuffer 转回 CVPixelBufferRef，
//     委托给 encoder；全程不把 CVPixelBufferRef 泄漏到 core 接口。
//   * 时间一律 RationalTime（timescale = kProjectTimeScale = 120000），与 AppleVideoEncoder 同构。
//   * 取消语义：WriteVideoFrame / Finish 检测 CancelToken，返回 kCancelled（非错误）。
//
// 红线：零 FFmpeg 类型；平台类型只在本 .mm（经 pImpl / GetCvPixelBuffer）；错误一律 Status；
// 内核禁用异常；-Werror 零警告。

#include <cstdint>
#include <string>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "media_decode.h"  // GetCvPixelBuffer（仅 Apple TU）
#include "media_muxer.h"

namespace cq {

// 把码率档位映射到本机默认码率（bps）。0 = 交给 AVAssetWriter 默认值（最高可达质量）。
static int64_t BitrateForTier(BitrateTier tier) {
    switch (tier) {
        case BitrateTier::kLow:      return 5'000'000;
        case BitrateTier::kMedium:   return 10'000'000;
        case BitrateTier::kHigh:     return 20'000'000;
        case BitrateTier::kLossless:
        case BitrateTier::kUnknown:
        default:                     return 0;  // 交平台默认
    }
}

AppleMediaMuxer::AppleMediaMuxer() = default;

AppleMediaMuxer::~AppleMediaMuxer() = default;

Status AppleMediaMuxer::Open(const char* output_path, ContainerFormat container) {
    if (output_path == nullptr) return Status{StatusCode::kInvalidArgument};
    // 本期仅支持 MP4 封装（AVFileTypeMPEG4）。
    if (container != ContainerFormat::kMp4 && container != ContainerFormat::kMov) {
        return Status{StatusCode::kFormatUnsupported};
    }
    output_path_ = output_path;
    container_ = container;
    opened_ = true;
    video_added_ = false;
    audio_added_ = false;
    return Status::Ok();
}

Status AppleMediaMuxer::AddVideoTrack(const VideoTrackConfig& cfg) {
    if (!opened_) return Status{StatusCode::kInvalidArgument};
    if (cfg.width == 0 || cfg.height == 0) return Status{StatusCode::kInvalidArgument};

    EncodeConfig ecfg;
    ecfg.width = cfg.width;
    ecfg.height = cfg.height;
    ecfg.timescale = kProjectTimeScale;  // 120000，与源同构，杜绝累积漂移（ADR-0009）
    ecfg.fps_numerator = static_cast<uint32_t>(cfg.frame_rate.value);
    ecfg.fps_denominator = static_cast<uint32_t>(cfg.frame_rate.timescale);
    if (ecfg.fps_denominator == 0) ecfg.fps_denominator = 1;
    ecfg.average_bitrate = BitrateForTier(cfg.bitrate);
    ecfg.max_keyframe_interval = cfg.max_keyframe_interval;
    ecfg.allow_hardware = cfg.allow_hardware;

    Status s = encoder_.Open(output_path_.c_str(), ecfg);
    if (s.IsOk()) video_added_ = true;
    return s;
}

Status AppleMediaMuxer::AddAudioTrack(const AudioTrackConfig& cfg) {
    if (!opened_) return Status{StatusCode::kInvalidArgument};
    // 约束（见 media.h 注释）：音频轨必须在视频轨（建立 writer）之后添加。
    if (!video_added_) return Status{StatusCode::kInvalidArgument};
    if (cfg.codec != CodecId::kAac) {
        // 本期仅实现 AAC 封装；其它音频 codec 如实返回不支持，不伪造。
        return Status{StatusCode::kEncodeUnsupported};
    }
    Status s = encoder_.AddAudioTrack(cfg);
    if (s.IsOk()) audio_added_ = true;
    return s;
}

Status AppleMediaMuxer::WriteAudioFrame(const PcmBuffer& pcm, const RationalTime& pts,
                                     const CancelToken& token) {
    if (!audio_added_) return Status{StatusCode::kEncodeError};
    return encoder_.WriteAudioFrame(pcm, pts, token);
}

Status AppleMediaMuxer::WriteVideoFrame(NativeImageHandle image, const RationalTime& pts,
                                       const CancelToken& token) {
    if (!video_added_) return Status{StatusCode::kEncodeError};
    CVPixelBufferRef pb = GetCvPixelBuffer(image);
    if (pb == nullptr) return Status{StatusCode::kInvalidArgument};
    return encoder_.EncodeFrame(pb, pts, token);
}

Status AppleMediaMuxer::Finish(const CancelToken& token) {
    if (token.IsCancelled()) return token.Cancelled();
    return encoder_.Finish();
}

Status AppleMediaMuxer::Cancel() {
    return encoder_.Cancel();
}

int64_t AppleMediaMuxer::FrameCount() const {
    return encoder_.FrameCount();
}

bool AppleMediaMuxer::IsHardwareAccelerated() const {
    return encoder_.IsHardwareAccelerated();
}

void AppleMediaMuxer::Destroy() {
    delete this;
}

Status CreateMediaMuxer(PalPtr<IMediaMuxer>& out_muxer) {
    out_muxer = PalPtr<IMediaMuxer>(new AppleMediaMuxer());
    return Status::Ok();
}

}  // namespace cq
