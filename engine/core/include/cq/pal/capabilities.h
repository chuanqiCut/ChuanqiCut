// ChuanqiCut — PAL 能力查询接口与枚举（CORE-006 / CORE-007）
//
// 职责：定义能力查询的接口与枚举。下游 CORE-007（ICapabilities 与枚举）将**实现**
// 本契约；此处只**冻结接口与枚举**。
//
// 红线 #3（AGENTS.root.md）：能力必须运行时查询，不得用 #if __APPLE__ 推断。
//   Android 能力由机型决定、Apple 由芯片决定（如 ProRes 硬编仅部分芯片支持），
//   编译期判断必然出错。一律走 QueryCapability()。
//
// 红线：零平台类型、零 FFmpeg 类型。

#ifndef CQ_PAL_CAPABILITIES_H_
#define CQ_PAL_CAPABILITIES_H_

#include "cq/base/status.h"

namespace cq {

// 能力项（镜像 ARCH-004 §2；追加 GPU 后端标识）。
enum class Capability : int32_t {
    kHwDecodeH264 = 0,
    kHwDecodeHevc,
    kHwDecodeAv1,
    kHwDecodeProres,
    kHwEncodeH264,
    kHwEncodeHevc,
    kHwEncodeProres,
    k10BitPipeline,
    kHdrDisplay,
    kComputeShader,
    kFloatTexture,
    kExternalMemoryImport,
    kNpuInference,
    // GPU 后端标识（用于 RenderGraph 后端选择）
    kGpuMetal,
    kGpuGles,
    kGpuVulkan,
};

// 能力状态：缺失 / 可用 / 降级可用（能力缺失降级仍要做，见 ARCH-003 §7）。
enum class CapabilityValue : int32_t {
    kNo = 0,
    kYes,
    kDegraded,
};

// 能力查询接口（CORE-007 实现具体后端：读 Metal/芯片/机型）。
class ICapabilities {
public:
    virtual ~ICapabilities() = default;
    virtual CapabilityValue Query(Capability cap) const = 0;
};

// 注入能力后端（不接管所有权；其生命周期须长于查询调用）。
// 传入 nullptr 清除后端（此后 QueryCapability 返回 kNo）。
Status SetCapabilitiesBackend(ICapabilities* backend);

// 全局能力查询：委托给已注入后端；未注入返回 kNo。
CapabilityValue QueryCapability(Capability cap);

}  // namespace cq

#endif  // CQ_PAL_CAPABILITIES_H_
