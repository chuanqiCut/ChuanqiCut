// ChuanqiCut — SPSC 无锁样本环实现（AUDIO-001）
//
// 索引单调递增（uint64 回绕安全：差值比较用无符号减法），实际下标 = idx & mask。
// 环内不存头部/长度元数据，纯粹字节流 —— 块边界由调用方协议维护
// （PCM 恒定块规格下天然隐含）。

#include "cq/audio/spsc_ring.h"

#include <cstring>
#include <new>

namespace cq {

SpscSampleRing::~SpscSampleRing() {
    delete[] storage_;
    storage_ = nullptr;
}

Status SpscSampleRing::Init(uint64_t capacity_bytes) {
    if (initialized_) {
        return Status{StatusCode::kInvalidArgument};  // 重复 Init
    }
    if (capacity_bytes == 0) {
        return Status{StatusCode::kInvalidArgument};
    }
    // 向上取整到 2 的幂（用位技巧，不引入浮点/查表）。
    uint64_t pow2 = 1;
    while (pow2 < capacity_bytes) {
        pow2 <<= 1;
        if (pow2 == 0) {
            return Status{StatusCode::kInvalidArgument};  // 溢出（>2^63 字节不现实）
        }
    }
    storage_ = new (std::nothrow) uint8_t[pow2];
    if (storage_ == nullptr) {
        return Status{StatusCode::kResourceExhausted};
    }
    capacity_ = pow2;
    mask_ = pow2 - 1;
    head_.store(0, std::memory_order_relaxed);
    tail_.store(0, std::memory_order_relaxed);
    initialized_ = true;
    return Status::Ok();
}

Status SpscSampleRing::Write(const void* data, uint64_t bytes) {
    if (!initialized_ || data == nullptr) {
        return Status{StatusCode::kInvalidArgument};
    }
    if (bytes == 0) {
        return Status::Ok();
    }
    if (bytes > capacity_) {
        return Status{StatusCode::kInvalidArgument};  // 单块超过总容量：协议错误
    }
    const uint64_t tail = tail_.load(std::memory_order_relaxed);
    const uint64_t head = head_.load(std::memory_order_acquire);  // 对端发布的读位置
    if (bytes > capacity_ - (tail - head)) {
        return Status{StatusCode::kResourceExhausted};  // 满：全有或全无
    }
    const uint64_t pos = tail & mask_;
    const uint64_t first = capacity_ - pos;  // 到环形末尾的连续空间
    if (bytes <= first) {
        std::memcpy(storage_ + pos, data, bytes);
    } else {
        std::memcpy(storage_ + pos, data, first);
        std::memcpy(storage_, static_cast<const uint8_t*>(data) + first, bytes - first);
    }
    tail_.store(tail + bytes, std::memory_order_release);  // 发布写入
    return Status::Ok();
}

Status SpscSampleRing::Read(void* out, uint64_t bytes) {
    if (!initialized_ || out == nullptr) {
        return Status{StatusCode::kInvalidArgument};
    }
    if (bytes == 0) {
        return Status::Ok();
    }
    const uint64_t head = head_.load(std::memory_order_relaxed);
    const uint64_t tail = tail_.load(std::memory_order_acquire);  // 对端发布的写位置
    if (bytes > tail - head) {
        return Status{StatusCode::kResourceExhausted};  // 空/不足：全有或全无
    }
    const uint64_t pos = head & mask_;
    const uint64_t first = capacity_ - pos;
    if (bytes <= first) {
        std::memcpy(out, storage_ + pos, bytes);
    } else {
        std::memcpy(out, storage_ + pos, first);
        std::memcpy(static_cast<uint8_t*>(out) + first, storage_, bytes - first);
    }
    head_.store(head + bytes, std::memory_order_release);  // 释放已读空间
    return Status::Ok();
}

uint64_t SpscSampleRing::ReadableBytes() const {
    return tail_.load(std::memory_order_relaxed) - head_.load(std::memory_order_relaxed);
}

uint64_t SpscSampleRing::WritableBytes() const {
    const uint64_t tail = tail_.load(std::memory_order_relaxed);
    const uint64_t head = head_.load(std::memory_order_relaxed);
    return capacity_ - (tail - head);
}

}  // namespace cq
