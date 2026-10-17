// ChuanqiCut — ChqEditorModelState 实现（UIA-009 子步骤 1）
//
// 契约见 editor_model_state.h。fingerprint 的字段集必须覆盖「时间线外观会变」
// 的全部实体字段（轨道属性 + 片段全部字段），漏一个字段就会出现
// 「改了但 digest 不变」的假阴性。

#include "cq/model/chq_editor_model_state.h"

namespace cq {

namespace {

// FNV-1a 64 位：把整数逐该厂商混入。够用于「变了没有」判定，不作他用。
void Mix(uint64_t& h, uint64_t v) {
    for (int i = 0; i < 8; ++i) {
        h ^= (v >> (i * 8)) & 0xFFu;
        h *= 0x100000001b3ull;
    }
}

void MixTime(uint64_t& h, const ChqRationalTime& t) {
    Mix(h, static_cast<uint64_t>(t.value));
    Mix(h, static_cast<uint64_t>(t.timescale));
}

}  // namespace

ChqEditorModelState::ChqEditorModelState() {
    // 初始（空时间线）快照立即发布：读路径从构造起就有值。
    Publish();
}

std::shared_ptr<const ChqModelSnapshot> ChqEditorModelState::CurrentSnapshot() const {
    std::lock_guard<std::mutex> lk(snap_mtx_);
    return published_;
}

std::shared_ptr<const ChqTimeline> ChqEditorModelState::CurrentTimeline() const {
    std::lock_guard<std::mutex> lk(snap_mtx_);
    return published_ ? published_->timeline : nullptr;
}

ChqStatus ChqEditorModelState::Execute(std::unique_ptr<ChqICommand> cmd) {
    ChqStatus s = history_.Execute(std::move(cmd), timeline_);
    if (!s.IsOk()) return s;
    Publish();
    RefreshHistoryFlags();
    return ChqStatus::Ok();
}

ChqStatus ChqEditorModelState::Undo() {
    ChqStatus s = history_.Undo(timeline_);
    if (!s.IsOk()) return s;
    Publish();
    RefreshHistoryFlags();
    return ChqStatus::Ok();
}

ChqStatus ChqEditorModelState::Redo() {
    ChqStatus s = history_.Redo(timeline_);
    if (!s.IsOk()) return s;
    Publish();
    RefreshHistoryFlags();
    return ChqStatus::Ok();
}

void ChqEditorModelState::RefreshHistoryFlags() {
    // 只在 session 线程调用（history_ 非线程安全）；原子量供任意线程读。
    can_undo_.store(history_.CanUndo(), std::memory_order_release);
    can_redo_.store(history_.CanRedo(), std::memory_order_release);
}

ChqStatus ChqEditorModelState::RegisterAsset(uint64_t asset_id, const std::string& path) {
    ChqStatus s = assets_.Register(asset_id, path);
    if (!s.IsOk()) return s;
    // 素材表进快照（预览按 asset_id 查路径）——必须重新发布，
    // 否则渲染侧拿到的还是旧素材表。素材表不进 fingerprint / 不参与 Undo。
    Publish();
    return ChqStatus::Ok();
}

uint64_t ChqEditorModelState::Digest() const { return Fingerprint(timeline_); }

uint64_t ChqEditorModelState::Fingerprint(const ChqTimeline& timeline) {
    uint64_t h = 0xcbf29ce484222325ull;  // FNV offset basis
    // 画布是项目级结构属性：改动必须推进 digest（UI 增量刷新与撤销判定都靠它）。
    Mix(h, static_cast<uint64_t>(timeline.CanvasWidth()));
    Mix(h, static_cast<uint64_t>(timeline.CanvasHeight()));
    Mix(h, timeline.Tracks().size());
    for (const ChqTrack& track : timeline.Tracks()) {
        Mix(h, track.id);
        Mix(h, static_cast<uint64_t>(track.kind));
        Mix(h, track.enabled ? 1 : 0);
        Mix(h, track.muted ? 1 : 0);
        Mix(h, track.clips.size());
        for (const ChqClip& c : track.clips) {
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
            // MODEL-003：效果栈（含每个效果的启用位与全部参数）。漏了它就会出现
            // 「改了属性但 digest 不变」的假阴性 —— UI 不刷新、装配缓存不失效。
            Mix(h, c.effects.Fingerprint());
        }
    }
    return h;
}

void ChqEditorModelState::Publish() {
    // 配对拷贝：ChqTimeline 与 ChqAssetRegistry 同版本发布（读侧一次加载，无撕裂）。
    auto snap = std::make_shared<const ChqModelSnapshot>(
        ChqModelSnapshot{std::make_shared<const ChqTimeline>(timeline_),
                         std::make_shared<const ChqAssetRegistry>(assets_)});
    std::lock_guard<std::mutex> lk(snap_mtx_);
    published_ = std::move(snap);
}

}  // namespace cq
