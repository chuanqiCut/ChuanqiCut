// ChuanqiCut — PAL 平台日志后端 sink 契约（CORE-006）
//
// 职责：定义「平台日志后端」的契约。base 层（CORE-003）已定义 ILogSink 接口与默认
// FILE* 实现，但**不实现任何平台特后端**。本契约要求 PAL 提供一个 ILogSink 的
// 平台实现：iOS→os_log、Android→logcat、鸿蒙→hilog，并通过工厂返回。
//
// 边界：本文件不定义任何 os_log/logcat 调用细节（那是 PAL 实现层的事）。
// core 层只通过 cq::SetLogSink() 注入，与 base 层解耦。
// 帧级 trace（CQ_LOG_FRAME）已用 RationalTime pts 标识帧，平台 sink 只需把格式化好
// 的 UTF-8 文本交给对应系统日志，无需理解帧概念。
//
// 红线：零平台类型、零 FFmpeg 类型。

#ifndef CQ_PAL_LOG_H_
#define CQ_PAL_LOG_H_

#include "cq/base/logging.h"    // ILogSink（平台后端需实现此接口）
#include "cq/base/status.h"
#include "cq/pal/pal_common.h"

namespace cq {

// 契约函数（由 PAL 平台实现提供）：创建/销毁平台日志 sink。
// 返回的原始 ILogSink* 由调用方经 DestroyPlatformLogSink 释放（不 delete）。
ILogSink* CreatePlatformLogSink();
void DestroyPlatformLogSink(ILogSink* sink);

}  // namespace cq

#endif  // CQ_PAL_LOG_H_
