// ChuanqiCut — MEDIA-012 解码器池（DecoderPool）
//
// 实现 `IDecoderPool`（`frame_provider.h` 冻结接口）。跨平台层：零平台类型 / 零 FFmpeg 类型 /
// 无异常 / 时间用 RationalTime。
//
// ─────────────────────────────────────────────────────────────────────────────
// 硬解路数上限
// ─────────────────────────────────────────────────────────────────────────────
// * 上限由构造参数 `max_hardware_paths` 给定，默认保守值 `kDefaultMaxHardwarePaths = 1`。
// * **不写死 Apple 的具体数字**（VideoToolbox 并发硬解 session 数属平台知识，归 PAL）。
//   将来若 CORE-007 的 `ICapabilities` 能查到真实硬解路数上限，由调用方用其覆盖默认值
//   （`SetMaxHardwarePaths`）。core 层只认可配置的上限。
//
// ─────────────────────────────────────────────────────────────────────────────
// 超路数降级策略（不崩溃、不挂起）
// ─────────────────────────────────────────────────────────────────────────────
// 借用时优先复用池中「已释放的同 codec 解码器」（避免新建硬解 session）；否则若
// `active_count < max_hardware_paths` 经工厂新建一路；否则（满且无空闲）→ 返回
// `kResourceExhausted`（非错误计数、非崩溃、非挂起）。调用方据此做背压/排队。
//   * 不在此阻塞等待空闲：避免 CORE-005 踩过的条件变量谓词误用导致挂死/空容器访问。
//   * 不抢占最旧一路：硬解 session 中途抢占可能导致解码态损坏，风险不可控。
//   * 不在此静默降级软解：软解路径属 PALA-011 范畴，core 层无此能力（降级软解需 PAL 提供
//     软件解码 factory，本期未实现）。三者作为可选升级在任务报告里写明。
//
// 线程模型：池内部加锁（非阻塞），可被多轨并发借用；Acquire/Release 不阻塞，不会挂起。

#ifndef CQ_MEDIA_DECODER_POOL_H_
#define CQ_MEDIA_DECODER_POOL_H_

#include <cstdint>
#include <list>
#include <memory>
#include <mutex>
#include <vector>

#include "cq/base/status.h"            // Status / StatusCode
#include "cq/media/frame_provider.h"   // IDecoderPool / DecoderHandle / CodecId

namespace cq {

class IFrameDecoder;  // 前向声明（完整定义见 system_frame_provider.h）

// 解码器工厂：池在「无空闲可复用且路数未满」时调 Create 新建一路；池析构/清空时调
// Destroy 释放尚未复用的解码器。core 层不持有真实解码器实现（PALA-011 未做），故由注入方提供。
class IDecoderFactory {
public:
    virtual ~IDecoderFactory() = default;
    virtual Status Create(CodecId codec, DecoderHandle& out) = 0;
    virtual void Destroy(DecoderHandle decoder) = 0;
};

// 池管理的解码器句柄（CqDecoder 在 frame_provider.h 前向声明，此处完整定义）。
// 仅含跨平台元数据 + 真实解码器指针；不暴露任何平台类型。
struct CqDecoder {
    IFrameDecoder* decoder = nullptr;  // 池管理的真实解码器（由工厂注入；core 不拥有其类型）
    int32_t id = 0;                    // 诊断用稳定 id
};

// 从池句柄取底层解码器（provider 经此把解码路由到池中的解码器）。
inline IFrameDecoder* DecoderOf(DecoderHandle h) {
    return h ? h->decoder : nullptr;
}

class DecoderPool : public IDecoderPool {
public:
    static constexpr int32_t kDefaultMaxHardwarePaths = 1;

    // factory: 注入的解码器工厂；池以 unique_ptr 接管以便自行清理未复用解码器。
    DecoderPool(int32_t max_hardware_paths, std::unique_ptr<IDecoderFactory> factory);

    // ---- IDecoderPool ----
    // 借一个解码器（按 codec）。池满且无法复用 → 返回 kResourceExhausted（不崩溃）。
    Status AcquireDecoder(CodecId codec, DecoderHandle& out_decoder) override;
    void ReleaseDecoder(DecoderHandle decoder) override;  // 归还（置空闲，可复用，不销毁）
    int32_t ActiveCount() const override;                // 当前在用（已借未还）路数
    int32_t MaxHardwarePaths() const override;            // 硬解路数上限

    void SetMaxHardwarePaths(int32_t n);  // 允许运行时覆盖（如将来用 ICapabilities 查到的真值）

private:
    struct Slot {
        DecoderHandle handle;
        CodecId codec;
        bool in_use;
    };

    int32_t max_hardware_paths_;
    std::unique_ptr<IDecoderFactory> factory_;
    std::vector<Slot> slots_;        // 池（含空闲）
    mutable std::mutex mtx_;         // 非阻塞加锁
};

// 工厂：构造一个 DecoderPool（调用方持有 unique_ptr<IDecoderPool>）。
std::unique_ptr<IDecoderPool> CreateDecoderPool(
    int32_t max_hardware_paths, std::unique_ptr<IDecoderFactory> factory);

}  // namespace cq

#endif  // CQ_MEDIA_DECODER_POOL_H_
