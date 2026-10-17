// ChuanqiCut — 变换层的顶点烘焙（RENDER-010 / B5.5 第一块消费方）
//
// 为什么几何在 core 而不在 shader（SHADER-010 的设计取舍，写清楚免得被"搬运回 GPU"）：
//   * `cos/sin` 与各端 libm / 各端 GPU 的三角函数末位并不保证一致；把旋转放进 shader
//     等于把「三端一致」交给着色器实现。放 core 后各端拿到的是**同一批顶点**。
//   * 放 core 才能用普通单测锁死（tests/unit/render/test_layer_geometry.cpp），
//     放 shader 只能上真机看画面 —— 而恒等档要求的是「与现有 blit 一致」，
//     那是一串可以逐位比的数字，不该只能用眼睛验。
//   * `ChqICommandEncoder` 没有绑 uniform 缓冲的方法，逐层参数走顶点也就免改契约头。
//
// 坐标口径（沿用 chq_transform.h 文件头，不得另立）：
//   * 画布归一化 + **左上原点、+y 向下**；换算像素时才转 NDC（ndc_y = 1 - 2·y/H）。
//   * 旋转在**像素平面**上做：归一化空间里的 45° 在非正方画布上会变成斜切。
//   * 轨级变换 = 片段的父级，叠加顺序取 `M(轨) ∘ M(片段)`（MODEL-004 把这一格让给本卡，
//     见 chq_timeline.h 的 ChqTrack::transform 注释）。轨级恒等时该合恒等。
//
// 硬约束：零平台类型、禁用异常、时间不进几何（取点由装配器负责）。

#ifndef CQ_CORE_RENDER_CHQ_LAYER_GEOMETRY_H_
#define CQ_CORE_RENDER_CHQ_LAYER_GEOMETRY_H_

#include <cstdint>

#include "cq/base/chq_status.h"
#include "cq/model/chq_transform.h"
#include "cq/render/chq_fit_mode.h"

namespace cq {

// 顶点交错布局：pos.x, pos.y, uv.u, uv.v, alpha（与 transform.vert 的 loc0/1/2 对齐）。
constexpr uint32_t kLayerVertexFloats = 5;
constexpr uint32_t kLayerVertexCount = 6;  // 两个三角形（ quad 无索引缓冲可绑）
constexpr uint32_t kLayerVertexBytes = 20U;
constexpr uint32_t kLayerFloatCapacity = kLayerVertexCount * kLayerVertexFloats;

struct ChqLayerInput {
    uint32_t canvas_width = 0;  // 画布像素（0 = 非法）
    uint32_t canvas_height = 0;
    uint32_t source_width = 0;  // 源帧像素（0 = 未知 → 不做宽高比适配）
    uint32_t source_height = 0;
    uint16_t source_rotation = 0;  // #21 显示旋转角（0/90/180/270），在 uv 层还原
    ChqFitMode fit_mode = ChqFitMode::kStretch;
    ChqTransform track;  // 父级；恒等 = 不参与
    ChqTransform clip;   // 子级
};

// 烘焙 6 个顶点到 out（容量至少 kLayerFloatCapacity 个 float）。
// 非法输入（画布尺寸 0 / out 空 / 两份 transform 任一 Validate 不过 / 含 NaN）
// → kInvalidArgument，且不写 out。
ChqStatus BakeLayerQuad(const ChqLayerInput& in, float* out, uint32_t out_float_capacity);

}  // namespace cq

#endif  // CQ_CORE_RENDER_CHQ_LAYER_GEOMETRY_H_
