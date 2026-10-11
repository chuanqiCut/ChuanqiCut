// ChuanqiCut — MEDIA-020 ChqSystemFrameProvider 翻译单元
//
// 实现在头文件 system_frame_provider.h（内联类方法），本 TU 落地工厂函数并作为
// cq_core 的编译锚点，确保 MEDIA-020 编排逻辑在 -Werror（含 -Wconversion /
// -Wshadow / -Wold-style-cast）下随库一起干净编译。真实解码后端（PALA-011）接入后，
// 可在本 TU 落地平台解码适配器，无需改动接口。

#include "cq/media/chq_system_frame_provider.h"

namespace cq {

std::unique_ptr<ChqFrameProvider> CreateSystemFrameProvider(
    ChqPlatformPtr<ChqIMediaDemuxer> demuxer, ChqIFrameDecoder* decoder) {
    return std::unique_ptr<ChqFrameProvider>(
        new ChqSystemFrameProvider(std::move(demuxer), decoder));
}

std::unique_ptr<ChqFrameProvider> CreateSystemFrameProvider(
    ChqPlatformPtr<ChqIMediaDemuxer> demuxer, std::unique_ptr<ChqIFrameDecoder> owned_decoder) {
    ChqIFrameDecoder* raw = owned_decoder.get();
    auto provider = std::unique_ptr<ChqFrameProvider>(
        new ChqSystemFrameProvider(std::move(demuxer), raw));
    static_cast<ChqSystemFrameProvider*>(provider.get())->AdoptDecoder(std::move(owned_decoder));
    return provider;
}

}  // namespace cq
