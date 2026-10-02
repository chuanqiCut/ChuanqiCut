// ChuanqiCut — Apple 侧 FrameProvider 装配（BIND-003 子步骤 4）
//
// 为什么单独一个文件（而不是让 core 直接装配）：
//   SystemFrameProvider 需要 (PAL demuxer, IFrameDecoder*)，后者的真实实现是
//   PALA-011 的 VideoToolboxDecoder，定义在 pal/apple/media_decode.h —— 该文件
//   **只有 Apple TU 可见**。core 若直接装配就必须 include 平台头，违反
//   「PAL 头文件零平台类型」红线。故装配下沉到本文件。
//
// 装配公式：
//   CreateMediaDemuxer（PALA-010）+ VideoToolboxDecoder（PALA-011）
//   → CreateSystemFrameProvider（MEDIA-020 编排，并接管解码器所有权）

#ifndef CQ_PAL_APPLE_FRAME_PROVIDER_APPLE_H_
#define CQ_PAL_APPLE_FRAME_PROVIDER_APPLE_H_

#include <memory>

#include "cq/media/frame_provider_factory.h"  // cq::IFrameProviderFactory

namespace cq {
namespace apple {

std::unique_ptr<IFrameProviderFactory> CreateAppleFrameProviderFactory();

}  // namespace apple
}  // namespace cq

#endif  // CQ_PAL_APPLE_FRAME_PROVIDER_APPLE_H_
