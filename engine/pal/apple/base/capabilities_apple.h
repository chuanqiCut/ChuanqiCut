// ChuanqiCut — Apple 能力后端安装入口（CORE-007）
//
// ⚠️ 本头文件**故意不放在 core/include**：它是 Apple 平台专属的安装入口。
//    放进 core/include 会让内核公共头目录沾上平台概念，有违红线 #2 的精神
//    （PAL 头文件零平台类型）。平台专属声明一律留在 pal/<platform>/ 下。

#ifndef CQ_PAL_APPLE_CAPABILITIES_APPLE_H_
#define CQ_PAL_APPLE_CAPABILITIES_APPLE_H_

#include "cq/base/status.h"

namespace cq {
namespace apple {

// 安装 Apple 能力后端。
//
// 后端本体是进程生命周期内有效的静态实例，满足契约「生命周期须长于查询调用」
// 且不引入所有权歧义（内核侧不接管所有权，见 capabilities.cpp）。
// 可重复调用（幂等）。
Status InstallCapabilities();

}  // namespace apple
}  // namespace cq

#endif  // CQ_PAL_APPLE_CAPABILITIES_APPLE_H_
