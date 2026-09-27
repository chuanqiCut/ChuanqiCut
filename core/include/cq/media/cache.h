// ChuanqiCut — MEDIA-011 帧缓存池（LRU）+ 内存上界
//
// 实现 `IFrameCache`（`frame_provider.h` 冻结接口）。跨平台层：零平台类型 / 零 FFmpeg 类型 /
// 无异常 / 时间用 RationalTime。
//
// ─────────────────────────────────────────────────────────────────────────────
// 所有权与 lease 模型（防 use-after-free 的关键）
// ─────────────────────────────────────────────────────────────────────────────
// * 缓存持有的是解码后 `MediaFrame` 的**浅拷贝**：`video.image`（`NativeImageHandle`）/
//   `audio.pcm.data` 指向的内存归 provider 内部池所有，缓存**只持句柄**，绝不释放它。
//   故 `Insert` 接管的是「句柄副本」所有权；`evict` 时仅丢弃句柄副本，不释放底层像素缓冲
//   （底层由 provider 池管理，避免 double free）。
// * lease 语义：`Find` 命中时把帧**移出**缓存（move-out）交给调用方，缓存中不再保留该条目。
//   于是「被借出的帧」物理上不在 LRU 中，淘汰循环永远碰不到它——即使将来改为深拷贝模式，
//   调用方手中的帧也是独立的拷贝，淘汰不会破坏它。调用方用毕经
//   `FrameProvider::ReleaseFrame` 把帧交回（provider 调 `Insert` 重新入缓存，key = 帧 pts）。
// * 上界：`UsedBytes()` 统计「若把这些帧常驻需多少内存」= 按像素格式估算的解码尺寸
//   （video: w*h*bpp；audio: pcm.data_bytes）。上限由构造参数 / `SetMaxBytes` 给定；
//   插入导致超限时按 LRU 从尾部淘汰，保证 `UsedBytes() <= 上界`（单帧尺寸须 ≤ 上界，
//   否则该帧无法被淘汰、上界被单帧击穿——属配置错误，注释固定）。
//
// 线程模型：非内部同步（单 owner，provider 串行访问）；并发由调用方保证。

#ifndef CQ_MEDIA_CACHE_H_
#define CQ_MEDIA_CACHE_H_

#include <cstdint>
#include <list>
#include <map>

#include "cq/base/status.h"            // Status
#include "cq/base/time.h"              // RationalTime
#include "cq/media/frame_provider.h"   // IFrameCache

namespace cq {

// LRU 帧缓存（MEDIA-011）。
class LruFrameCache : public IFrameCache {
public:
    // max_bytes = 内存上界（解码尺寸估算字节）。<=0 视为无上界（仅测试/诊断用）。
    explicit LruFrameCache(int64_t max_bytes);

    // ---- IFrameCache ----
    // 命中：把帧**移出**缓存（move-out lease）写入 out，返回 true；未命中返回 false。
    bool Find(const RationalTime& at, MediaFrame& out) override;
    // 存入一帧（浅拷贝句柄）。若会超上界则按 LRU 淘汰最久未用，保证 UsedBytes() <= 上界。
    Status Insert(const RationalTime& at, const MediaFrame& frame) override;
    // 当前缓存占用字节（解码尺寸估算；不含已借出帧）。
    int64_t UsedBytes() const override;

    // ---- 配置 / 诊断（具体类扩展，不进冻结接口）----
    int64_t MaxBytes() const;
    void SetMaxBytes(int64_t bytes);     // 缩小时立即触发淘汰
    int64_t Size() const;               // 当前缓存条目数（不含已借出）
    bool Contains(const RationalTime& at) const;  // key 是否在缓存内（已借出不算）

private:
    struct Entry {
        MediaFrame frame;
        int64_t bytes = 0;
        std::list<RationalTime>::iterator lru_it;  // 指向 lru_ 中的本 key
    };

    // 估算单帧成本（解码尺寸）。video: w*h*bpp；audio: pcm.data_bytes。
    static int64_t ApproxFrameBytes(const MediaFrame& f);
    // 在插入 incoming_bytes 前，按 LRU 淘汰尾部直到 used + incoming <= max。
    void EvictToFit(int64_t incoming_bytes);

    int64_t max_bytes_;
    int64_t used_bytes_ = 0;
    std::map<RationalTime, Entry> map_;    // key -> 条目
    std::list<RationalTime> lru_;          // front = MRU，back = LRU
};

}  // namespace cq

#endif  // CQ_MEDIA_CACHE_H_
