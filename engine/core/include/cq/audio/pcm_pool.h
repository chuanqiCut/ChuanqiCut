// ChuanqiCut — 预分配 PCM 缓冲池（AUDIO-001）
//
// ARCH-001 铁律 2 的执行点之一：音频线程无锁、无分配。
//   * Init()（非音频线程，如 session 线程）一次性预分配全部槽位与内存；
//   * Acquire()/Release()（音频线程热路径）只有原子操作与 memcpy 级指针运算，
//     绝不触碰堆；耗尽返回 kResourceExhausted，**绝不回退动态分配**。
//
// 并发模型：多生产者多消费者皆安全 —— freelist 是带 tag 的索引 Treiber 栈
// （CAS on 64 位 {tag,index}，tag 每次弹出自增，防 ABA）；另有 per-slot 状态位
// 双保险：重复 Release / 外来缓冲会被 kInvalidArgument 拒绝，不会造成栈环。

#ifndef CQ_AUDIO_PCM_POOL_H_
#define CQ_AUDIO_PCM_POOL_H_

#include <atomic>
#include <cstdint>

#include "cq/audio/audio_types.h"
#include "cq/base/status.h"

namespace cq {

class AudioBlockPool {
public:
    AudioBlockPool() = default;
    ~AudioBlockPool();

    AudioBlockPool(const AudioBlockPool&) = delete;
    AudioBlockPool& operator=(const AudioBlockPool&) = delete;

    // 预分配 block_count 个槽位，每槽 = spec.frames_per_block 帧的交错样本。
    // 只允许调用一次；重复调用返回 kInvalidArgument。
    // 允许在任意线程调用（约定 session 线程），此后 Acquire/Release 无锁。
    Status Init(uint32_t block_count, const AudioGraphSpec& spec);

    // 取一块缓冲。成功时 out 的元数据（format/channels/rate/bytes）已填好，
    // pts 置零由调用方在出队数据时回填（池不感知时间轴）。
    // 耗尽 → kResourceExhausted；未 Init → kInvalidArgument。
    Status Acquire(AudioBuffer& out);

    // 归还缓冲。重复归还 / 非 pool 发放的 data / 未 Init → kInvalidArgument。
    Status Release(const AudioBuffer& buf);

    // 统计（近似值：多线程下读取瞬间可能已过期，仅用于监控与测试）。
    uint32_t Capacity() const { return block_count_; }
    uint32_t InUse() const { return in_use_.load(std::memory_order_relaxed); }

private:
    // 64 位打包 {tag:32 | index:32}：tag 防 Treiber 栈 ABA。
    static uint64_t PackHead(uint32_t tag, uint32_t index) {
        return (static_cast<uint64_t>(tag) << 32) | static_cast<uint64_t>(index);
    }
    static uint32_t HeadIndex(uint64_t head) {
        return static_cast<uint32_t>(head & 0xFFFFFFFFu);
    }
    static uint32_t HeadTag(uint64_t head) {
        return static_cast<uint32_t>(head >> 32);
    }

    // 槽位状态（per-slot 双保险）。cpp 侧以 kStateFree/kStateAcquired 常量使用。
    enum class SlotState : uint8_t { kFree = 0, kAcquired = 1 };

    // 释放全部内存（析构与 Re-init 保护用）。
    void Teardown();

    std::atomic<uint64_t> free_head_{0};   // {tag,index}；kFreeListEmpty 见下
    std::atomic<uint32_t> in_use_{0};
    std::atomic<uint8_t>* slot_state_ = nullptr;  // 每槽一字节状态（预分配数组）
    uint32_t* next_ = nullptr;             // freelist 每槽 next（预分配数组）
    uint8_t* storage_ = nullptr;           // 连续样本内存（block_count_ 槽）
    AudioBuffer meta_{};                   // Acquire 时复制的规格模板（data/pts 逐块填）
    uint64_t slot_bytes_ = 0;
    uint32_t block_count_ = 0;
    bool initialized_ = false;

    static constexpr uint32_t kFreeListEmpty = 0xFFFFFFFFu;
};

}  // namespace cq

#endif  // CQ_AUDIO_PCM_POOL_H_
