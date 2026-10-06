// ChuanqiCut — SPSC 无锁样本环（AUDIO-001）
//
// ARCH-001 铁律 2 的另一个执行点：音频线程与上游（decode/session 线程）之间
// 的唯一合法通道。预分配 2 的幂字节容量，热路径只有原子 load/store 与 memcpy，
// 无锁、无分配、不阻塞。
//
// 并发模型（严格 SPSC，违规使用 = 数据竞争，后果自负）：
//   * Write 只允许**生产者单线程**调用；Read 只允许**消费者单线程**调用；
//   * head（读位置）只有消费者写，tail（写位置）只有生产者写，
//     各自 store-release / 对端 load-acquire，无需 CAS；
//   * 语义为**全有或全无**：空间/数据不足时返回 kResourceExhausted，
//     不做部分读写 —— 调用方按块重试，简化块处理逻辑。

#ifndef CQ_AUDIO_SPSC_RING_H_
#define CQ_AUDIO_SPSC_RING_H_

#include <atomic>
#include <cstdint>

#include "cq/base/status.h"

namespace cq {

class SpscSampleRing {
public:
    SpscSampleRing() = default;
    ~SpscSampleRing();

    SpscSampleRing(const SpscSampleRing&) = delete;
    SpscSampleRing& operator=(const SpscSampleRing&) = delete;

    // 预分配容量（向上取整到 2 的幂，字节）。只允许调用一次。
    // 实际容量可用 CapacityBytes() 查询 —— 调用方按返回值而不是入参做块规划。
    Status Init(uint64_t capacity_bytes);

    // 【生产者线程】写入 bytes 字节。空间不足 → kResourceExhausted（原数据未动）。
    Status Write(const void* data, uint64_t bytes);

    // 【消费者线程】读出 bytes 字节。可读不足 → kResourceExhausted（不动缓冲）。
    Status Read(void* out, uint64_t bytes);

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

#endif  // CQ_AUDIO_SPSC_RING_H_
