// ChuanqiCut — MEDIA-020 SystemFrameProvider 翻译单元
//
// 实现在头文件 system_frame_provider.h（内联类方法），本 TU 落地工厂函数并作为
// cq_core 的编译锚点，确保 MEDIA-020 编排逻辑在 -Werror（含 -Wconversion /
// -Wshadow / -Wold-style-cast）下随库一起干净编译。真实解码后端（PALA-011）接入后，
// 可在本 TU 落地平台解码适配器，无需改动接口。

#include "cq/media/system_frame_provider.h"

namespace cq {

std::unique_ptr<FrameProvider> CreateSystemFrameProvider(
    PalPtr<IMediaDemuxer> demuxer, IFrameDecoder* decoder) {
    return std::unique_ptr<FrameProvider>(
        new SystemFrameProvider(std::move(demuxer), decoder));
}

std::unique_ptr<FrameProvider> CreateSystemFrameProvider(
    PalPtr<IMediaDemuxer> demuxer, std::unique_ptr<IFrameDecoder> owned_decoder) {
    IFrameDecoder* raw = owned_decoder.get();
    auto provider = std::unique_ptr<FrameProvider>(
        new SystemFrameProvider(std::move(demuxer), raw));
    static_cast<SystemFrameProvider*>(provider.get())->AdoptDecoder(std::move(owned_decoder));
    return provider;
}

}  // namespace cq
