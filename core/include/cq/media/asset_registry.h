// ChuanqiCut — 素材表（BIND-003 子步骤 1）
//
// 作用：补上 MODEL-001 留下的那一环 —— `MediaRef` 只有 `asset_id`，
// 预览拿到 pts 后需要「asset_id → 媒体源」才能去解码。
//
// ⚠️ 为什么必须自己持有路径字符串：
//    PAL 的 `MediaSource` 只存 `const char* path` **裸指针**，不拥有内存。
//    若本表直接存 MediaSource 而路径由调用方持有，调用方那边一释放就是悬垂指针。
//    故这里用堆上的 shared_ptr<string> 保管 —— 且**必须放堆上**：
//    若放栈/对象内，unordered_map 重哈希移动 Entry 时，短字符串 SSO 缓冲区
//    会随对象搬家而换地址，MediaSource.path 同样失效。
//    （2026-10-03 由 unique_ptr 改 shared_ptr：快照发布需要**拷贝整表**，
//    拷贝共享同一份堆字符串，地址稳定语义不变。）
//
// 职责边界：只做 id → MediaSource 映射。**不负责打开、不持有解码器、不做缓存** ——
//   生命周期与解码器归属交给预览渲染器（BIND-003 子步骤 2+）。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常（错误一律 Status）。
// 可拷贝（快照发布需要）；拷贝共享路径字符串，无深拷贝成本。

#ifndef CQ_MEDIA_ASSET_REGISTRY_H_
#define CQ_MEDIA_ASSET_REGISTRY_H_

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>

#include "cq/base/status.h"
#include "cq/pal/media.h"

namespace cq {

class AssetRegistry {
public:
    // 注册素材。path 会被**拷贝**进表内（调用方可立即释放自己的那份）。
    // 重复注册同一 id：整个替换（先清后写），不留半截状态。
    Status Register(uint64_t asset_id, const std::string& path);

    Status Unregister(uint64_t asset_id);

    // 取媒体源；未注册返回 nullptr（**不**返回 Status —— 查不到是正常查询路径，
    // 不是错误，避免调用方被迫处理一个必然要忽略的错误码）。
    const MediaSource* Find(uint64_t asset_id) const;

    std::size_t Count() const;
    void Clear();

private:
    struct Entry {
        std::shared_ptr<std::string> path;  // 堆持有，地址稳定；拷贝共享
        MediaSource source;                 // source.path 指向上面的字符串
    };

    std::unordered_map<uint64_t, Entry> assets_;
};

}  // namespace cq

#endif  // CQ_MEDIA_ASSET_REGISTRY_H_
