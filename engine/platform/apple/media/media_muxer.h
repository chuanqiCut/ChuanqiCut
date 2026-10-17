// ChuanqiCut — PALA-012 Apple 编码与封装的 Platform 接缝（ChqIMediaMuxer 的 Apple 实现）
//
// 本头是平台内部头，仅被 Apple 平台 TU 包含（tests/ 与未来 Platform 装配代码），
// 绝不进入 core 冻结头。门禁 check_platform_headers.py 只扫 engine/core/cq/{platform,gfx,media}，
// 故此处出现平台类型（CVPixelBufferRef 经 GetCvPixelBuffer 引入）安全。
//
// 为什么需要这一层：
//   * engine/core/cq/platform/chq_media.h 的 `ChqIMediaMuxer` 是平台无关接缝，但 AppleVideoEncoder
//     （media_encode.h）只接受 `CVPixelBufferRef`——这是 Apple 内部类型，不能进 core 头。
//   * 本类 `AppleMediaMuxer` 实现 `ChqIMediaMuxer`：把接口层的 `NativeImageHandle` 经
//     `GetCvPixelBuffer` 转回 CVPixelBufferRef，再委托给内部 `AppleVideoEncoder`。
//     上层（导出控制器）只持有 `ChqIMediaMuxer`，完全不碰 AppleVideoEncoder / CVPixelBufferRef。
//
// 红线（与 core 一致）：内核禁用异常（错误一律 ChqStatus）；长任务接受 ChqCancelToken；
// 时间用 ChqRationalTime；零 FFmpeg 类型。

#ifndef CQ_PLATFORM_APPLE_MEDIA_MUXER_H_
#define CQ_PLATFORM_APPLE_MEDIA_MUXER_H_

#include <cstdint>
#include <string>

#include "cq/base/chq_concurrency.h"    // ChqCancelToken
#include "cq/base/chq_status.h"         // ChqStatus / ChqStatusCode
#include "cq/base/chq_rational_time.h"  // ChqRationalTime
#include "cq/platform/chq_media.h"      // ChqIMediaMuxer / ChqVideoTrackConfig / ChqAudioTrackConfig
#include "media_encode.h"               // AppleVideoEncoder（内部引擎）

namespace cq {

// ChqIMediaMuxer 的 Apple 实现：组合 AppleVideoEncoder，把平台无关的 NativeImageHandle
// 转接为 CVPixelBufferRef 喂给编码器/封装器。
//
// 行为完全继承 AppleVideoEncoder 已验证的 60 帧导出能力（AVAssetWriter +
// PixelBufferAdaptor，每帧 PTS 用 ChqRationalTime 同构 CMTime，movieTimeScale=120000）。
// 仅新增了「经 opaque 句柄的跨层转接」，不改变编码/封装语义。
class AppleMediaMuxer : public ChqIMediaMuxer {
public:
    AppleMediaMuxer();
    ~AppleMediaMuxer() override;

    AppleMediaMuxer(const AppleMediaMuxer&) = delete;
    AppleMediaMuxer& operator=(const AppleMediaMuxer&) = delete;

    // ChqIMediaMuxer 接缝。
    ChqStatus Open(const char* output_path, ChqContainerFormat container) override;
    ChqStatus AddVideoTrack(const ChqVideoTrackConfig& cfg) override;
    ChqStatus AddAudioTrack(const ChqAudioTrackConfig& cfg) override;
    ChqStatus WriteVideoFrame(NativeImageHandle image, const ChqRationalTime& pts,
                              const ChqCancelToken& token) override;
    ChqStatus WriteAudioFrame(const ChqPcmBuffer& pcm, const ChqRationalTime& pts,
                              const ChqCancelToken& token) override;
    ChqStatus Finish(const ChqCancelToken& token) override;
    ChqStatus Cancel() override;
    int64_t FrameCount() const override;
    bool IsHardwareAccelerated() const override;

    // ChqIPlatformResource 生命周期。
    void Destroy() override;

private:
    AppleVideoEncoder encoder_;
    std::string output_path_;
    ChqContainerFormat container_ = ChqContainerFormat::kMp4;
    bool opened_ = false;       // Open 已成功
    bool video_added_ = false;  // AddVideoTrack 已成功（writer 已建立）
    bool audio_added_ = false;  // AddAudioTrack 已成功（AAC 音频轨已建立）
};

// 工厂：返回平台无关 ChqIMediaMuxer（Apple 后端）。由 PALA 平台实现提供。
ChqStatus CreateMediaMuxer(ChqPlatformPtr<ChqIMediaMuxer>& out_muxer);

}  // namespace cq

#endif  // CQ_PLATFORM_APPLE_MEDIA_MUXER_H_
