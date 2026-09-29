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

#include <new>
#include <utility>
#include <vector>

#include "cq/base/status.h"
#include "cq/pal/capabilities.h"
#include "cq/session/editor_session.h"
#include "cq/session/snapshot.h"
#include "cq/session/thread_model.h"

// CQSession 的真实定义：就是 cq_sdk.h 里那个 opaque 句柄的本体。
// ⚠️ 必须定义在**全局**命名空间 —— 放进匿名 namespace 会与头文件的
//    `typedef struct CQSession CQSession;` 产生命名歧义（实测 clang 报
//    "reference to 'CQSession' is ambiguous"）。
struct CQSession {
    cq::EditorSession impl;
};

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
