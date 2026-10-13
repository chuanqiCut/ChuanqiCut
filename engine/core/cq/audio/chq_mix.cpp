// ChuanqiCut — 多轨混音原语实现（AUDIO-004）
//
// 实现约定（契约见 chq_mix.h）：
//   * 全部校验先于任何写内存 —— 全有或全无；
//   * size_t 乘加先防回绕（调用方算术 bug 变成错误码，而不是野读写）；
//   * 热路径只有乘法与比较，无分支预测陷阱之外的隐藏成本。

#include "cq/audio/chq_mix.h"

#include <cstddef>

namespace cq {

ChqStatus MixAccumulateRange(float* acc, size_t acc_frames, uint32_t channels,
                             const float* src, size_t src_frame0, size_t frames,
                             size_t dst_frame0, float gain) {
    if (acc == nullptr || src == nullptr) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};
    }
    if (channels == 0u || frames == 0u || acc_frames == 0u) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};
    }
    // 非有限增益会污染累加器（NaN 连乘即全块报废），拒于入口。
    if (!std::isfinite(gain)) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};
    }

    const size_t ch = static_cast<size_t>(channels);
    // 累加器侧越界：frames ≤ acc_frames 保证 acc_frames - frames 不回绕。
    if (frames > acc_frames || dst_frame0 > acc_frames - frames) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};
    }
    // 源侧基址乘加回绕防护（src 缓冲长度不可知，此处只防算术溢出，
    // 不替代调用方的边界责任 —— 契约见头文件）。
    if (src_frame0 > (SIZE_MAX / ch) || frames > (SIZE_MAX / ch)) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};
    }

    const size_t src_base = src_frame0 * ch;
    const size_t dst_base = dst_frame0 * ch;
    for (size_t i = 0; i < frames; ++i) {
        const size_t s = src_base + i * ch;
        const size_t d = dst_base + i * ch;
        for (size_t c = 0; c < ch; ++c) {
            acc[d + c] += src[s + c] * gain;
        }
    }
    return ChqStatus{ChqStatusCode::kOk};
}

ChqStatus MixClipRange(float* data, size_t frames, uint32_t channels) {
    if (data == nullptr) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};
    }
    if (channels == 0u || frames == 0u) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};
    }

    const size_t ch = static_cast<size_t>(channels);
    if (frames > (SIZE_MAX / ch)) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};
    }
    const size_t total = frames * ch;

    for (size_t i = 0; i < total; ++i) {
        // 非有限值（解码异常 / 累加溢出的下游）按 0 处置：输出恒在 [-1,1]，
        // 不存在 inf/NaN 穿透到平台引擎（"无溢出"的可测定义）。
        float v = data[i];
        if (!std::isfinite(v)) {
            v = 0.0f;
        } else if (v > 1.0f) {
            v = 1.0f;
        } else if (v < -1.0f) {
            v = -1.0f;
        }
        data[i] = v;
    }
    return ChqStatus{ChqStatusCode::kOk};
}

}  // namespace cq
