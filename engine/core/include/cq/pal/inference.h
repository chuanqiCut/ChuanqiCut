// ChuanqiCut — PAL Inference 抽象接口（CORE-006 / AI-001）
//
// 职责：推理后端抽象。下游 AI-001（IInferenceBackend）、PALA-020（CoreML）、
// PALD-020（TFLite，NNAPI/GPU/XNNPACK 回退）依赖。
//
// ADR-0005：共享模型资产不共享推理 SDK —— 多后端 + 强制 CPU 回退。
// 本契约只定义「加载模型 / 跑推理」的抽象，不绑定任何 SDK 类型（CoreML/TFLite 的
// 类型绝不出现在公共头，全部藏在 PAL 实现内）。
//
// 红线：零平台类型、零 FFmpeg 类型。

#ifndef CQ_PAL_INFERENCE_H_
#define CQ_PAL_INFERENCE_H_

#include <cstdint>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/status.h"
#include "cq/pal/pal_common.h"

namespace cq {

// 推理后端类型（枚举仅作 factory 选择；具体后端由平台实现决定，接口不绑定 SDK）。
enum class InferenceBackendType : int32_t {
    kAuto = 0,         // 平台自选（优先 NPU/ANE，否则 GPU/CPU）
    kCoreML,           // Apple ANE（仅 Apple 端有效，其它端回退）
    kTFLite,           // Android（NNAPI/GPU/XNNPACK 回退）
    kCpuReference,     // 纯 CPU 参考实现（兜底）
};

// 张量角色。
enum class TensorRole : int32_t {
    kInput = 0,
    kOutput,
};

// 推理张量描述（POD）。data 指向调用方/后端提供的样本内存。
struct InferenceTensor {
    InferenceDataType data_type = InferenceDataType::kUnknown;
    int32_t dim_count = 0;
    int64_t dims[8] = {};     // 固定上限覆盖 NCHW/NHWC；>8 维待 AI-001 实测（hypothesis）
    void* data = nullptr;
    uint64_t data_bytes = 0;
    TensorRole role = TensorRole::kInput;
};

// 模型资产描述。来源/许可/校验和登记在 third_party/models/manifest.toml（ADR-0005）。
struct ModelAsset {
    const char* model_id = nullptr;   // manifest 中的资产 ID
    const char* path = nullptr;       // 本地路径（已落地资产）
    size_t path_len = 0;
    const char* checksum = nullptr;   // 可选：完整性校验（如 sha256）
};

class IInferenceBackend : public IPalResource {
public:
    virtual Status LoadModel(const ModelAsset& asset) = 0;

    // 执行推理。inputs/outputs 由调用方填充（含 data 指针与 dims）。
    // 长任务，接受 CancelToken（大图推理可取消）。
    virtual Status Run(const InferenceTensor* inputs, int32_t input_count,
                       InferenceTensor* outputs, int32_t output_count,
                       const CancelToken& token) = 0;

    // 后端自身可用性（如 ANE/NNAPI 是否存在）。不可用不影响接口，调用方据此降级。
    virtual Status QueryAvailability(CapabilityValue& out) = 0;
};

// 工厂（由 PAL 平台实现）。返回 PalPtr。
Status CreateInferenceBackend(InferenceBackendType type, PalPtr<IInferenceBackend>& out_backend);

}  // namespace cq

#endif  // CQ_PAL_INFERENCE_H_
