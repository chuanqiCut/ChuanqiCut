// ChuanqiCut — LLM 客户端抽象（AIEDIT-001 冻结；实现 AIEDIT-004）
//
// 分层边界（ADR-0020 决策 2）：本接口在 core（三端共享），传输实现走
// pal/<platform>/net（Apple = URLSession 原生，不引第三方）；core 只见
// cq/pal/net.h 的 INetTransport 抽象。协议收敛 OpenAI-compatible
// chat/completions（决策 5）——同一客户端代码可切供应商，只换 LlmConfig。
//
// key 不落盘明文：LlmConfig.api_key_ref 是**引用**（如 iOS Keychain 条目），
// 由绑定层解析为真实凭据并注入传输层头（SPEC §8）；core 不接触明文 key。
//
// 降级链路（ADR-0020 决策 6）：配置为空 / 网络不可达 / 决策三连失败 →
// 本地规则引擎接管，由管线（AIEDIT-005）编排，本接口不感知降级。
//
// 红线 2/7：零平台类型、零第三方类型（grep 审查项，AIEDIT-001 验收）。
// 线程约定：Complete 为同步语义、内部异步（SPEC §8）——阻塞调用线程直至
// 完成/取消/超时；主线程禁止调用（红线 8 由调用方保证，分析管线在自有线程）。

#ifndef CQ_AI_LLM_CLIENT_H_
#define CQ_AI_LLM_CLIENT_H_

#include <cstdint>
#include <string>
#include <vector>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/status.h"
#include "cq/pal/net.h"
#include "cq/pal/pal_common.h"

namespace cq {

// LLM 接入配置（SPEC §8）。endpoint/model 为空 → 不创建客户端，直接走降级。
struct LlmConfig {
    std::string endpoint;       // OpenAI-compatible base，如 "https://host/v1"
    std::string model;          // 模型名（chat/completions 的 model 字段）
    std::string api_key_ref;    // 凭据引用（Keychain 条目名），不是明文 key
    double temperature = 0.7;   // 统计类参数，允许浮点（红线 4 只约束时间字段）
    int32_t max_tokens = 4096;
    int64_t timeout_ms = 60000; // 总超时 [E]（SPEC §8：连接 10s / 总 60s，连接超时归传输实现）
};

struct LlmMessage {
    std::string role;       // "system" | "user" | "assistant"
    std::string content;
};

struct LlmRequest {
    std::vector<LlmMessage> messages;
    bool response_json = true;  // 期望 JSON 输出（OpenAI response_format 提示；
                                // 校验仍由 C++ 权威执行，提示只降劣质格式概率）
};

struct LlmUsage {
    int64_t prompt_tokens = 0;
    int64_t completion_tokens = 0;
};

struct LlmResult {
    Status status = Status::Ok();   // Ok / kCancelled / 传输或协议错误
    std::string text;               // 助手消息原文（应为 EditPlan JSON）
    LlmUsage usage{};
};

class ILlmClient {
public:
    virtual ~ILlmClient() = default;

    // 单轮补全。非流式（决策 JSON 不需要逐字流式，SPEC §3 步骤 3；
    // SSE 通道由 INetTransport::PostSse 承载，供 P1 对话逐字显示时启用）。
    // HTTP >= 400 / 响应体非法 JSON → 返回非 Ok Status（错误细节进诊断日志）。
    virtual LlmResult Complete(const LlmRequest& request, const CancelToken& token) = 0;
};

// 工厂：注入传输与配置。config 非法（endpoint/model 空）→ kInvalidArgument。
// transport 以 PalPtr 移入（客户端独占其生命周期）。
Status CreateLlmClient(const LlmConfig& config, PalPtr<pal::INetTransport> transport,
                       PalPtr<ILlmClient>& out_client);

}  // namespace cq

#endif  // CQ_AI_LLM_CLIENT_H_
