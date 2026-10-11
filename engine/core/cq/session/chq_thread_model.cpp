// ChuanqiCut — 线程角色体系实现（CORE-008）

#include "cq/session/chq_thread_model.h"

namespace cq {
namespace {

// 线程本地角色状态。
//
// 默认 kUnknown 而非 kMain：宁可"不知道"，不可把未标记的线程误判成主线程
// —— 误判会让「主线程零阻塞」的守卫形同虚设。
thread_local ChqThreadRole t_role = ChqThreadRole::kUnknown;

}  // namespace

void SetCurrentThreadRole(ChqThreadRole role) { t_role = role; }

ChqThreadRole CurrentThreadRole() { return t_role; }

bool IsMainThread() { return t_role == ChqThreadRole::kMain; }

bool IsAudioThread() { return t_role == ChqThreadRole::kAudio; }

const char* ThreadRoleName(ChqThreadRole role) {
    switch (role) {
        case ChqThreadRole::kUnknown:
            return "unknown";
        case ChqThreadRole::kMain:
            return "main";
        case ChqThreadRole::kSession:
            return "session";
        case ChqThreadRole::kDecode:
            return "decode";
        case ChqThreadRole::kRender:
            return "render";
        case ChqThreadRole::kEncode:
            return "encode";
        case ChqThreadRole::kAudio:
            return "audio";
        case ChqThreadRole::kInference:
            return "inference";
    }
    return "?";
}

}  // namespace cq
