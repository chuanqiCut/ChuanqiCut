// ChuanqiCut — PALA-012 Apple 编码与封装的 PAL 接缝（IMediaMuxer 的 Apple 实现）
//
// 本头是平台内部头，仅被 Apple 平台 TU 包含（tests/ 与未来 PAL 装配代码），
// 绝不进入 core 冻结头。门禁 check_pal_headers.py 只扫 core/include/cq/{pal,gfx,media}，
// 故此处出现平台类型（CVPixelBufferRef 经 GetCvPixelBuffer 引入）安全。
//
// 为什么需要这一层：
//   * core/include/cq/pal/media.h 的 `IMediaMuxer` 是平台无关接缝，但 AppleVideoEncoder
//     （media_encode.h）只接受 `CVPixelBufferRef`——这是 Apple 内部类型，不能进 core 头。
//   * 本类 `AppleMediaMuxer` 实现 `IMediaMuxer`：把接口层的 `NativeImageHandle` 经
//     `GetCvPixelBuffer` 转回 CVPixelBufferRef，再委托给内部 `AppleVideoEncoder`。
//     上层（导出控制器）只持有 `IMediaMuxer`，完全不碰 AppleVideoEncoder / CVPixelBufferRef。
//
// 红线（与 core 一致）：内核禁用异常（错误一律 Status）；长任务接受 CancelToken；
// 时间用 RationalTime；零 FFmpeg 类型。

#ifndef CQ_PAL_APPLE_MEDIA_MUXER_H_
#define CQ_PAL_APPLE_MEDIA_MUXER_H_

#include <cstdint>
#include <string>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/status.h"        // Status / StatusCode
#include "cq/base/time.h"          // RationalTime
#include "cq/pal/media.h"          // IMediaMuxer / VideoTrackConfig / AudioTrackConfig
#include "media_encode.h"          // AppleVideoEncoder（内部引擎）

namespace cq {

// IMediaMuxer 的 Apple 实现：组合 AppleVideoEncoder，把平台无关的 NativeImageHandle
// 转接为 CVPixelBufferRef 喂给编码器/封装器。
//
// 行为完全继承 AppleVideoEncoder 已验证的 60 帧导出能力（AVAssetWriter +
// PixelBufferAdaptor，每帧 PTS 用 RationalTime 同构 CMTime，movieTimeScale=120000）。
// 仅新增了「经 opaque 句柄的跨层转接」，不改变编码/封装语义。
class AppleMediaMuxer : public IMediaMuxer {
public:
    AppleMediaMuxer();
    ~AppleMediaMuxer() override;

    AppleMediaMuxer(const AppleMediaMuxer&) = delete;
    AppleMediaMuxer& operator=(const AppleMediaMuxer&) = delete;

    // IMediaMuxer 接缝。
    Status Open(const char* output_path, ContainerFormat container) override;
    Status AddVideoTrack(const VideoTrackConfig& cfg) override;
    Status AddAudioTrack(const AudioTrackConfig& cfg) override;
    Status WriteVideoFrame(NativeImageHandle image, const RationalTime& pts,
                         const CancelToken& token) override;
    Status Finish(const CancelToken& token) override;
    Status Cancel() override;
    int64_t FrameCount() const override;
    bool IsHardwareAccelerated() const override;

    // IPalResource 生命周期。
    void Destroy() override;

private:
    AppleVideoEncoder encoder_;
    std::string output_path_;
    ContainerFormat container_ = ContainerFormat::kMp4;
    bool opened_ = false;       // Open 已成功
    bool video_added_ = false;  // AddVideoTrack 已成功（writer 已建立）
};

// 工厂：返回平台无关 IMediaMuxer（Apple 后端）。由 PALA 平台实现提供。
Status CreateMediaMuxer(PalPtr<IMediaMuxer>& out_muxer);

}  // namespace cq

#endif  // CQ_PAL_APPLE_MEDIA_MUXER_H_
