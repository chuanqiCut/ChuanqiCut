// ChuanqiCut — 线程角色体系实现（CORE-008）

#include "cq/session/thread_model.h"

namespace cq {
namespace {

// 线程本地角色状态。
//
// 默认 kUnknown 而非 kMain：宁可"不知道"，不可把未标记的线程误判成主线程
// —— 误判会让「主线程零阻塞」的守卫形同虚设。
thread_local ThreadRole t_role = ThreadRole::kUnknown;

}  // namespace

void SetCurrentThreadRole(ThreadRole role) { t_role = role; }

ThreadRole CurrentThreadRole() { return t_role; }

bool IsMainThread() { return t_role == ThreadRole::kMain; }

bool IsAudioThread() { return t_role == ThreadRole::kAudio; }

const char* ThreadRoleName(ThreadRole role) {
    switch (role) {
        case ThreadRole::kUnknown:
            return "unknown";
        case ThreadRole::kMain:
            return "main";
        case ThreadRole::kSession:
            return "session";
        case ThreadRole::kDecode:
            return "decode";
        case ThreadRole::kRender:
            return "render";
        case ThreadRole::kEncode:
            return "encode";
        case ThreadRole::kAudio:
            return "audio";
        case ThreadRole::kInference:
            return "inference";
    }
    return "?";
}

}  // namespace cq
