// ChuanqiCut — 预分配 PCM 缓冲池实现（AUDIO-001）

#include "cq/audio/pcm_pool.h"

#include <cstddef>
#include <new>

namespace cq {

namespace {
// 与 pcm_pool.h 私有枚举 SlotState 对齐（kFree=0 / kAcquired=1）。
constexpr uint8_t kStateFree = 0;
constexpr uint8_t kStateAcquired = 1;
}  // namespace

AudioBlockPool::~AudioBlockPool() { Teardown(); }

void AudioBlockPool::Teardown() {
    delete[] slot_state_;
    slot_state_ = nullptr;
    delete[] next_;
    next_ = nullptr;
    delete[] storage_;
    storage_ = nullptr;
    initialized_ = false;
    block_count_ = 0;
    slot_bytes_ = 0;
}

Status AudioBlockPool::Init(uint32_t block_count, const AudioGraphSpec& spec) {
    if (initialized_) {
        return Status{StatusCode::kInvalidArgument};  // 重复 Init
    }
    if (block_count == 0) {
        return Status{StatusCode::kInvalidArgument};
    }
    // 规格校验：格式可知、声道/采样率/帧数合法、单块字节数不溢出。
    AudioBuffer probe{};
    probe.format = spec.format;
    probe.channels = spec.channels;
    const uint64_t bytes_per_frame = probe.BytesPerFrame();
    if (bytes_per_frame == 0 || spec.sample_rate == 0 || spec.frames_per_block == 0) {
        return Status{StatusCode::kInvalidArgument};
    }
    const uint64_t slot_bytes =
        bytes_per_frame * static_cast<uint64_t>(spec.frames_per_block);
    const uint64_t total_bytes = slot_bytes * static_cast<uint64_t>(block_count);
    if (total_bytes > static_cast<uint64_t>(0xFFFFFFFFu)) {
        return Status{StatusCode::kInvalidArgument};  // 池总量超 4GB 视为配置错误
    }

    // 一次性预分配：槽状态数组 + freelist next 数组 + 连续样本内存。
    slot_state_ = new (std::nothrow) std::atomic<uint8_t>[block_count];
    next_ = new (std::nothrow) uint32_t[block_count];
    storage_ = new (std::nothrow) uint8_t[total_bytes];
    if (slot_state_ == nullptr || next_ == nullptr || storage_ == nullptr) {
        Teardown();
        return Status{StatusCode::kResourceExhausted};
    }
    for (uint32_t i = 0; i < block_count; ++i) {
        slot_state_[i].store(kStateFree, std::memory_order_relaxed);
        next_[i] = (i + 1 < block_count) ? (i + 1) : kFreeListEmpty;
    }
    free_head_.store(PackHead(1, 0), std::memory_order_relaxed);

    meta_ = AudioBuffer{};
    meta_.format = spec.format;
    meta_.channels = spec.channels;
    meta_.sample_rate = spec.sample_rate;
    meta_.frame_count = static_cast<uint64_t>(spec.frames_per_block);
    meta_.data_bytes = slot_bytes;

    slot_bytes_ = slot_bytes;
    block_count_ = block_count;
    in_use_.store(0, std::memory_order_relaxed);
    initialized_ = true;
    return Status::Ok();
}

Status AudioBlockPool::Acquire(AudioBuffer& out) {
    if (!initialized_) {
        return Status{StatusCode::kInvalidArgument};
    }
    // Treiber 弹栈：CAS(head) 直到拿到一个 index 或确认空。
    // tag 每次成功 CAS 自增，防「弹-还同一 index 使 head 复原」的 ABA 竞态。
    for (;;) {
        uint64_t head = free_head_.load(std::memory_order_acquire);  // 非 const：CAS 会写回
        const uint32_t index = HeadIndex(head);
        if (index == kFreeListEmpty) {
            return Status{StatusCode::kResourceExhausted};  // 池耗尽：绝不回退堆分配
        }
        const uint32_t tag = HeadTag(head);
        const uint32_t next = next_[index];
        if (free_head_.compare_exchange_weak(head, PackHead(tag + 1, next),
                                             std::memory_order_acq_rel,
                                             std::memory_order_acquire)) {
            // 状态位双保险：弹栈成功的 index 必然处于 kFree（能回到 freelist 的
            // 唯一路径是 Release 的 kAcquired→kFree CAS）。若不成立即内部不变量
            // 被破坏，返回 kUnknown 拒绝发放而不是交出坏状态。
            uint8_t expected = kStateFree;
            if (!slot_state_[index].compare_exchange_strong(
                    expected, kStateAcquired, std::memory_order_acq_rel,
                    std::memory_order_acquire)) {
                return Status{StatusCode::kUnknown};
            }
            out = meta_;
            out.data = storage_ + static_cast<size_t>(index) * static_cast<size_t>(slot_bytes_);
            out.pts = RationalTime{};
            in_use_.fetch_add(1, std::memory_order_relaxed);
            return Status::Ok();
        }
    }
}

Status AudioBlockPool::Release(const AudioBuffer& buf) {
    if (!initialized_) {
        return Status{StatusCode::kInvalidArgument};
    }
    // 外来缓冲校验：data 必须落在池内存范围内且与槽边界对齐。
    if (buf.data == nullptr || buf.data < reinterpret_cast<const void*>(storage_)) {
        return Status{StatusCode::kInvalidArgument};
    }
    const auto* begin = storage_;
    const auto* p = static_cast<const uint8_t*>(buf.data);
    const uint64_t total =
        static_cast<uint64_t>(slot_bytes_) * static_cast<uint64_t>(block_count_);
    if (p >= begin + total || (static_cast<uint64_t>(p - begin) % slot_bytes_) != 0) {
        return Status{StatusCode::kInvalidArgument};
    }
    const uint32_t index =
        static_cast<uint32_t>(static_cast<uint64_t>(p - begin) / slot_bytes_);

    // 状态位 CAS：kAcquired→kFree。重复 Release（已是 kFree）与
    // 「Init 前发放/槽从未发放」的不一致都会在此被拒绝。
    uint8_t expected = kStateAcquired;
    if (!slot_state_[index].compare_exchange_strong(expected, kStateFree,
                                                    std::memory_order_acq_rel,
                                                    std::memory_order_acquire)) {
        return Status{StatusCode::kInvalidArgument};
    }
    // Treiber 压栈。
    for (;;) {
        uint64_t head = free_head_.load(std::memory_order_acquire);  // 非 const：CAS 会写回
        const uint32_t tag = HeadTag(head);
        next_[index] = HeadIndex(head);
        if (free_head_.compare_exchange_weak(head, PackHead(tag + 1, index),
                                             std::memory_order_acq_rel,
                                             std::memory_order_acquire)) {
            break;
        }
    }
    in_use_.fetch_sub(1, std::memory_order_relaxed);
    return Status::Ok();
}

}  // namespace cq
