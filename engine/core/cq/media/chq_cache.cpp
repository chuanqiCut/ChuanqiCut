// ChuanqiCut — MEDIA-011 ChqLruFrameCache 实现（跨平台层）
//
// 头文件零平台类型 / 零 FFmpeg 类型 / 无异常。细节见 cache.h 注释（所有权与 lease 模型）。

#include "cq/media/chq_media_cache.h"

namespace cq {

ChqLruFrameCache::ChqLruFrameCache(int64_t max_bytes) : max_bytes_(max_bytes) {}

bool ChqLruFrameCache::Find(const ChqRationalTime& at, ChqMediaFrame& out) {
    auto it = map_.find(at);
    if (it == map_.end()) return false;
    // 命中：move-out lease —— 移出缓存，调用方独占该帧（淘汰循环碰不到）。
    out = std::move(it->second.frame);
    used_bytes_ -= it->second.bytes;
    lru_.erase(it->second.lru_it);
    map_.erase(it);
    return true;
}

ChqStatus ChqLruFrameCache::Insert(const ChqRationalTime& at, const ChqMediaFrame& frame) {
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
    return ChqStatus::Ok();
}

int64_t ChqLruFrameCache::UsedBytes() const { return used_bytes_; }

int64_t ChqLruFrameCache::MaxBytes() const { return max_bytes_; }

void ChqLruFrameCache::SetMaxBytes(int64_t bytes) {
    max_bytes_ = bytes;
    EvictToFit(0);  // 缩小时立即淘汰到 <= 上界
}

int64_t ChqLruFrameCache::Size() const {
    return static_cast<int64_t>(map_.size());
}

bool ChqLruFrameCache::Contains(const ChqRationalTime& at) const {
    return map_.find(at) != map_.end();
}

int64_t ChqLruFrameCache::ApproxFrameBytes(const ChqMediaFrame& f) {
    if (f.type == ChqMediaType::kVideo) {
        const int64_t w = static_cast<int64_t>(f.video.width);
        const int64_t h = static_cast<int64_t>(f.video.height);
        int64_t bytes = 0;
        switch (f.video.pixel_format) {
            case ChqPixelFormat::kRGBA8:
            case ChqPixelFormat::kBGRA8:            bytes = w * h * 4; break;
            case ChqPixelFormat::kRGBA16F:          bytes = w * h * 8; break;
            case ChqPixelFormat::kYUV420Planar:
            case ChqPixelFormat::kYUV420SemiPlanar:  bytes = w * h + (w * h) / 2; break;  // 1.5 bpp
            case ChqPixelFormat::kYUV422Planar:
            case ChqPixelFormat::kYUV422SemiPlanar:  bytes = w * h * 2; break;
            case ChqPixelFormat::kGray8:            bytes = w * h; break;
            default:                             bytes = w * h * 4; break;
        }
        return bytes;
    }
    if (f.type == ChqMediaType::kAudio) {
        return static_cast<int64_t>(f.audio.pcm.data_bytes);
    }
    return 0;
}

void ChqLruFrameCache::EvictToFit(int64_t incoming_bytes) {
    // 单帧尺寸 > 上界时无法靠淘汰腾出空间，循环自然退出（该帧仍会被插入，上界被击穿——
    // 属配置错误，已在头文件注释固定；单测用「每帧 ≤ 上界」的帧避免此情形）。
    while (!map_.empty() && used_bytes_ + incoming_bytes > max_bytes_) {
        const ChqRationalTime key = lru_.back();  // LRU 尾部
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
