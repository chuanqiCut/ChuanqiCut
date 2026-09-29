// ChuanqiCut — 能力查询内核侧实现（CORE-007）
//
// 契约来源：docs/specs/PAL-接口契约.md §4 Capabilities
// 接口在 CORE-006 冻结于 core/include/cq/pal/capabilities.h，本文件补上**实现**。
//
// 为什么需要单独一个文件：CORE-006 只冻结了头文件，`SetCapabilitiesBackend` /
// `QueryCapability` 一直只有声明、没有定义。全仓库唯一引用是
// tests/unit/pal_headers_compile.cpp 里的 static_assert —— 那是编译期检查、不链接，
// 所以 CTest 一直全绿也看不出「接口其实是断的」。这与 CORE-006 当时的教训同型
// （见 HANDOFF-002 §8）：**编译通过 ≠ 接口可用**。

#include "cq/pal/capabilities.h"

#include <atomic>
#include <cstdint>

namespace cq {
namespace {

// 已注入的能力后端。
//
// 契约：注入方不接管所有权，后端生命周期须长于查询调用。
//
// 用 atomic 而非裸指针：能力查询可能来自任意线程（预览 / 导出 / 解码各线程），
// 而注入通常只在启动时发生一次。atomic 保证读写不撕裂，且查询路径**无锁**——
// 红线 #8 要求音频线程无锁、无分配，这里不引入任何锁或分配。
std::atomic<ICapabilities*> g_backend{nullptr};

}  // namespace

Status SetCapabilitiesBackend(ICapabilities* backend) {
    // 允许注入，也允许传 nullptr 清除（清除后一律返回 kNo）。
    g_backend.store(backend, std::memory_order_release);
    return Status::Ok();
}

CapabilityValue QueryCapability(Capability cap) {
    ICapabilities* backend = g_backend.load(std::memory_order_acquire);
    if (backend == nullptr) {
        // 未注入后端时一律 kNo。
        //
        // 这是**安全默认**，不是"查不到就当作没有"的偷懒：上层拿到 kNo 会走
        // 降级路径；若谎报 kYes，上层会去调用根本不存在的能力并崩溃。
        // 宁可降级不可用，不可谎报可用。
        return CapabilityValue::kNo;
    }
    return backend->Query(cap);
}

}  // namespace cq
