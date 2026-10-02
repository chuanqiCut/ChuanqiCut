// ChuanqiCut — Apple 侧 FrameProvider 装配实现
//
// 见 frame_provider_apple.h 的分层说明。

#include "frame_provider_apple.h"

#include <string>
#include <utility>  // std::move

#include "cq/media/frame_provider.h"
#include "cq/media/system_frame_provider.h"  // CreateSystemFrameProvider（所有权重载）
#include "cq/pal/media.h"                    // MediaSource / CreateMediaDemuxer
#include "media_decode.h"                    // VideoToolboxDecoder（PALA-011，仅 Apple TU 可见）

namespace cq {
namespace apple {
namespace {

class AppleFrameProviderFactory final : public IFrameProviderFactory {
public:
    Status Create(const MediaSource& src, std::unique_ptr<FrameProvider>& out) override {
        out.reset();
        if (src.path == nullptr || src.path_len == 0) {
            return Status(StatusCode::kInvalidArgument);
        }

        // PALA-010：解封装
        PalPtr<IMediaDemuxer> demuxer;
        Status s = CreateMediaDemuxer(src, demuxer);
        if (!s.IsOk()) return s;
        if (!demuxer) return Status(StatusCode::kInternal);

        // PALA-011：硬解。解码器是堆对象，交给 provider 接管所有权（AdoptDecoder），
        // 避免「provider 活着但 decoder 已析构」的悬垂。
        // path 单独拷一份：MediaSource 只有「指针 + 长度」，不保证以 NUL 结尾。
        const std::string path(src.path, src.path_len);
        auto decoder = std::unique_ptr<IFrameDecoder>(new VideoToolboxDecoder(path.c_str()));

        auto provider = CreateSystemFrameProvider(std::move(demuxer), std::move(decoder));

        // Open 会读流信息并建立 VideoToolbox 会话；失败时如实透传，不降级为「半可用」。
        s = provider->Open(src);
        if (!s.IsOk()) return s;

        out = std::move(provider);
        return Status::Ok();
    }
};

}  // namespace

std::unique_ptr<IFrameProviderFactory> CreateAppleFrameProviderFactory() {
    return std::unique_ptr<IFrameProviderFactory>(new AppleFrameProviderFactory());
}

}  // namespace apple
}  // namespace cq
