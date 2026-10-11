// ChuanqiCut — 音频轨读取器：core 侧默认装配工厂（AUDIO-002）
//
// 为什么单独一个 TU（与 cq/preview/cq_sdk_preview.cpp 同一论证）：
//   本文件引用 Platform 工厂符号（CreateAudioTrackReader）。静态库按 archive
//   member 粒度拉符号，只有真正使用音频读取能力的目标才会把它链进来 ——
//   不用音频预览的目标（如无 Platform 后端的 Android 构建）不产生链接依赖。

#include "cq/audio/track_reader.h"

namespace cq {

Status PlatformAudioReaderFactory::Create(const MediaSource& src,
                                          const AudioGraphSpec& spec,
                                          AudioReaderPtr& out) {
    if (src.path == nullptr || src.path_len == 0) {
        return Status(StatusCode::kInvalidArgument);
    }
    PlatformPtr<IAudioTrackReader> platform;
    Status s = CreateAudioTrackReader(platform, spec);
    if (!s.IsOk() || !platform) {
        return s;  // 平台后端缺失/创建失败：原样透传（诚实，不伪造空读取器）
    }
    // Open 由这里统一完成（契约：工厂产出的读取器已 Open）。
    s = platform->Open(src);
    if (!s.IsOk()) {
        return s;
    }
    // release 后所有权移交 AudioReaderPtr（析构走 Destroy()，符合
    // IPlatformResource「不可跨模块 delete」契约）。
    out = AudioReaderPtr(static_cast<IAudioTrackReader*>(platform.release()));
    return Status::Ok();
}

}  // namespace cq
