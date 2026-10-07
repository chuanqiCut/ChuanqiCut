// ChuanqiCut — CQSession 的真实定义（内核私有共享，不进公共头）
//
// 为什么单独成头：cq_sdk.cpp 拥有定义，cq_sdk_preview.cpp（预览 ABI，独立 TU，
// 见 ADR-0011 的隔离规则）需要从 CQSession* 取 EditorSession* 来挂模型快照。
// 两 TU 共享**同一份**定义 —— 在两个 .cpp 里各写一份会产生两个不同类型。
//
// ⚠️ 对外 cq_sdk.h 里 CQSession 仍是 opaque 句柄（纯 C 契约），本头**禁止**
//    被任何公共头 include。

#ifndef CQ_SESSION_IMPL_H_
#define CQ_SESSION_IMPL_H_

#include "cq/session/editor_session.h"

// 必须在**全局**命名空间 —— 放进匿名 namespace 会与公共头的
// `typedef struct CQSession CQSession;` 产生命名歧义（实测 clang 报
// "reference to 'CQSession' is ambiguous"）。
struct CQSession {
    cq::EditorSession impl;
};

#endif /* CQ_SESSION_IMPL_H_ */
