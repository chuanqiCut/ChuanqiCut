// ChuanqiCut — PALA-012 Apple 封装接缝实现（ChqIMediaMuxer 的 Apple 实现）
//
// 见 media_muxer.h 的设计说明。要点：
//   * 组合 AppleVideoEncoder（AVAssetWriter + PixelBufferAdaptor，已验证的 60 帧导出）。
//   * WriteVideoFrame 把平台无关 NativeImageHandle 经 GetCvPixelBuffer 转回 CVPixelBufferRef，
//     委托给 encoder；全程不把 CVPixelBufferRef 泄漏到 core 接口。
//   * 时间一律 ChqRationalTime（timescale = kProjectTimeScale = 120000），与 AppleVideoEncoder 同构。
//   * 取消语义：WriteVideoFrame / Finish 检测 ChqCancelToken，返回 kCancelled（非错误）。
//
// 红线：零 FFmpeg 类型；平台类型只在本 .mm（经 pImpl / GetCvPixelBuffer）；错误一律 ChqStatus；
// 内核禁用异常；-Werror 零警告。

#include <cstdint>
#include <string>

#include "cq/base/chq_status.h"
#include "cq/base/chq_rational_time.h"
#include "media_decode.h"  // GetCvPixelBuffer（仅 Apple TU）
#include "media_muxer.h"

namespace cq {

// 把码率档位映射到本机默认码率（bps）。0 = 交给 AVAssetWriter 默认值（最高可达质量）。
static int64_t BitrateForTier(ChqBitrateTier tier) {
    switch (tier) {
        case ChqBitrateTier::kLow:      return 5'000'000;
        case ChqBitrateTier::kMedium:   return 10'000'000;
        case ChqBitrateTier::kHigh:     return 20'000'000;
        case ChqBitrateTier::kLossless:
        case ChqBitrateTier::kUnknown:
        default:                     return 0;  // 交平台默认
    }
}

AppleMediaMuxer::AppleMediaMuxer() = default;

AppleMediaMuxer::~AppleMediaMuxer() = default;

ChqStatus AppleMediaMuxer::Open(const char* output_path, ChqContainerFormat container) {
    if (output_path == nullptr) return ChqStatus{ChqStatusCode::kInvalidArgument};
    // 本期仅支持 MP4 封装（AVFileTypeMPEG4）。
    if (container != ChqContainerFormat::kMp4 && container != ChqContainerFormat::kMov) {
        return ChqStatus{ChqStatusCode::kFormatUnsupported};
    }
    output_path_ = output_path;
    container_ = container;
    opened_ = true;
    video_added_ = false;
    audio_added_ = false;
    return ChqStatus::Ok();
}

ChqStatus AppleMediaMuxer::AddVideoTrack(const ChqVideoTrackConfig& cfg) {
    if (!opened_) return ChqStatus{ChqStatusCode::kInvalidArgument};
    if (cfg.width == 0 || cfg.height == 0) return ChqStatus{ChqStatusCode::kInvalidArgument};

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

    ChqStatus s = encoder_.Open(output_path_.c_str(), ecfg);
    if (s.IsOk()) video_added_ = true;
    return s;
}

ChqStatus AppleMediaMuxer::AddAudioTrack(const ChqAudioTrackConfig& cfg) {
    if (!opened_) return ChqStatus{ChqStatusCode::kInvalidArgument};
    // 约束（见 media.h 注释）：音频轨必须在视频轨（建立 writer）之后添加。
    if (!video_added_) return ChqStatus{ChqStatusCode::kInvalidArgument};
    if (cfg.codec != ChqCodecId::kAac) {
        // 本期仅实现 AAC 封装；其它音频 codec 如实返回不支持，不伪造。
        return ChqStatus{ChqStatusCode::kEncodeUnsupported};
    }
    ChqStatus s = encoder_.AddAudioTrack(cfg);
    if (s.IsOk()) audio_added_ = true;
    return s;
}

ChqStatus AppleMediaMuxer::WriteAudioFrame(const ChqPcmBuffer& pcm, const ChqRationalTime& pts,
                                     const ChqCancelToken& token) {
    if (!audio_added_) return ChqStatus{ChqStatusCode::kEncodeError};
    return encoder_.WriteAudioFrame(pcm, pts, token);
}

ChqStatus AppleMediaMuxer::WriteVideoFrame(NativeImageHandle image, const ChqRationalTime& pts,
                                       const ChqCancelToken& token) {
    if (!video_added_) return ChqStatus{ChqStatusCode::kEncodeError};
    CVPixelBufferRef pb = GetCvPixelBuffer(image);
    if (pb == nullptr) return ChqStatus{ChqStatusCode::kInvalidArgument};
    return encoder_.EncodeFrame(pb, pts, token);
}

ChqStatus AppleMediaMuxer::Finish(const ChqCancelToken& token) {
    if (token.IsCancelled()) return token.Cancelled();
    return encoder_.Finish();
}

ChqStatus AppleMediaMuxer::Cancel() {
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

ChqStatus CreateMediaMuxer(ChqPlatformPtr<ChqIMediaMuxer>& out_muxer) {
    out_muxer = ChqPlatformPtr<ChqIMediaMuxer>(new AppleMediaMuxer());
    return ChqStatus::Ok();
}

}  // namespace cq
