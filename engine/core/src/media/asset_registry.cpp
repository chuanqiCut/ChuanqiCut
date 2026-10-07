// ChuanqiCut — 素材表实现（BIND-003 子步骤 1）

#include "cq/media/asset_registry.h"

#include <utility>  // std::move

namespace cq {

Status AssetRegistry::Register(uint64_t asset_id, const std::string& path) {
    if (path.empty()) return Status(StatusCode::kInvalidArgument);

    Entry entry;
    entry.path = std::make_shared<std::string>(path);
    // source.path 指向堆上的字符串：Entry 搬家时该地址不变（见头文件注释）。
    entry.source.path = entry.path->c_str();
    entry.source.path_len = entry.path->size();

    assets_[asset_id] = std::move(entry);
    return Status::Ok();
}

Status AssetRegistry::Unregister(uint64_t asset_id) {
    return assets_.erase(asset_id) > 0 ? Status::Ok()
                                       : Status(StatusCode::kInvalidArgument);
}

const MediaSource* AssetRegistry::Find(uint64_t asset_id) const {
    auto it = assets_.find(asset_id);
    if (it == assets_.end()) return nullptr;
    return &it->second.source;
}

std::vector<std::pair<uint64_t, MediaSource>> AssetRegistry::ListAssets() const {
    std::vector<std::pair<uint64_t, MediaSource>> out;
    out.reserve(assets_.size());
    for (const auto& [id, entry] : assets_) {
        out.emplace_back(id, entry.source);
    }
    return out;
}

std::size_t AssetRegistry::Count() const { return assets_.size(); }

void AssetRegistry::Clear() { assets_.clear(); }

}  // namespace cq
