// ChuanqiCut — PAL 网络传输抽象（AIEDIT-001 冻结；平台实现 AIEDIT-004）
//
// ADR-0020 决策 2：HTTP/SSE 传输归 PAL（Apple 端 URLSession 原生实现，
// 不引第三方——manifest 无网络依赖是既成事实，破例要走
// cq-dependency-governance）；core 只见本抽象。消费方 = ai/llm_client.h。
//
// SSE 帧解析边界（冻结）：传输层负责**传输级**拆帧——按空行分隔事件、剥离
// "data:" 前缀与行结束符、跳过注释行（":" 开头心跳）与非 data 字段行
// （event:/id:/retry:）；OnEvent 收到的是单个事件的完整 data 载荷。
// "[DONE]" 哨兵原样送达，由调用方判定。SSE 载荷的 JSON 增量拼装归调用方。
//
// 红线 2/7：零平台类型、零第三方类型；错误一律 Status 返回（内核禁异常）。
// 线程约定：实现可内部起线程/队列，但回调（OnEvent）必须在 PostSse 返回前
// 于调用线程同步发生——与 ILlmClient「同步语义、内部异步」一致，调用方
// 无需加锁（ADR-0020 决策 5 的无状态化配套）。

#ifndef CQ_PAL_NET_H_
#define CQ_PAL_NET_H_

#include <cstdint>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/status.h"
#include "cq/pal/pal_common.h"

namespace cq {
namespace pal {

// 请求头（键值对；Authorization 等敏感头由绑定层注入，core 不持有明文）。
struct NetHeader {
    const char* name = nullptr;
    const char* value = nullptr;
};

// 一次性请求描述。url/body 以调用方缓冲传入，调用方保证在调用期间有效。
struct NetRequest {
    const char* url = nullptr;          // 完整 URL（含 scheme）
    size_t url_len = 0;
    const NetHeader* headers = nullptr;
    size_t header_count = 0;
    const char* body = nullptr;         // UTF-8（JSON）
    size_t body_len = 0;
    const char* content_type = "application/json";
    int64_t timeout_ms = 60000;         // 总超时 [E]；连接超时归平台实现配置
};

// 响应。body 指向传输实现持有的缓冲，**下次对本传输实例的任何调用或
// Destroy 之后失效**；调用方需要留存必须自行拷贝。
struct NetResponse {
    int32_t http_status = 0;    // 0 = 未收到 HTTP 响应（网络层失败，看 Status）
    const char* body = nullptr;
    size_t body_len = 0;
};

// SSE 事件监听器（调用方实现）。OnEvent 返回非 Ok → 传输终止流并以该
// Status 从 PostSse 返回（调用方主动中断的标准通道）。
class INetSseListener {
public:
    virtual ~INetSseListener() = default;
    virtual Status OnEvent(const char* data, size_t len) = 0;
};

class INetTransport : public IPalResource {
public:
    // 阻塞 POST，响应 JSON。HTTP >= 400 **不算**传输失败：正常返回，
    // http_status 与 body 原样带回，由调用方（ILlmClient）判定业务错误。
    virtual Status PostJson(const NetRequest& request, NetResponse& out_response,
                            const CancelToken& token) = 0;

    // 流式 POST（SSE）。每个完整事件回调一次 OnEvent；HTTP 状态非 200 或
    // 响应头阶段失败 → 不进事件循环，直接返回错误 Status。
    virtual Status PostSse(const NetRequest& request, INetSseListener& listener,
                           const CancelToken& token) = 0;
};

// 后端类型（枚举仅作 factory 选择；风格对齐 pal/inference.h 的
// InferenceBackendType——枚举点平台实现不是平台类型泄漏）。
enum class NetBackendType : int32_t {
    kAuto = 0,      // 平台自选（Apple → URLSession；Android/鸿蒙随 P1 各自落实现）
    kUrlSession,    // Apple 原生（AIEDIT-004 落地）
    kReference,     // 参考实现：仅测试与离线用途（P0 可不提供）
};

// 工厂（由 PAL 平台实现注册）。平台未实现所选后端 → kFormatUnsupported。
Status CreateNetTransport(NetBackendType type, PalPtr<INetTransport>& out_transport);

}  // namespace pal
}  // namespace cq

#endif  // CQ_PAL_NET_H_
