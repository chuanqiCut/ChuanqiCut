// ChuanqiCut — 渲染取帧接缝（RENDER-001 / B0）
//
// 为什么要有这个接口（不是"顺手抽个函数"）：
//   RenderGraph 的 source 节点需要「取一帧并导入成纹理」，但这件事牵扯解码会话、
//   CVMetalTextureCache、**跨帧复用的状态**（MEDIA-024 的展示区间复用），
//   这些状态归预览渲染器所有。若让 RenderGraph 自己去取帧，就要把这些状态复制一份
//   ——又是两套逻辑。故用接缝把「取帧」注入给执行器：
//     * 预览：ChqPreviewRenderer 实现（持有 provider 表与复用状态）
//     * 测试：假实现（不解码也能测图的装配与执行顺序）
//
// 硬约束：零平台类型（纹理用 opaque TextureHandle）、禁用异常。

#ifndef CQ_CORE_RENDER_CHQ_FRAME_SOURCE_H_
#define CQ_CORE_RENDER_CHQ_FRAME_SOURCE_H_

#include <cstdint>

#include "cq/base/chq_concurrency.h"
#include "cq/base/chq_rational_time.h"
#include "cq/base/chq_status.h"
#include "cq/media/chq_asset_registry.h"
#include "cq/platform/chq_common.h"  // TextureHandle

namespace cq {

class ChqIFrameSource {
public:
    virtual ~ChqIFrameSource() = default;

    // 取素材 asset_id 在 src_time 处的一帧并导入为可采样纹理。
    //   assets     —— 当前帧的素材表（asset_id → 路径）。由执行器转发，接缝本身不解释它。
    //   out_tex    —— 导入出的纹理句柄（生命周期归实现方；实现方负责回收上一帧的）
    //   out_w/out_h—— 帧的像素尺寸（视口计算需要）
    //   out_reused —— 本次是否命中了展示区间复用（未走解码）；诊断用，可空
    // 返回值：kOk / kIoNotFound（素材未注册）/ 解码与导入错误原样透传。
    virtual ChqStatus Acquire(uint64_t asset_id, const ChqRationalTime& src_time,
                              const ChqAssetRegistry& assets, TextureHandle& out_tex,
                              uint32_t& out_w, uint32_t& out_h, bool* out_reused,
                              const ChqCancelToken& token) = 0;
};

}  // namespace cq

#endif  // CQ_CORE_RENDER_CHQ_FRAME_SOURCE_H_
