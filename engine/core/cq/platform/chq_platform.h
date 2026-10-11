// ChuanqiCut — Platform 聚合头（CORE-006）
//
// 一次性包含 Platform 全部领域头文件，便于下游与编译验证 TU 使用。
// 各领域的接口定义分散在独立头文件（见 docs/specs/Platform-接口契约.md）。

#ifndef CQ_CORE_PLATFORM_CHQ_PLATFORM_H_
#define CQ_CORE_PLATFORM_CHQ_PLATFORM_H_

#include "cq/platform/chq_capabilities.h"
#include "cq/platform/chq_clock.h"
#include "cq/platform/chq_common.h"
#include "cq/platform/chq_fs.h"
#include "cq/platform/chq_gfx.h"
#include "cq/platform/chq_inference.h"
#include "cq/platform/chq_log.h"
#include "cq/platform/chq_media.h"
#include "cq/platform/chq_audio.h"

#endif  // CQ_CORE_PLATFORM_CHQ_PLATFORM_H_
