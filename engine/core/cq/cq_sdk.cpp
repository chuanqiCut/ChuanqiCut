// ChuanqiCut — 对外 C ABI 实现（BIND-001）
//
// 本文件是 core/include/cq/cq_sdk.h 的实现侧：把 C++ 内核（ChqEditorSession /
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

#include "cq/base/chq_logging.h"  // CORE-010：workflow 日志（cq_log_configure_from_env）
#include "cq/base/chq_status.h"
#include "cq/platform/chq_capabilities.h"
#include "chq_session_impl.h"
#include "cq/model/chq_property.h"  // MODEL-003：效果属性（C ABI 的直接依赖，显式列出）
#include "cq/model/chq_timeline.h"
#include "cq/preview/chq_player_clock.h"
#include "cq/session/chq_editor_session.h"
#include "cq/session/chq_session_snapshot.h"
#include "cq/session/chq_thread_model.h"

// CQSession 的真实定义移至内核私有共享头（cq_session_impl.h）——
// cq_sdk_preview.cpp（UIA-009 子步骤 2 预览收口）需要从 CQSession* 取
// ChqEditorSession*，两 TU 必须共享同一份定义。

namespace {

int32_t CodeOf(cq::ChqStatus st) { return static_cast<int32_t>(st.code); }

int32_t CodeOfEnum(cq::ChqStatusCode code) { return static_cast<int32_t>(code); }

}  // namespace

// ---- 版本（数值由 CMake 注入，见 core/CMakeLists.txt）----
int32_t cq_version_major(void) { return CQ_VERSION_MAJOR; }
int32_t cq_version_minor(void) { return CQ_VERSION_MINOR; }
int32_t cq_version_patch(void) { return CQ_VERSION_PATCH; }

// ---- 状态码 ----
// 直接复用内核语义，不复制枚举（复制必然漂移）。
int32_t cq_status_is_ok(int32_t code) {
    return cq::ChqStatus{static_cast<cq::ChqStatusCode>(code)}.IsOk() ? 1 : 0;
}

int32_t cq_status_is_error(int32_t code) {
    return cq::ChqStatus{static_cast<cq::ChqStatusCode>(code)}.IsError() ? 1 : 0;
}

int32_t cq_status_is_cancelled(int32_t code) {
    return cq::ChqStatus{static_cast<cq::ChqStatusCode>(code)}.IsCancelled() ? 1 : 0;
}

const char* cq_status_to_string(int32_t code) {
    return cq::StatusToString(static_cast<cq::ChqStatusCode>(code));
}

// ---- 线程角色 ----
void cq_mark_main_thread(void) { cq::SetCurrentThreadRole(cq::ChqThreadRole::kMain); }

int32_t cq_is_main_thread(void) { return cq::IsMainThread() ? 1 : 0; }

// ---- 能力查询（红线 #3 的执行入口）----
int32_t cq_query_capability(int32_t capability) {
    return static_cast<int32_t>(cq::QueryCapability(static_cast<cq::ChqCapability>(capability)));
}

// ---- 会话 ----
CQSession* cq_session_create(void) {
    CQSession* session = new (std::nothrow) CQSession();
    if (session == nullptr) {
        return nullptr;  // 分配失败：不抛，返回 NULL
    }
    cq::ChqStatus st = session->impl.Start();
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
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    // 把 C 函数指针包装成内核的 ChqMutateFn。捕获的是两个 POD 指针，无生命周期问题。
    cq::ChqStatus st = session->impl.Submit(change_name, [mutate, ctx]() -> cq::ChqStatus {
        int32_t code = mutate(ctx);
        return cq::ChqStatus{static_cast<cq::ChqStatusCode>(code)};
    });
    return CodeOf(st);
}

CQSnapshot cq_session_current_snapshot(const CQSession* session) {
    if (session == nullptr) return CQSnapshot{0, 0};
    cq::ChqSnapshot s = session->impl.CurrentSnapshot();
    return CQSnapshot{s.version, s.digest};
}

int32_t cq_session_changes_since(const CQSession* session, uint64_t from_version,
                                 CQChangeRecord* out, int32_t capacity) {
    if (session == nullptr || out == nullptr || capacity <= 0) return 0;
    std::vector<cq::ChqChangeRecord> records;
    session->impl.ChangesSince(from_version, &records);
    int32_t written = 0;
    for (const cq::ChqChangeRecord& r : records) {
        if (written >= capacity) break;
        out[written].version = r.version;
        // name 指向静态存储（内核 ChqChangeRecord 同一约定），此处只转指针不拷贝。
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
    session->impl.SetSnapshotObserver([observer, ctx](const cq::ChqSnapshot& s) {
        if (observer == nullptr) return;
        CQSnapshot cs{s.version, s.digest};
        observer(cs, ctx);
    });
}

// ---- 会话级模型（UIA-009 子步骤 1）-----------------------------------------

int32_t cq_session_register_asset(CQSession* session, uint64_t asset_id, const char* path) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    return CodeOf(session->impl.SubmitRegisterAsset("register-asset", asset_id, path));
}

int32_t cq_session_add_track(CQSession* session, int32_t kind) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    if (kind < 0 || kind > 1) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    const cq::ChqTrackKind k = (kind == 0) ? cq::ChqTrackKind::kVideo : cq::ChqTrackKind::kAudio;
    return CodeOf(session->impl.SubmitAddTrack("add-track", k));
}

int32_t cq_session_add_clip(CQSession* session, uint64_t track_id, uint64_t asset_id,
                            int64_t start_value, int32_t start_timescale,
                            int64_t duration_value, int32_t duration_timescale,
                            int64_t source_in_value, int32_t source_in_timescale) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    if (start_timescale <= 0 || duration_timescale <= 0 || source_in_timescale <= 0) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    cq::ChqClip clip;
    clip.kind = cq::ChqClipKind::kVideo;
    clip.source.asset_id = asset_id;
    clip.source.source_in = cq::ChqRationalTime{source_in_value, source_in_timescale};
    clip.source.source_duration = cq::ChqRationalTime{duration_value, duration_timescale};
    clip.start = cq::ChqRationalTime{start_value, start_timescale};
    clip.duration = cq::ChqRationalTime{duration_value, duration_timescale};
    return CodeOf(session->impl.SubmitAddClip("add-clip", track_id, clip));
}

// ---- 片段编辑与撤销（UIA-005）--------------------------------------------

int32_t cq_session_move_clip(CQSession* session, uint64_t clip_id, int64_t start_value,
                             int32_t start_timescale) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    if (start_timescale <= 0) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    const cq::ChqRationalTime start{start_value, start_timescale};
    return CodeOf(session->impl.SubmitMoveClip("move-clip", clip_id, start));
}

int32_t cq_session_trim_clip(CQSession* session, uint64_t clip_id, int64_t duration_value,
                             int32_t duration_timescale) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    if (duration_timescale <= 0) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    const cq::ChqRationalTime duration{duration_value, duration_timescale};
    return CodeOf(session->impl.SubmitTrimClip("trim-clip", clip_id, duration));
}

// ---- 片段 / 轨道结构操作与左缘裁剪（EDIT-007/008）--------------------------

int32_t cq_session_trim_clip_in(CQSession* session, uint64_t clip_id, int64_t start_value,
                                int32_t start_timescale) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    if (start_timescale <= 0) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    const cq::ChqRationalTime start{start_value, start_timescale};
    return CodeOf(session->impl.SubmitTrimClipIn("trim-clip-in", clip_id, start));
}

int32_t cq_session_split_clip(CQSession* session, uint64_t clip_id, int64_t at_value,
                              int32_t at_timescale) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    if (at_timescale <= 0) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    const cq::ChqRationalTime at{at_value, at_timescale};
    return CodeOf(session->impl.SubmitSplitClip("split-clip", clip_id, at));
}

int32_t cq_session_remove_clip(CQSession* session, uint64_t clip_id) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    return CodeOf(session->impl.SubmitRemoveClip("remove-clip", clip_id));
}

int32_t cq_session_remove_track(CQSession* session, uint64_t track_id) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    return CodeOf(session->impl.SubmitRemoveTrack("remove-track", track_id));
}

// ---- 跨轨移动与画布（UIA-040）----------------------------------------------

int32_t cq_session_move_clip_to_track(CQSession* session, uint64_t clip_id, uint64_t track_id,
                                      int64_t start_value, int32_t start_timescale) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    if (start_timescale <= 0) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    const cq::ChqRationalTime start{start_value, start_timescale};
    return CodeOf(session->impl.SubmitMoveClipToTrack("move-clip-to-track", clip_id, track_id,
                                                      start));
}

int32_t cq_session_set_canvas(CQSession* session, int32_t width, int32_t height) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    return CodeOf(session->impl.SubmitSetCanvas("set-canvas", width, height));
}

int32_t cq_session_get_canvas(const CQSession* session, int32_t* out_width, int32_t* out_height) {
    if (session == nullptr || out_width == nullptr || out_height == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqTimeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::ChqStatusCode::kInternal);  // 自定义状态无模型
    *out_width = snap->CanvasWidth();
    *out_height = snap->CanvasHeight();
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

// ---- 片段效果属性（MODEL-003）------------------------------------------------

namespace {

// 字符串拷贝 + 截断标记（同 CQAssetInfo.path 的手法：截断要说出来，
// 不能让调用方把一个被切过的 id 当完整 id 用）。
void CopyStrTrunc(char* dst, size_t dst_size, const std::string& src, bool& truncated) {
    const bool cut = src.size() >= dst_size;
    std::strncpy(dst, src.c_str(), dst_size - 1);
    dst[dst_size - 1] = '\0';
    if (cut) truncated = true;
}

// ChqPropertyType → ABI type 码（显式映射：枚举重排不应悄悄改变 ABI 数值）。
int32_t PropTypeToAbi(cq::ChqPropertyType t) {
    switch (t) {
        case cq::ChqPropertyType::kInt64: return 0;
        case cq::ChqPropertyType::kFloat: return 1;
        case cq::ChqPropertyType::kBool: return 2;
        case cq::ChqPropertyType::kColor: return 3;
        case cq::ChqPropertyType::kVec2: return 4;
    }
    return -1;  // 枚举封闭，不可达；出现即内部不一致
}

void FillEffectParamInfo(const std::string& key, const cq::ChqPropertyValue& v,
                         CQEffectParamInfo* out) {
    bool truncated = false;
    CopyStrTrunc(out->key, sizeof(out->key), key, truncated);
    out->type = PropTypeToAbi(v.type);
    out->i = v.i;
    for (int i = 0; i < 4; ++i) out->v[i] = v.v[i];
    out->b = v.b ? 1 : 0;
    out->truncated = truncated ? 1 : 0;
}

}  // namespace

int32_t cq_session_add_clip_effect(CQSession* session, uint64_t clip_id,
                                   const char* effect_id, const char* effect_name) {
    if (session == nullptr || effect_id == nullptr || effect_name == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    cq::ChqEffectBinding effect;
    effect.effect_id = effect_id;    // 入队前拷贝：提交异步，调用方缓冲区可能先失效
    effect.effect_name = effect_name;
    return CodeOf(session->impl.SubmitAddClipEffect("add-clip-effect", clip_id, effect));
}

int32_t cq_session_remove_clip_effect(CQSession* session, uint64_t clip_id,
                                      const char* effect_id) {
    if (session == nullptr || effect_id == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    return CodeOf(
        session->impl.SubmitRemoveClipEffect("remove-clip-effect", clip_id, effect_id));
}

int32_t cq_session_set_clip_effect_enabled(CQSession* session, uint64_t clip_id,
                                           const char* effect_id, int32_t enabled) {
    if (session == nullptr || effect_id == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    return CodeOf(session->impl.SubmitSetClipEffectEnabled("set-clip-effect-enabled", clip_id,
                                                           effect_id, enabled != 0));
}

int32_t cq_session_set_clip_effect_param_i64(CQSession* session, uint64_t clip_id,
                                             const char* effect_id, const char* key,
                                             int64_t value) {
    if (session == nullptr || effect_id == nullptr || key == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    return CodeOf(session->impl.SubmitSetClipEffectParam(
        "set-effect-param", clip_id, effect_id, key, cq::ChqPropertyValue::I64(value)));
}

int32_t cq_session_set_clip_effect_param_float(CQSession* session, uint64_t clip_id,
                                               const char* effect_id, const char* key,
                                               float value) {
    if (session == nullptr || effect_id == nullptr || key == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    return CodeOf(session->impl.SubmitSetClipEffectParam(
        "set-effect-param", clip_id, effect_id, key, cq::ChqPropertyValue::F(value)));
}

int32_t cq_session_set_clip_effect_param_bool(CQSession* session, uint64_t clip_id,
                                              const char* effect_id, const char* key,
                                              int32_t value) {
    if (session == nullptr || effect_id == nullptr || key == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    return CodeOf(session->impl.SubmitSetClipEffectParam(
        "set-effect-param", clip_id, effect_id, key, cq::ChqPropertyValue::B(value != 0)));
}

int32_t cq_session_set_clip_effect_param_color(CQSession* session, uint64_t clip_id,
                                               const char* effect_id, const char* key,
                                               float r, float g, float b, float a) {
    if (session == nullptr || effect_id == nullptr || key == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    return CodeOf(session->impl.SubmitSetClipEffectParam(
        "set-effect-param", clip_id, effect_id, key, cq::ChqPropertyValue::Color(r, g, b, a)));
}

int32_t cq_session_set_clip_effect_param_vec2(CQSession* session, uint64_t clip_id,
                                              const char* effect_id, const char* key,
                                              float x, float y) {
    if (session == nullptr || effect_id == nullptr || key == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    return CodeOf(session->impl.SubmitSetClipEffectParam(
        "set-effect-param", clip_id, effect_id, key, cq::ChqPropertyValue::Vec2(x, y)));
}

int32_t cq_session_clip_effect_count(const CQSession* session, uint64_t clip_id,
                                     int32_t* out_count) {
    if (session == nullptr || out_count == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqTimeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::ChqStatusCode::kInternal);
    const cq::ChqClip* clip = snap->FindClip(clip_id);
    if (clip == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    *out_count = static_cast<int32_t>(clip->effects.Size());
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

int32_t cq_session_query_clip_effects(const CQSession* session, uint64_t clip_id,
                                      CQEffectInfo* out, int32_t capacity, int32_t* out_count) {
    if (session == nullptr || out_count == nullptr || (out != nullptr && capacity <= 0)) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqTimeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::ChqStatusCode::kInternal);
    const cq::ChqClip* clip = snap->FindClip(clip_id);
    if (clip == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);

    const auto& effects = clip->effects.Effects();
    *out_count = static_cast<int32_t>(effects.size());
    if (out == nullptr) return CodeOfEnum(cq::ChqStatusCode::kOk);  // 两段式：仅查总数
    int32_t written = 0;
    for (const cq::ChqEffectBinding& e : effects) {
        if (written >= capacity) break;
        CQEffectInfo& dst = out[written];
        bool truncated = false;
        CopyStrTrunc(dst.effect_id, sizeof(dst.effect_id), e.effect_id, truncated);
        CopyStrTrunc(dst.effect_name, sizeof(dst.effect_name), e.effect_name, truncated);
        dst.enabled = e.enabled ? 1 : 0;
        dst.param_count = static_cast<int32_t>(e.params.Size());
        dst.truncated = truncated ? 1 : 0;
        ++written;
    }
    *out_count = written;
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

int32_t cq_session_clip_effect_param_count(const CQSession* session, uint64_t clip_id,
                                           const char* effect_id, int32_t* out_count) {
    if (session == nullptr || effect_id == nullptr || out_count == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqTimeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::ChqStatusCode::kInternal);
    const cq::ChqClip* clip = snap->FindClip(clip_id);
    if (clip == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    const cq::ChqEffectBinding* effect = clip->effects.Find(effect_id);
    if (effect == nullptr) return CodeOfEnum(cq::ChqStatusCode::kIoNotFound);
    *out_count = static_cast<int32_t>(effect->params.Size());
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

int32_t cq_session_query_clip_effect_params(const CQSession* session, uint64_t clip_id,
                                            const char* effect_id, CQEffectParamInfo* out,
                                            int32_t capacity, int32_t* out_count) {
    if (session == nullptr || effect_id == nullptr || out_count == nullptr ||
        (out != nullptr && capacity <= 0)) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqTimeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::ChqStatusCode::kInternal);
    const cq::ChqClip* clip = snap->FindClip(clip_id);
    if (clip == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    const cq::ChqEffectBinding* effect = clip->effects.Find(effect_id);
    if (effect == nullptr) return CodeOfEnum(cq::ChqStatusCode::kIoNotFound);

    // map 有序 ⇒ 输出顺序稳定（与 ChqPropertyBag::Fingerprint 的遍历序一致）。
    const auto& entries = effect->params.Entries();
    *out_count = static_cast<int32_t>(entries.size());
    if (out == nullptr) return CodeOfEnum(cq::ChqStatusCode::kOk);  // 两段式：仅查总数
    int32_t written = 0;
    for (const auto& kv : entries) {
        if (written >= capacity) break;
        FillEffectParamInfo(kv.first, kv.second, &out[written]);
        ++written;
    }
    *out_count = written;
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

int32_t cq_session_undo(CQSession* session) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    return CodeOf(session->impl.SubmitUndo("undo"));
}

int32_t cq_session_redo(CQSession* session) {
    if (session == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
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
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqTimeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::ChqStatusCode::kInternal);  // 自定义状态无模型
    *out_count = static_cast<int32_t>(snap->Tracks().size());
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

namespace {

void FillTrackInfo(const cq::ChqTrack& t, CQTrackInfo* out) {
    out->track_id = t.id;
    out->kind = (t.kind == cq::ChqTrackKind::kVideo) ? 0 : 1;
    out->enabled = t.enabled ? 1 : 0;
    out->muted = t.muted ? 1 : 0;
}

void FillClipInfo(const cq::ChqTrack& t, const cq::ChqClip& c, CQClipInfo* out) {
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
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqTimeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::ChqStatusCode::kInternal);

    const auto& tracks = snap->Tracks();
    *out_count = static_cast<int32_t>(tracks.size());
    if (out == nullptr) return CodeOfEnum(cq::ChqStatusCode::kOk);  // 两段式：仅查总数
    int32_t written = 0;
    for (const cq::ChqTrack& t : tracks) {
        if (written >= capacity) break;
        FillTrackInfo(t, &out[written]);
        ++written;
    }
    *out_count = written;
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

int32_t cq_session_query_clips(const CQSession* session, uint64_t track_id, CQClipInfo* out,
                               int32_t capacity, int32_t* out_count) {
    if (session == nullptr || out_count == nullptr || (out != nullptr && capacity <= 0)) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqTimeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::ChqStatusCode::kInternal);

    // 先统计再写入（两段式友好）；单次遍历完成。
    int32_t total = 0;
    int32_t written = 0;
    for (const cq::ChqTrack& t : snap->Tracks()) {
        if (track_id != 0 && t.id != track_id) continue;
        total += static_cast<int32_t>(t.clips.size());
        if (out == nullptr) continue;
        for (const cq::ChqClip& c : t.clips) {
            if (written >= capacity) break;
            FillClipInfo(t, c, &out[written]);
            ++written;
        }
    }
    *out_count = (out == nullptr) ? total : written;
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

int32_t cq_session_asset_count(const CQSession* session, int32_t* out_count) {
    if (session == nullptr || out_count == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqModelSnapshot> snap = session->impl.CurrentModelSnapshot();
    if (!snap || !snap->assets) return CodeOfEnum(cq::ChqStatusCode::kInternal);
    *out_count = static_cast<int32_t>(snap->assets->Count());
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

int32_t cq_session_query_assets(const CQSession* session, CQAssetInfo* out, int32_t capacity,
                                int32_t* out_count) {
    if (session == nullptr || out_count == nullptr || (out != nullptr && capacity <= 0)) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqModelSnapshot> snap = session->impl.CurrentModelSnapshot();
    if (!snap || !snap->assets) return CodeOfEnum(cq::ChqStatusCode::kInternal);

    std::vector<std::pair<uint64_t, cq::ChqMediaSource>> listed = snap->assets->ListAssets();
    *out_count = static_cast<int32_t>(listed.size());
    if (out == nullptr) return CodeOfEnum(cq::ChqStatusCode::kOk);  // 两段式：仅查总数
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
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

// ---- 时间线总时长与播放时钟（UIA-010）--------------------------------------

int32_t cq_session_timeline_duration(const CQSession* session, int64_t* out_value,
                                     int32_t* out_timescale) {
    if (session == nullptr || out_value == nullptr || out_timescale == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    std::shared_ptr<const cq::ChqTimeline> snap = session->impl.CurrentTimeline();
    if (!snap) return CodeOfEnum(cq::ChqStatusCode::kInternal);
    const cq::ChqRationalTime d = snap->Duration();
    *out_value = d.value;
    *out_timescale = d.timescale;
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

// CQPlayer 的真实定义：包一层 ChqPlayerClock（与 CQSession 同手法，
// 公共头只有 opaque 句柄）。
struct CQPlayer {
    explicit CQPlayer(const cq::ChqRationalTime& frame) : impl(frame) {}
    cq::ChqPlayerClock impl;
};

CQPlayer* cq_player_create(int64_t frame_value, int32_t frame_timescale) {
    // 参数非法时 ChqPlayerClock 内部回落到 1001/30000，不返回 NULL（纯计算对象）。
    CQPlayer* p = new (std::nothrow) CQPlayer(cq::ChqRationalTime{frame_value, frame_timescale});
    return p;  // 分配失败时为 nullptr
}

void cq_player_destroy(CQPlayer* player) {
    delete player;  // nullptr 安全
}

int32_t cq_player_set_duration(CQPlayer* player, int64_t value, int32_t timescale) {
    if (player == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    return CodeOf(player->impl.SetDuration(cq::ChqRationalTime{value, timescale}));
}

void cq_player_set_loop(CQPlayer* player, int32_t loop) {
    if (player == nullptr) return;
    player->impl.SetLoop(loop != 0);
}

int32_t cq_player_play(CQPlayer* player) {
    if (player == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
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
    if (player == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    return CodeOf(player->impl.Seek(cq::ChqRationalTime{value, timescale}));
}

int32_t cq_player_is_playing(const CQPlayer* player) {
    if (player == nullptr) return 0;
    return player->impl.IsPlaying() ? 1 : 0;
}

int32_t cq_player_current_time(const CQPlayer* player, int64_t* out_value,
                               int32_t* out_timescale) {
    if (player == nullptr || out_value == nullptr || out_timescale == nullptr) {
        return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    }
    const cq::ChqRationalTime t = player->impl.CurrentTime();
    *out_value = t.value;
    *out_timescale = t.timescale;
    return CodeOfEnum(cq::ChqStatusCode::kOk);
}

int32_t cq_player_tick(CQPlayer* player) {
    if (player == nullptr) return CodeOfEnum(cq::ChqStatusCode::kInvalidArgument);
    return CodeOf(player->impl.Tick());
}

/* ==========================================================================
 * 日志：workflow 筛选（CORE-010）
 * ========================================================================== */

void cq_log_configure_from_env(void) { cq::ConfigureLogFromEnv(); }

void cq_log_set_level(int32_t level) {
    // 越界一律忽略。理由：静默地把 7 夹到 4 会让调用方以为自己设成功了。
    switch (level) {
        case static_cast<int32_t>(cq::ChqLogLevel::kTrace):
        case static_cast<int32_t>(cq::ChqLogLevel::kDebug):
        case static_cast<int32_t>(cq::ChqLogLevel::kInfo):
        case static_cast<int32_t>(cq::ChqLogLevel::kWarn):
        case static_cast<int32_t>(cq::ChqLogLevel::kError):
            cq::SetLogLevel(static_cast<cq::ChqLogLevel>(level));
            return;
        default:
            return;
    }
}
