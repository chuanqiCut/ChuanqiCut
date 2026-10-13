// ChuanqiCut — 画布适配视口计算（ADR-0018 / UIA-014）
//
// 从 preview/chq_preview_renderer.cpp 移出（B0）：
//   RenderGraph 的 blit 节点与预览**共用同一份**视口计算 —— 又是同一条理由：
//   两份实现必然漂移（ADR-0034「严禁两套渲染/交互逻辑」）。
//
// 三种模式都表达为「把全屏 blit 变换到一个矩形」：
//   kStretch / 源尺寸未知 / 同比例 → 整目标（与引入 ChqFitMode 前逐该厂商一致）；
//   kContain → 内切矩形居中（letterbox，不裁内容）；
//   kCover   → 外接矩形居中（裁剪铺满，超出目标的部分被光栅化丢弃）。

#ifndef CQ_CORE_RENDER_CHQ_FIT_VIEWPORT_H_
#define CQ_CORE_RENDER_CHQ_FIT_VIEWPORT_H_

#include <cstdint>

#include "cq/render/chq_fit_mode.h"

namespace cq {

// out = {x, y, w, h}（像素，原点 = target **左上**，与 ChqICommandEncoder::SetViewport
// 的约定一致）。src 尺寸为 0（尚未取帧，未知）时按整目标处理。
inline void ComputeFitViewport(ChqFitMode mode, uint32_t sw, uint32_t sh, uint32_t dw, uint32_t dh,
                               float out[4]) {
    out[0] = 0.0f;
    out[1] = 0.0f;
    out[2] = static_cast<float>(dw);
    out[3] = static_cast<float>(dh);
    if (mode == ChqFitMode::kStretch || sw == 0 || sh == 0 || dw == 0 || dh == 0 ||
        (sw == dw && sh == dh)) {
        return;
    }
    const double src_ar = static_cast<double>(sw) / static_cast<double>(sh);
    const double dst_ar = static_cast<double>(dw) / static_cast<double>(dh);
    // 宽度贴边：contain 且源更宽，或 cover 且源更矮/更窄（cover 取另一半分支）。
    const bool width_bound = (mode == ChqFitMode::kContain) ? (src_ar > dst_ar) : (src_ar <= dst_ar);
    double w = 0.0;
    double h = 0.0;
    if (width_bound) {
        w = static_cast<double>(dw);
        h = w / src_ar;
    } else {
        h = static_cast<double>(dh);
        w = h * src_ar;
    }
    if (w < 1.0) w = 1.0;
    if (h < 1.0) h = 1.0;
    out[0] = static_cast<float>((static_cast<double>(dw) - w) / 2.0);
    out[1] = static_cast<float>((static_cast<double>(dh) - h) / 2.0);
    out[2] = static_cast<float>(w);
    out[3] = static_cast<float>(h);
}

// 视口是否等于整目标（是 → 不调 SetViewport，与引入 ChqFitMode 前的编码序列逐该厂商一致）。
inline bool IsFullTargetViewport(const float vp[4], uint32_t dw, uint32_t dh) {
    return vp[0] == 0.0f && vp[1] == 0.0f && vp[2] == static_cast<float>(dw) &&
           vp[3] == static_cast<float>(dh);
}

}  // namespace cq

#endif  // CQ_CORE_RENDER_CHQ_FIT_VIEWPORT_H_
