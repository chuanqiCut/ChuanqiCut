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

std::shared_ptr<const Timeline> EditorModelState::CurrentTimeline() const {
    std::lock_guard<std::mutex> lk(snap_mtx_);
    return published_;
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
    // 素材表不进 fingerprint / 不参与 Undo，但快照里的 Timeline 未变，
    // 无需重新发布（CurrentTimeline 只承载时间线）。版本推进由 EditorSession 做。
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
    auto snap = std::make_shared<const Timeline>(timeline_);
    std::lock_guard<std::mutex> lk(snap_mtx_);
    published_ = std::move(snap);
}

}  // namespace cq
