// ChuanqiCut — PAL 聚合头（CORE-006）
//
// 一次性包含 PAL 全部领域头文件，便于下游与编译验证 TU 使用。
// 各领域的接口定义分散在独立头文件（见 docs/specs/PAL-接口契约.md）。

#ifndef CQ_PAL_PAL_H_
#define CQ_PAL_PAL_H_

#include "cq/pal/capabilities.h"
#include "cq/pal/clock.h"
#include "cq/pal/common.h"
#include "cq/pal/fs.h"
#include "cq/pal/gfx.h"
#include "cq/pal/inference.h"
#include "cq/pal/log.h"
#include "cq/pal/media.h"
#include "cq/pal/audio.h"

#endif  // CQ_PAL_PAL_H_
