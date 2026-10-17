// ChuanqiCut — ChqFrameProvider 装配接缝（BIND-003 子步骤 4 引入）
//
// 为什么需要这层接缝（而不是让预览渲染器直接 new 一个 ChqSystemFrameProvider）：
//   ChqSystemFrameProvider 的构造签名是 (ChqPlatformPtr<ChqIMediaDemuxer>, ChqIFrameDecoder*)——
//   demuxer 来自 Platform 工厂，decoder 的真实实现是 PALA-011 的 VideoToolboxDecoder，
//   它定义在 platform/apple/media_decode.h，**只有 Apple TU 可见**。
//   core 若直接装配就必须 include 平台头，直接违反「Platform 头文件零平台类型」红线。
//
// 故：装配动作下沉到 platform/<platform>/，core 只定义这个抽象并持有其指针。
// 这与既有的 ChqIFrameCache / ChqIDecoderPool 注入式接缝是同一套路。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常（错误一律 ChqStatus）。

#ifndef CQ_CORE_MEDIA_CHQ_FRAME_PROVIDER_FACTORY_H_
#define CQ_CORE_MEDIA_CHQ_FRAME_PROVIDER_FACTORY_H_

#include <memory>

#include "cq/base/chq_status.h"
#include "cq/media/chq_frame_provider.h"  // ChqFrameProvider（MEDIA-010 抽象）
#include "cq/platform/chq_media.h"        // ChqMediaSource

namespace cq {

class ChqIFrameProviderFactory {
public:
    virtual ~ChqIFrameProviderFactory() = default;

    // 打开媒体源并产出一个可用的 ChqFrameProvider。
    // 返回的 provider **已 Open 完成**（调用方不必再调 Open）。
    // 生命周期：调用方持有 unique_ptr；本工厂不保留引用。
    virtual ChqStatus Create(const ChqMediaSource& src, std::unique_ptr<ChqFrameProvider>& out) = 0;
};

}  // namespace cq

#endif  // CQ_CORE_MEDIA_CHQ_FRAME_PROVIDER_FACTORY_H_
