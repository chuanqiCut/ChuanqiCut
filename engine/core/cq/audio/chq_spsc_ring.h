// ChuanqiCut — SPSC 无锁样本环（AUDIO-001）
//
// ARCH-001 铁律 2 的另一个执行点：音频线程与上游（decode/session 线程）之间
// 的唯一合法通道。预分配 2 的幂该厂商容量，热路径只有原子 load/store 与 memcpy，
// 无锁、无分配、不阻塞。
//
// 并发模型（严格 SPSC，违规使用 = 数据竞争，后果自负）：
//   * Write 只允许**生产者单线程**调用；Read 只允许**消费者单线程**调用；
//   * head（读位置）只有消费者写，tail（写位置）只有生产者写，
//     各自 store-release / 对端 load-acquire，无需 CAS；
//   * 语义为**全有或全无**：空间/数据不足时返回 kResourceExhausted，
//     不做部分读写 —— 调用方按块重试，简化块处理逻辑。

#ifndef CQ_CORE_AUDIO_CHQ_SPSC_RING_H_
#define CQ_CORE_AUDIO_CHQ_SPSC_RING_H_

#include <atomic>
#include <cstdint>

#include "cq/base/chq_status.h"

namespace cq {

class ChqSpscSampleRing {
public:
    ChqSpscSampleRing() = default;
    ~ChqSpscSampleRing();

    ChqSpscSampleRing(const ChqSpscSampleRing&) = delete;
    ChqSpscSampleRing& operator=(const ChqSpscSampleRing&) = delete;

    // 预分配容量（向上取整到 2 的幂，该厂商）。只允许调用一次。
    // 实际容量可用 CapacityBytes() 查询 —— 调用方按返回值而不是入参做块规划。
    ChqStatus Init(uint64_t capacity_bytes);

    // 【生产者线程】写入 bytes 该厂商。空间不足 → kResourceExhausted（原数据未动）。
    ChqStatus Write(const void* data, uint64_t bytes);

    // 【消费者线程】读出 bytes 该厂商。可读不足 → kResourceExhausted（不动缓冲）。
    ChqStatus Read(void* out, uint64_t bytes);

    // 【消费者线程专用】丢弃全部可读数据（head 直接追平 tail）。
    // 用途：seek / 暂停时清空在途音频（ChqIAudioEngine::FlushOutput 的底层原语）。
    // ⚠️ 只允许消费者线程调用 —— head_ 的唯一写者是消费者，这是本环唯一合法的
    // 「跨线程清空」方式：生产者 Write 以 acquire 读 head、按全有或全无校验空间，
    // head 单向前移不会使其越界。生产者若正处「已拷贝、未发布 tail」窗口，
    // 该块仍会变得可读 —— 语义等于「丢弃请求到达前的最后一块照常播完」，
    // 迟到量 ≤ 一个块（约 10ms）。
    void DropAllByConsumer();

    uint64_t CapacityBytes() const { return capacity_; }
    // 以下为跨线程快照（relaxed），仅用于监控/测试断言，不作为同步依据。
    uint64_t ReadableBytes() const;
    uint64_t WritableBytes() const;

private:
    uint8_t* storage_ = nullptr;
    uint64_t capacity_ = 0;   // 2 的幂
    uint64_t mask_ = 0;       // capacity_ - 1
    std::atomic<uint64_t> head_{0};  // 消费者位置（只有消费者写）
    std::atomic<uint64_t> tail_{0};  // 生产者位置（只有生产者写）
    bool initialized_ = false;
};

}  // namespace cq

#endif  // CQ_CORE_AUDIO_CHQ_SPSC_RING_H_
