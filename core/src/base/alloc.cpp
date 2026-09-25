// ChuanqiCut — 内存池 / Arena / 纹理预算记账 实现（CORE-004）
//
// 设计要点见同目录头文件 alloc.h 的注释。要点重申：
//   * MemoryBudget：字节账本，TryAllocate 用 compare_exchange 无锁累加，超预算
//     返回 kResourceExhausted(5000)。
//   * LinearArena：bump 分配，原子 offset 仅用于无锁查询 Used()。
//   * FixedPool：定长块空闲链表，单 owner。
//   * TextureBudget：GPU 纹理账本（重点），计数 atomic 无锁，id 映射低频加 mutex。
//   * 不定义任何 GFX 类型，纹理对象由 GFX 层持有。

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>

#include "cq/base/alloc.h"

namespace cq {

// ===========================================================================
// MemoryBudget
// ===========================================================================
MemoryBudget::MemoryBudget(int64_t limit_bytes)
    : used_(0), limit_(limit_bytes < 0 ? 0 : limit_bytes) {}

Status MemoryBudget::TryAllocate(int64_t bytes) {
    if (bytes < 0) return Status(StatusCode::kInvalidArgument);
    int64_t cur = used_.load(std::memory_order_relaxed);
    int64_t limit = limit_.load(std::memory_order_relaxed);
    for (;;) {
        int64_t next = cur + bytes;
        // 超预算：不修改计数，返回资源耗尽。
        if (next > limit) {
            return Status(StatusCode::kResourceExhausted);
        }
        if (used_.compare_exchange_weak(cur, next, std::memory_order_relaxed,
                                         std::memory_order_relaxed)) {
            return Status::Ok();
        }
        // cur 已被更新为最新值，重试。
    }
}

void MemoryBudget::Release(int64_t bytes) {
    if (bytes < 0) return;
    int64_t prev = used_.fetch_sub(bytes, std::memory_order_relaxed);
    if (prev < bytes) {
        // 防御：归还量超过已用（重复释放/计数错），夹紧到 0。
        used_.store(0, std::memory_order_relaxed);
    }
}

int64_t MemoryBudget::Used() const { return used_.load(std::memory_order_relaxed); }
int64_t MemoryBudget::Limit() const { return limit_.load(std::memory_order_relaxed); }

int64_t MemoryBudget::Remaining() const {
    int64_t rem = limit_.load(std::memory_order_relaxed) - used_.load(std::memory_order_relaxed);
    return rem < 0 ? 0 : rem;
}

void MemoryBudget::SetLimit(int64_t bytes) {
    limit_.store(bytes < 0 ? 0 : bytes, std::memory_order_relaxed);
}

// ===========================================================================
// LinearArena
// ===========================================================================
LinearArena::LinearArena(size_t capacity_bytes) : capacity_(capacity_bytes) {
    if (capacity_ > 0) {
        buffer_ = new (std::nothrow) unsigned char[capacity_];
        if (buffer_ == nullptr) {
            capacity_ = 0;  // 分配失败：空 arena，所有 Allocate 返回 nullptr。
        }
    }
    offset_.store(0, std::memory_order_relaxed);
}

LinearArena::~LinearArena() { delete[] buffer_; }

void* LinearArena::Allocate(size_t bytes, size_t align) {
    if (buffer_ == nullptr || bytes == 0 || align == 0) return nullptr;
    // align 必须非 0 且为 2 的幂；这里仅按传入值处理（调用方保证）。
    size_t off = offset_.load(std::memory_order_relaxed);
    for (;;) {
        uintptr_t base = reinterpret_cast<uintptr_t>(buffer_) + off;
        uintptr_t aligned = (base + (align - 1)) & ~(static_cast<uintptr_t>(align - 1));
        size_t pad = static_cast<size_t>(aligned - base);
        size_t need = pad + bytes;
        if (off + need > capacity_) return nullptr;  // 空间不足
        size_t desired = off + need;
        if (offset_.compare_exchange_weak(off, desired, std::memory_order_relaxed,
                                          std::memory_order_relaxed)) {
            return reinterpret_cast<void*>(aligned);
        }
        // off 已更新为最新值，重试。
    }
}

void LinearArena::Reset() { offset_.store(0, std::memory_order_relaxed); }

size_t LinearArena::Used() const { return offset_.load(std::memory_order_relaxed); }
size_t LinearArena::Capacity() const { return capacity_; }
size_t LinearArena::Available() const {
    size_t used = offset_.load(std::memory_order_relaxed);
    return used > capacity_ ? 0 : capacity_ - used;
}

// ===========================================================================
// FixedPool
// ===========================================================================
FixedPool::FixedPool(size_t block_size, size_t count)
    : block_size_(block_size < sizeof(Node) ? sizeof(Node) : block_size),
      count_(count),
      live_(0) {
    if (count_ > 0) {
        mem_ = new (std::nothrow) unsigned char[block_size_ * count_];
        if (mem_ != nullptr) {
            free_ = nullptr;
            for (size_t i = 0; i < count_; ++i) {
                Node* n = reinterpret_cast<Node*>(mem_ + i * block_size_);
                n->next = free_;
                free_ = n;
            }
        } else {
            count_ = 0;  // 分配失败：空池。
        }
    }
}

FixedPool::~FixedPool() { delete[] mem_; }

void* FixedPool::Acquire() {
    if (free_ == nullptr) return nullptr;
    Node* n = free_;
    free_ = n->next;
    ++live_;
    return n;
}

void FixedPool::Release(void* p) {
    if (p == nullptr) return;
    // 防御：仅接受来自本池的指针。
    unsigned char* cp = static_cast<unsigned char*>(p);
    if (cp < mem_ || cp >= mem_ + block_size_ * count_) return;
    Node* n = static_cast<Node*>(p);
    n->next = free_;
    free_ = n;
    if (live_ > 0) --live_;
}

size_t FixedPool::BlockSize() const { return block_size_; }
size_t FixedPool::Capacity() const { return count_; }
size_t FixedPool::LiveCount() const { return live_; }
size_t FixedPool::FreeCount() const {
    return count_ > live_ ? count_ - live_ : 0;
}

// ===========================================================================
// TextureBudget
// ===========================================================================
TextureBudget::TextureBudget(int64_t limit_bytes, int32_t limit_count)
    : used_bytes_(0),
      used_count_(0),
      limit_bytes_(limit_bytes < 0 ? 0 : limit_bytes),
      limit_count_(limit_count < 0 ? 0 : limit_count) {}

Status TextureBudget::Register(int64_t id, int64_t bytes) {
    if (id <= 0 || bytes < 0) return Status(StatusCode::kInvalidArgument);

    std::lock_guard<std::mutex> g(map_mutex_);
    if (live_.find(id) != live_.end()) {
        return Status(StatusCode::kInvalidArgument);  // 重复 id
    }
    int64_t cur_bytes = used_bytes_.load(std::memory_order_relaxed);
    int32_t cur_count = used_count_.load(std::memory_order_relaxed);
    int64_t new_bytes = cur_bytes + bytes;
    int32_t new_count = static_cast<int32_t>(cur_count + 1);
    int64_t lim_bytes = limit_bytes_.load(std::memory_order_relaxed);
    int32_t lim_count = limit_count_.load(std::memory_order_relaxed);
    if (new_bytes > lim_bytes || new_count > lim_count) {
        return Status(StatusCode::kResourceExhausted);  // 超预算，不登记
    }
    used_bytes_.store(new_bytes, std::memory_order_relaxed);
    used_count_.store(new_count, std::memory_order_relaxed);
    live_[id] = bytes;
    return Status::Ok();
}

Status TextureBudget::Unregister(int64_t id) {
    if (id <= 0) return Status(StatusCode::kInvalidArgument);
    std::lock_guard<std::mutex> g(map_mutex_);
    auto it = live_.find(id);
    if (it == live_.end()) {
        return Status(StatusCode::kInvalidArgument);  // 未知 id
    }
    int64_t sz = it->second;
    int64_t prev = used_bytes_.fetch_sub(sz, std::memory_order_relaxed);
    if (prev < sz) used_bytes_.store(0, std::memory_order_relaxed);
    int32_t prev_c = used_count_.fetch_sub(1, std::memory_order_relaxed);
    if (prev_c <= 0) used_count_.store(0, std::memory_order_relaxed);
    live_.erase(it);
    return Status::Ok();
}

int64_t TextureBudget::UsedBytes() const {
    return used_bytes_.load(std::memory_order_relaxed);
}
int64_t TextureBudget::LimitBytes() const {
    return limit_bytes_.load(std::memory_order_relaxed);
}
int32_t TextureBudget::UsedCount() const {
    return used_count_.load(std::memory_order_relaxed);
}
int32_t TextureBudget::LimitCount() const {
    return limit_count_.load(std::memory_order_relaxed);
}
int64_t TextureBudget::RemainingBytes() const {
    int64_t rem = limit_bytes_.load(std::memory_order_relaxed) -
                  used_bytes_.load(std::memory_order_relaxed);
    return rem < 0 ? 0 : rem;
}
int32_t TextureBudget::RemainingCount() const {
    int32_t rem = static_cast<int32_t>(limit_count_.load(std::memory_order_relaxed) -
                                       used_count_.load(std::memory_order_relaxed));
    return rem < 0 ? 0 : rem;
}
void TextureBudget::SetLimits(int64_t limit_bytes, int32_t limit_count) {
    limit_bytes_.store(limit_bytes < 0 ? 0 : limit_bytes, std::memory_order_relaxed);
    limit_count_.store(limit_count < 0 ? 0 : limit_count, std::memory_order_relaxed);
}

}  // namespace cq
