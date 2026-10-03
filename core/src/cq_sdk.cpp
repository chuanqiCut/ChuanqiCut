// ChuanqiCut — 对外 C ABI 实现（BIND-001）
//
// 本文件是 core/include/cq/cq_sdk.h 的实现侧：把 C++ 内核（EditorSession /
// 能力查询 / 线程角色）包装成纯 C 函数。
//
// ⚠️ 唯一的 C++ 出现在**本 .cpp 内**；公共头 cq_sdk.h 保持零 C++ 类型，
//    由 tests/unit/test_c_abi.c（真正的 C 翻译单元）机器校验。
//
// 内核禁用异常（ARCH-001）：分配一律用 `new (std::nothrow)`，
// 失败返回 NULL / 错误码，不抛不捕。

#include "cq/cq_sdk.h"

#include <cstring>
#include <memory>
#include <new>
#include <utility>
#include <vector>

#include "cq/base/status.h"
#include "cq/pal/capabilities.h"
#include "cq_session_impl.h"
#include "cq/model/timeline.h"
#include "cq/preview/player_clock.h"
#include "cq/session/editor_session.h"
#include "cq/session/snapshot.h"
#include "cq/session/thread_model.h"

// CQSession 的真实定义移至内核私有共享头（cq_session_impl.h）——
// cq_sdk_preview.cpp（UIA-009 子步骤 2 预览收口）需要从 CQSession* 取
// EditorSession*，两 TU 必须共享同一份定义。

namespace {

int32_t CodeOf(cq::Status st) { return static_cast<int32_t>(st.code); }

int32_t CodeOfEnum(cq::StatusCode code) { return static_cast<int32_t>(code); }

}  // namespace

// ---- 版本（数值由 CMake 注入，见 core/CMakeLists.txt）----
int32_t cq_version_major(void) { return CQ_VERSION_MAJOR; }
int32_t cq_version_minor(void) { return CQ_VERSION_MINOR; }
int32_t cq_version_patch(void) { return CQ_VERSION_PATCH; }

// ---- 状态码 ----
// 直接复用内核语义，不复制枚举（复制必然漂移）。
int32_t cq_status_is_ok(int32_t code) {
    return cq::Status{static_cast<cq::StatusCode>(code)}.IsOk() ? 1 : 0;
}

int32_t cq_status_is_error(int32_t code) {
    return cq::Status{static_cast<cq::StatusCode>(code)}.IsError() ? 1 : 0;
}

int32_t cq_status_is_cancelled(int32_t code) {
    return cq::Status{static_cast<cq::StatusCode>(code)}.IsCancelled() ? 1 : 0;
}

const char* cq_status_to_string(int32_t code) {
    return cq::StatusToString(static_cast<cq::StatusCode>(code));
}

// ---- 线程角色 ----
void cq_mark_main_thread(void) { cq::SetCurrentThreadRole(cq::ThreadRole::kMain); }

int32_t cq_is_main_thread(void) { return cq::IsMainThread() ? 1 : 0; }

// ---- 能力查询（红线 #3 的执行入口）----
int32_t cq_query_capability(int32_t capability) {
    return static_cast<int32_t>(cq::QueryCapability(static_cast<cq::Capability>(capability)));
}

// ---- 会话 ----
CQSession* cq_session_create(void) {
    CQSession* session = new (std::nothrow) CQSession();
    if (session == nullptr) {
        return nullptr;  // 分配失败：不抛，返回 NULL
    }
    cq::Status st = session->impl.Start();
    if (!st.IsOk()) {
        delete session;
        return nullptr;
    }
    return session;
}

void cq_session_destroy(CQSession* session) {
    if (session == nullptr) return;  // 幂等
    session->impl.Shutdown();
    delete session;
}

int32_t cq_session_submit(CQSession* session, const char* change_name, CQMutateFn mutate,
                          void* ctx) {
    if (session == nullptr || mutate == nullptr) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    // 把 C 函数指针包装成内核的 MutateFn。捕获的是两个 POD 指针，无生命周期问题。
    cq::Status st = session->impl.Submit(change_name, [mutate, ctx]() -> cq::Status {
        int32_t code = mutate(ctx);
        return cq::Status{static_cast<cq::StatusCode>(code)};
    });
    return CodeOf(st);
}

CQSnapshot cq_session_current_snapshot(const CQSession* session) {
    if (session == nullptr) return CQSnapshot{0, 0};
    cq::Snapshot s = session->impl.CurrentSnapshot();
    return CQSnapshot{s.version, s.digest};
}

int32_t cq_session_changes_since(const CQSession* session, uint64_t from_version,
                                 CQChangeRecord* out, int32_t capacity) {
    if (session == nullptr || out == nullptr || capacity <= 0) return 0;
    std::vector<cq::ChangeRecord> records;
    session->impl.ChangesSince(from_version, &records);
    int32_t written = 0;
    for (const cq::ChangeRecord& r : records) {
        if (written >= capacity) break;
        out[written].version = r.version;
        // name 指向静态存储（内核 ChangeRecord 同一约定），此处只转指针不拷贝。
        out[written].name = r.name;
        ++written;
    }
    return written;
}

int32_t cq_session_change_count(const CQSession* session) {
    if (session == nullptr) return 0;
    return static_cast<int32_t>(session->impl.ChangeCount());
}

void cq_session_set_observer(CQSession* session, CQSnapshotObserver observer, void* ctx) {
    if (session == nullptr) return;
    session->impl.SetSnapshotObserver([observer, ctx](const cq::Snapshot& s) {
        if (observer == nullptr) return;
        CQSnapshot cs{s.version, s.digest};
        observer(cs, ctx);
    });
}

// ---- 会话级模型（UIA-009 子步骤 1）-----------------------------------------

int32_t cq_session_register_asset(CQSession* session, uint64_t asset_id, const char* path) {
    if (session == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    return CodeOf(session->impl.SubmitRegisterAsset("register-asset", asset_id, path));
}

int32_t cq_session_add_track(CQSession* session, int32_t kind) {
    if (session == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    if (kind < 0 || kind > 1) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    const cq::TrackKind k = (kind == 0) ? cq::TrackKind::kVideo : cq::TrackKind::kAudio;
    return CodeOf(session->impl.SubmitAddTrack("add-track", k));
}

int32_t cq_session_add_clip(CQSession* session, uint64_t track_id, uint64_t asset_id,
                            int64_t start_value, int32_t start_timescale,
                            int64_t duration_value, int32_t duration_timescale,
                            int64_t source_in_value, int32_t source_in_timescale) {
    if (session == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    if (start_timescale <= 0 || duration_timescale <= 0 || source_in_timescale <= 0) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    cq::Clip clip;
    clip.kind = cq::ClipKind::kVideo;
    clip.source.asset_id = asset_id;
    clip.source.source_in = cq::RationalTime{source_in_value, source_in_timescale};
    clip.source.source_duration = cq::RationalTime{duration_value, duration_timescale};
    clip.start = cq::RationalTime{start_value, start_timescale};
    clip.duration = cq::RationalTime{duration_value, duration_timescale};
    return CodeOf(session->impl.SubmitAddClip("add-clip", track_id, clip));
}

// ---- 片段编辑与撤销（UIA-005）--------------------------------------------

int32_t cq_session_move_clip(CQSession* session, uint64_t clip_id, int64_t start_value,
                             int32_t start_timescale) {
    if (session == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    if (start_timescale <= 0) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    const cq::RationalTime start{start_value, start_timescale};
    return CodeOf(session->impl.SubmitMoveClip("move-clip", clip_id, start));
}

int32_t cq_session_trim_clip(CQSession* session, uint64_t clip_id, int64_t duration_value,
                             int32_t duration_timescale) {
    if (session == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    if (duration_timescale <= 0) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    const cq::RationalTime duration{duration_value, duration_timescale};
    return CodeOf(session->impl.SubmitTrimClip("trim-clip", clip_id, duration));
}

int32_t cq_session_undo(CQSession* session) {
    if (session == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    return CodeOf(session->impl.SubmitUndo("undo"));
}

int32_t cq_session_redo(CQSession* session) {
    if (session == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    return CodeOf(session->impl.SubmitRedo("redo"));
}

int32_t cq_session_can_undo(const CQSession* session) {
    if (session == nullptr) return 0;
    return session->impl.CanUndo() ? 1 : 0;
}

int32_t cq_session_can_redo(const CQSession* session) {
    if (session == nullptr) return 0;
    return session->impl.CanRedo() ? 1 : 0;
}

int32_t cq_session_track_count(const CQSession* session, int32_t* out_count) {
    if (session == nullptr || out_count == nullptr) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::Timeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::StatusCode::kInternal);  // 自定义状态无模型
    *out_count = static_cast<int32_t>(snap->Tracks().size());
    return CodeOfEnum(cq::StatusCode::kOk);
}

namespace {

void FillTrackInfo(const cq::Track& t, CQTrackInfo* out) {
    out->track_id = t.id;
    out->kind = (t.kind == cq::TrackKind::kVideo) ? 0 : 1;
    out->enabled = t.enabled ? 1 : 0;
    out->muted = t.muted ? 1 : 0;
}

void FillClipInfo(const cq::Track& t, const cq::Clip& c, CQClipInfo* out) {
    out->track_id = t.id;
    out->clip_id = c.id;
    out->asset_id = c.source.asset_id;
    out->start_value = c.start.value;
    out->start_timescale = c.start.timescale;
    out->duration_value = c.duration.value;
    out->duration_timescale = c.duration.timescale;
    out->source_in_value = c.source.source_in.value;
    out->source_in_timescale = c.source.source_in.timescale;
    out->source_duration_value = c.source.source_duration.value;
    out->source_duration_timescale = c.source.source_duration.timescale;
    out->in_transition = static_cast<int32_t>(c.in_transition);
    out->out_transition = static_cast<int32_t>(c.out_transition);
    out->transition_duration_value = c.transition_duration.value;
    out->transition_duration_timescale = c.transition_duration.timescale;
}

}  // namespace

int32_t cq_session_query_tracks(const CQSession* session, CQTrackInfo* out, int32_t capacity,
                                int32_t* out_count) {
    if (session == nullptr || out_count == nullptr || (out != nullptr && capacity <= 0)) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::Timeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::StatusCode::kInternal);

    const auto& tracks = snap->Tracks();
    *out_count = static_cast<int32_t>(tracks.size());
    if (out == nullptr) return CodeOfEnum(cq::StatusCode::kOk);  // 两段式：仅查总数
    int32_t written = 0;
    for (const cq::Track& t : tracks) {
        if (written >= capacity) break;
        FillTrackInfo(t, &out[written]);
        ++written;
    }
    *out_count = written;
    return CodeOfEnum(cq::StatusCode::kOk);
}

int32_t cq_session_query_clips(const CQSession* session, uint64_t track_id, CQClipInfo* out,
                               int32_t capacity, int32_t* out_count) {
    if (session == nullptr || out_count == nullptr || (out != nullptr && capacity <= 0)) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::Timeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::StatusCode::kInternal);

    // 先统计再写入（两段式友好）；单次遍历完成。
    int32_t total = 0;
    int32_t written = 0;
    for (const cq::Track& t : snap->Tracks()) {
        if (track_id != 0 && t.id != track_id) continue;
        total += static_cast<int32_t>(t.clips.size());
        if (out == nullptr) continue;
        for (const cq::Clip& c : t.clips) {
            if (written >= capacity) break;
            FillClipInfo(t, c, &out[written]);
            ++written;
        }
    }
    *out_count = (out == nullptr) ? total : written;
    return CodeOfEnum(cq::StatusCode::kOk);
}

int32_t cq_session_asset_count(const CQSession* session, int32_t* out_count) {
    if (session == nullptr || out_count == nullptr) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ModelSnapshot> snap = session->impl.CurrentModelSnapshot();
    if (!snap || !snap->assets) return CodeOfEnum(cq::StatusCode::kInternal);
    *out_count = static_cast<int32_t>(snap->assets->Count());
    return CodeOfEnum(cq::StatusCode::kOk);
}

int32_t cq_session_query_assets(const CQSession* session, CQAssetInfo* out, int32_t capacity,
                                int32_t* out_count) {
    if (session == nullptr || out_count == nullptr || (out != nullptr && capacity <= 0)) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ModelSnapshot> snap = session->impl.CurrentModelSnapshot();
    if (!snap || !snap->assets) return CodeOfEnum(cq::StatusCode::kInternal);

    std::vector<std::pair<uint64_t, cq::MediaSource>> listed = snap->assets->ListAssets();
    *out_count = static_cast<int32_t>(listed.size());
    if (out == nullptr) return CodeOfEnum(cq::StatusCode::kOk);  // 两段式：仅查总数
    int32_t written = 0;
    for (const auto& [id, src] : listed) {
        if (written >= capacity) break;
        out[written].asset_id = id;
        const char* p = (src.path != nullptr) ? src.path : "";
        const bool truncated = std::strlen(p) >= sizeof(out[written].path);
        std::strncpy(out[written].path, p, sizeof(out[written].path) - 1);
        out[written].path[sizeof(out[written].path) - 1] = '\0';
        out[written].path_truncated = truncated ? 1 : 0;
        ++written;
    }
    *out_count = written;
    return CodeOfEnum(cq::StatusCode::kOk);
}

// ---- 时间线总时长与播放时钟（UIA-010）--------------------------------------

int32_t cq_session_timeline_duration(const CQSession* session, int64_t* out_value,
                                     int32_t* out_timescale) {
    if (session == nullptr || out_value == nullptr || out_timescale == nullptr) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::Timeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::StatusCode::kInternal);
    const cq::RationalTime d = snap->Duration();
    *out_value = d.value;
    *out_timescale = d.timescale;
    return CodeOfEnum(cq::StatusCode::kOk);
}

// CQPlayer 的真实定义：包一层 PlayerClock（与 CQSession 同手法，
// 公共头只有 opaque 句柄）。
struct CQPlayer {
    explicit CQPlayer(const cq::RationalTime& frame) : impl(frame) {}
    cq::PlayerClock impl;
};

CQPlayer* cq_player_create(int64_t frame_value, int32_t frame_timescale) {
    // 参数非法时 PlayerClock 内部回落到 1001/30000，不返回 NULL（纯计算对象）。
    CQPlayer* p = new (std::nothrow) CQPlayer(cq::RationalTime{frame_value, frame_timescale});
    return p;  // 分配失败时为 nullptr
}

void cq_player_destroy(CQPlayer* player) {
    delete player;  // nullptr 安全
}

int32_t cq_player_set_duration(CQPlayer* player, int64_t value, int32_t timescale) {
    if (player == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    return CodeOf(player->impl.SetDuration(cq::RationalTime{value, timescale}));
}

void cq_player_set_loop(CQPlayer* player, int32_t loop) {
    if (player == nullptr) return;
    player->impl.SetLoop(loop != 0);
}

int32_t cq_player_play(CQPlayer* player) {
    if (player == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    return CodeOf(player->impl.Play());
}

void cq_player_pause(CQPlayer* player) {
    if (player == nullptr) return;
    player->impl.Pause();
}

void cq_player_stop(CQPlayer* player) {
    if (player == nullptr) return;
    player->impl.Stop();
}

int32_t cq_player_seek(CQPlayer* player, int64_t value, int32_t timescale) {
    if (player == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    return CodeOf(player->impl.Seek(cq::RationalTime{value, timescale}));
}

int32_t cq_player_is_playing(const CQPlayer* player) {
    if (player == nullptr) return 0;
    return player->impl.IsPlaying() ? 1 : 0;
}

int32_t cq_player_current_time(const CQPlayer* player, int64_t* out_value,
                               int32_t* out_timescale) {
    if (player == nullptr || out_value == nullptr || out_timescale == nullptr) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    const cq::RationalTime t = player->impl.CurrentTime();
    *out_value = t.value;
    *out_timescale = t.timescale;
    return CodeOfEnum(cq::StatusCode::kOk);
}

int32_t cq_player_tick(CQPlayer* player) {
    if (player == nullptr) return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    return CodeOf(player->impl.Tick());
}
