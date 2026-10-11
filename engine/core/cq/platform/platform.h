// ChuanqiCut — Platform 聚合头（CORE-006）
//
// 一次性包含 Platform 全部领域头文件，便于下游与编译验证 TU 使用。
// 各领域的接口定义分散在独立头文件（见 docs/specs/Platform-接口契约.md）。

#ifndef CQ_PLATFORM_PLATFORM_H_
#define CQ_PLATFORM_PLATFORM_H_

#include "cq/platform/capabilities.h"
#include "cq/platform/clock.h"
#include "cq/platform/common.h"
#include "cq/platform/fs.h"
#include "cq/platform/gfx.h"
#include "cq/platform/inference.h"
#include "cq/platform/log.h"
#include "cq/platform/media.h"
#include "cq/platform/audio.h"

#endif  // CQ_PLATFORM_PLATFORM_H_
