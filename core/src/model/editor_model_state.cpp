// ChuanqiCut — EditorModelState 实现（UIA-009 子步骤 1）
//
// 契约见 editor_model_state.h。fingerprint 的字段集必须覆盖「时间线外观会变」
// 的全部实体字段（轨道属性 + 片段全部字段），漏一个字段就会出现
// 「改了但 digest 不变」的假阴性。

#include "cq/model/editor_model_state.h"

namespace cq {

namespace {

// FNV-1a 64 位：把整数逐字节混入。够用于「变了没有」判定，不作他用。
void Mix(uint64_t& h, uint64_t v) {
    for (int i = 0; i < 8; ++i) {
        h ^= (v >> (i * 8)) & 0xFFu;
        h *= 0x100000001b3ull;
    }
}

void MixTime(uint64_t& h, const RationalTime& t) {
    Mix(h, static_cast<uint64_t>(t.value));
    Mix(h, static_cast<uint64_t>(t.timescale));
}

}  // namespace

EditorModelState::EditorModelState() {
    // 初始（空时间线）快照立即发布：读路径从构造起就有值。
    Publish();
}

std::shared_ptr<const ModelSnapshot> EditorModelState::CurrentSnapshot() const {
    std::lock_guard<std::mutex> lk(snap_mtx_);
    return published_;
}

std::shared_ptr<const Timeline> EditorModelState::CurrentTimeline() const {
    std::lock_guard<std::mutex> lk(snap_mtx_);
    return published_ ? published_->timeline : nullptr;
}

Status EditorModelState::Execute(std::unique_ptr<ICommand> cmd) {
    Status s = history_.Execute(std::move(cmd), timeline_);
    if (!s.IsOk()) return s;
    Publish();
    return Status::Ok();
}

Status EditorModelState::RegisterAsset(uint64_t asset_id, const std::string& path) {
    Status s = assets_.Register(asset_id, path);
    if (!s.IsOk()) return s;
    // 素材表进快照（预览按 asset_id 查路径）——必须重新发布，
    // 否则渲染侧拿到的还是旧素材表。素材表不进 fingerprint / 不参与 Undo。
    Publish();
    return Status::Ok();
}

uint64_t EditorModelState::Digest() const { return Fingerprint(timeline_); }

uint64_t EditorModelState::Fingerprint(const Timeline& timeline) {
    uint64_t h = 0xcbf29ce484222325ull;  // FNV offset basis
    Mix(h, timeline.Tracks().size());
    for (const Track& track : timeline.Tracks()) {
        Mix(h, track.id);
        Mix(h, static_cast<uint64_t>(track.kind));
        Mix(h, track.enabled ? 1 : 0);
        Mix(h, track.muted ? 1 : 0);
        Mix(h, track.clips.size());
        for (const Clip& c : track.clips) {
            Mix(h, c.id);
            Mix(h, static_cast<uint64_t>(c.kind));
            Mix(h, c.source.asset_id);
            MixTime(h, c.source.source_in);
            MixTime(h, c.source.source_duration);
            MixTime(h, c.start);
            MixTime(h, c.duration);
            Mix(h, static_cast<uint64_t>(c.in_transition));
            Mix(h, static_cast<uint64_t>(c.out_transition));
            MixTime(h, c.transition_duration);
        }
    }
    return h;
}

void EditorModelState::Publish() {
    // 配对拷贝：Timeline 与 AssetRegistry 同版本发布（读侧一次加载，无撕裂）。
    auto snap = std::make_shared<const ModelSnapshot>(
        ModelSnapshot{std::make_shared<const Timeline>(timeline_),
                      std::make_shared<const AssetRegistry>(assets_)});
    std::lock_guard<std::mutex> lk(snap_mtx_);
    published_ = std::move(snap);
}

}  // namespace cq
