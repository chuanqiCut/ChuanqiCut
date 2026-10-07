// ChuanqiCut — MEDIA-011 LruFrameCache 实现（跨平台层）
//
// 头文件零平台类型 / 零 FFmpeg 类型 / 无异常。细节见 cache.h 注释（所有权与 lease 模型）。

#include "cq/media/media_cache.h"

namespace cq {

LruFrameCache::LruFrameCache(int64_t max_bytes) : max_bytes_(max_bytes) {}

bool LruFrameCache::Find(const RationalTime& at, MediaFrame& out) {
    auto it = map_.find(at);
    if (it == map_.end()) return false;
    // 命中：move-out lease —— 移出缓存，调用方独占该帧（淘汰循环碰不到）。
    out = std::move(it->second.frame);
    used_bytes_ -= it->second.bytes;
    lru_.erase(it->second.lru_it);
    map_.erase(it);
    return true;
}

Status LruFrameCache::Insert(const RationalTime& at, const MediaFrame& frame) {
    const int64_t b = ApproxFrameBytes(frame);
    // 同 key 已存在（理论不会发生，因 Find 会移出），先移除旧条目避免重复。
    auto ex = map_.find(at);
    if (ex != map_.end()) {
        used_bytes_ -= ex->second.bytes;
        lru_.erase(ex->second.lru_it);
        map_.erase(ex);
    }
    EvictToFit(b);
    Entry e;
    e.frame = frame;  // 浅拷贝句柄（底层像素内存归 provider 池所有）
    e.bytes = b;
    e.lru_it = lru_.insert(lru_.begin(), at);  // 置为 MRU
    map_[at] = std::move(e);
    used_bytes_ += b;
    return Status::Ok();
}

int64_t LruFrameCache::UsedBytes() const { return used_bytes_; }

int64_t LruFrameCache::MaxBytes() const { return max_bytes_; }

void LruFrameCache::SetMaxBytes(int64_t bytes) {
    max_bytes_ = bytes;
    EvictToFit(0);  // 缩小时立即淘汰到 <= 上界
}

int64_t LruFrameCache::Size() const {
    return static_cast<int64_t>(map_.size());
}

bool LruFrameCache::Contains(const RationalTime& at) const {
    return map_.find(at) != map_.end();
}

int64_t LruFrameCache::ApproxFrameBytes(const MediaFrame& f) {
    if (f.type == MediaType::kVideo) {
        const int64_t w = static_cast<int64_t>(f.video.width);
        const int64_t h = static_cast<int64_t>(f.video.height);
        int64_t bytes = 0;
        switch (f.video.pixel_format) {
            case PixelFormat::kRGBA8:
            case PixelFormat::kBGRA8:            bytes = w * h * 4; break;
            case PixelFormat::kRGBA16F:          bytes = w * h * 8; break;
            case PixelFormat::kYUV420Planar:
            case PixelFormat::kYUV420SemiPlanar:  bytes = w * h + (w * h) / 2; break;  // 1.5 bpp
            case PixelFormat::kYUV422Planar:
            case PixelFormat::kYUV422SemiPlanar:  bytes = w * h * 2; break;
            case PixelFormat::kGray8:            bytes = w * h; break;
            default:                             bytes = w * h * 4; break;
        }
        return bytes;
    }
    if (f.type == MediaType::kAudio) {
        return static_cast<int64_t>(f.audio.pcm.data_bytes);
    }
    return 0;
}

void LruFrameCache::EvictToFit(int64_t incoming_bytes) {
    // 单帧尺寸 > 上界时无法靠淘汰腾出空间，循环自然退出（该帧仍会被插入，上界被击穿——
    // 属配置错误，已在头文件注释固定；单测用「每帧 ≤ 上界」的帧避免此情形）。
    while (!map_.empty() && used_bytes_ + incoming_bytes > max_bytes_) {
        const RationalTime key = lru_.back();  // LRU 尾部
        auto it = map_.find(key);
        if (it == map_.end()) {  // 防御：lru_ 与 map_ 必须一致
            lru_.pop_back();
            continue;
        }
        used_bytes_ -= it->second.bytes;
        map_.erase(it);
        lru_.pop_back();
    }
}

}  // namespace cq
