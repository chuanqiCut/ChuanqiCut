// ChuanqiCut — 内存池 / Arena / 纹理预算记账（CORE-004）
//
// 设计目标：
//   1. 帧级数据处理高频分配/释放，需要池化：提供 LinearArena（bump 分配器，
//      帧末统一 Reset）与 FixedPool（定长块空闲链表池）。
//   2. 纹理预算记账是本项目的重点：GPU 纹理是移动端最稀缺资源。必须能查询
//      「当前已用 / 上限」，并在超预算时给出明确的 Status（kResourceExhausted=5000）。
//   3. 记账线程安全：本期用标准库 <atomic> 做计数（注册/注销低频路径用 <mutex>
//      保护 id->bytes 映射）。**不自己造锁，也不实现 CORE-005 的并发原语**。
//   4. **不定义任何 GFX 接口**（那是 GFX-001 的事）。本模块只提供「预算账本」，
//      纹理对象本身由 GFX 层将来持有并来登记（我们以 int64 id 簿记大小）。
//
// 红线（AGENTS.root.md）：
//   * 头文件零平台类型：本文件只使用 C/C++ 基础类型、std::atomic、std::mutex、
//     std::unordered_map，绝不出现 VkImage / MTLTexture / CVPixelBuffer 等 GFX 类型。
//
// 线程模型约定（见 ARCH-001 §6）：
//   * MemoryBudget / TextureBudget 的计数（Used/Limit/Remaining）是线程安全的，
//     可多生产者并发 TryAllocate/Register、并发无锁查询。
//   * LinearArena / FixedPool 是**单 owner**（每帧/每线程独占）的分配原语，不做
//     内部同步；跨线程共享它们的分配结果时应由调用方（CORE-005 的队列/锁）同步。
//     真正需要跨线程「查询当前分配量」的是上面两个账本，它们已线程安全。

#ifndef CQ_BASE_ALLOC_H_
#define CQ_BASE_ALLOC_H_

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <unordered_map>

#include "cq/base/status.h"

namespace cq {

// ---------------------------------------------------------------------------
// MemoryBudget：通用字节预算账本（线程安全）
// ---------------------------------------------------------------------------
// 追踪「当前已用字节 / 上限」。超过上限的分配请求返回 kResourceExhausted(5000)，
// 且不修改计数（调用方应自行降级/拒绝）。用于帧缓冲、临时媒体数据等堆外内存额度。
class MemoryBudget {
public:
    explicit MemoryBudget(int64_t limit_bytes);

    // 尝试记一笔分配。成功返回 Ok 并累加；会使 used 超过 limit 时返回
    // kResourceExhausted 且不累加（无副作用）。
    Status TryAllocate(int64_t bytes);

    // 释放（记一笔归还）。若归还量超过当前已用，夹紧到 0（防御重复释放）。
    void Release(int64_t bytes);

    int64_t Used() const;
    int64_t Limit() const;
    int64_t Remaining() const;  // limit - used，下限夹紧到 0
    void SetLimit(int64_t bytes);

private:
    std::atomic<int64_t> used_;
    std::atomic<int64_t> limit_;
};

// ---------------------------------------------------------------------------
// LinearArena：线性 bump 分配器（单 owner）
// ---------------------------------------------------------------------------
// 帧级处理：一帧内高频分配若干小对象，帧末统一 Reset() 一次性释放。
// 不做内部同步（单 owner 假设）；Used() 用原子仅用于无锁查询当前用量。
class LinearArena {
public:
    explicit LinearArena(size_t capacity_bytes);
    ~LinearArena();

    // 返回对齐后的指针；空间不足返回 nullptr（不抛、不增长）。
    // align 必须是 2 的幂，默认按 std::max_align_t 对齐。
    void* Allocate(size_t bytes, size_t align = alignof(std::max_align_t));

    // 一次性释放全部（仅单 owner 调用，不要在并发 Allocate 时进行）。
    void Reset();

    size_t Used() const;       // 自上次 Reset 以来已分配字节（含对齐填充）
    size_t Capacity() const;
    size_t Available() const;

private:
    unsigned char* buffer_ = nullptr;
    std::atomic<size_t> offset_;  // 原子仅用于无锁查询 Used()
    size_t capacity_ = 0;
};

// ---------------------------------------------------------------------------
// FixedPool：定长块池（单 owner）
// ---------------------------------------------------------------------------
// 帧缓冲等定长对象的池化：预分配 count 个 block_size 的槽，分配/回收走空闲链表。
// 同样单 owner（与 Arena 同生命周期），线程安全由调用方保证。LiveCount() 仅用于
// 诊断查询。
class FixedPool {
public:
    FixedPool(size_t block_size, size_t count);
    ~FixedPool();

    // 取一个块；池空返回 nullptr。
    void* Acquire();
    // 归还先前 Acquire 的块（必须来自本池）。非本池指针被忽略（防御）。
    void Release(void* p);

    size_t BlockSize() const;   // 单个槽字节数
    size_t Capacity() const;    // 槽总数
    size_t LiveCount() const;   // 当前已借出
    size_t FreeCount() const;   // 当前空闲

private:
    struct Node {
        Node* next;
    };

    unsigned char* mem_ = nullptr;
    Node* free_ = nullptr;
    size_t block_size_ = 0;
    size_t count_ = 0;
    size_t live_ = 0;
};

// ---------------------------------------------------------------------------
// TextureBudget：GPU 纹理预算账本（线程安全，重点）
// ---------------------------------------------------------------------------
// 移动端最稀缺资源。追踪「已用字节 / 已用张数」对照「上限字节 / 上限张数」。
// GFX 层将来只来登记（Register/Unregister），本模块**不定义任何 GFX 类型**，
// 纹理对象由 GFX 持有；我们仅以 int64 id 簿记大小。
//
// 计数（UsedBytes/UsedCount/Limit*/RemainingBytes）走 std::atomic，无锁可并发查询；
// id->bytes 映射仅在 Register/Unregister（低频）时由 std::mutex 保护。
class TextureBudget {
public:
    TextureBudget(int64_t limit_bytes, int32_t limit_count);

    // 登记一张纹理。会使任一维度超预算时返回 kResourceExhausted 且不登记。
    // id 必须 > 0 且在存活集中唯一；重复 id 返回 kInvalidArgument。
    Status Register(int64_t id, int64_t bytes);

    // 注销（释放）。id 必须当前存活；未知/重复注销返回 kInvalidArgument。
    Status Unregister(int64_t id);

    int64_t UsedBytes() const;
    int64_t LimitBytes() const;
    int32_t UsedCount() const;
    int32_t LimitCount() const;
    int64_t RemainingBytes() const;  // limit_bytes - used_bytes，下限 0
    int32_t RemainingCount() const;  // limit_count - used_count，下限 0
    void SetLimits(int64_t limit_bytes, int32_t limit_count);

private:
    std::atomic<int64_t> used_bytes_;
    std::atomic<int32_t> used_count_;
    std::atomic<int64_t> limit_bytes_;
    std::atomic<int32_t> limit_count_;
    mutable std::mutex map_mutex_;  // 仅保护 id->bytes 映射（注册/注销低频）
    std::unordered_map<int64_t, int64_t> live_;
};

}  // namespace cq

#endif  // CQ_BASE_ALLOC_H_
