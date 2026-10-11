// ChuanqiCut — 并发原语 / 有界队列 / ChqCancelToken 实现（CORE-005）
//
// 本文件为 base 层并发原语的少量非模板实现（ChqCancelToken 模板类本身在头文件内联；
// ChqBoundedQueue 为模板，全在头文件）。这里提供 `CancelledStatus()` 便捷函数，
// 并提供一处编译单元，使本模块在 -Werror 下可被单独编译、可被 cq_core 链接。

#include "cq/base/chq_concurrency.h"

namespace cq {

// 语义闭合辅助：返回「已取消」状态（等价于 ChqCancelToken 已取消时 Cancelled()）。
// 供不持有 token 的代码路径（如资源清理阶段）直接返回取消信号，避免调用方
// 手写 `ChqStatus{ChqStatusCode::kCancelled}` 散落各处、便于统一语义来源。
ChqStatus CancelledStatus() {
    return ChqStatus{ChqStatusCode::kCancelled};
}

}  // namespace cq
