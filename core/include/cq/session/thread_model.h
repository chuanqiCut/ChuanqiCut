// ChuanqiCut — 线程角色体系（CORE-008）
//
// 规格来源：docs/specs/ARCH-001-技术方案总纲.md §6 线程模型
//
//   ┌─ Main Thread ────────── UI 渲染、手势；禁止任何阻塞调用 ─────────┐
//   ├─ Session Thread ─────── 命令执行、模型变更、状态通知（串行） ─────┤
//   ├─ Decode Pool ────────── N 路并发解码 ────────────────────────────┤
//   ├─ Render Thread ──────── GPU 命令编码与提交（单线程） ────────────┤
//   ├─ Encode Thread ──────── 编码器输入/输出，背压控制 ───────────────┤
//   ├─ Audio Thread ───────── 实时优先级，禁止加锁与分配 ──────────────┤
//   └─ Inference Pool ─────── AI 推理，可降级/可丢弃 ──────────────────┘
//
// 铁律 1「主线程零阻塞」要能被**运行时检查**，前提是线程的身份可知。
// 这里用 thread_local 角色标记 + 查询函数，使任何代码都能问自己一句
// 「我现在是不是在主线程」—— 这是把铁律从文档变成可执行约定的最小手段。
//
// 设计约束：
//   - 零平台类型（红线 #2）：只用标准库 thread_local，不涉及 pthread / NSThread / 任何平台 API。
//   - 禁用异常（红线）：错误一律 Status，本文件不抛不捕。
//   - **不用编译期宏推断角色**（红线 #3 的同源纪律）：角色是运行时事实，
//     `#if __APPLE__` 之类猜不出当前跑在哪根线程上。

#ifndef CQ_SESSION_THREAD_MODEL_H_
#define CQ_SESSION_THREAD_MODEL_H_

#include <cstdint>

namespace cq {

// ARCH-001 §6 定义的七类线程角色。
// kUnknown 是默认值：尚未被显式标记的线程一律 Unknown，
// **不会**被误判成 Main 或 Audio（宁可"不知道"，不可猜错）。
enum class ThreadRole : int32_t {
    kUnknown = 0,
    kMain,       // UI 渲染、手势；禁止任何阻塞调用（>16ms 的操作一律不得在此执行）
    kSession,    // 命令执行、模型变更、状态通知（串行）
    kDecode,     // N 路并发解码（N = min(轨道数, 4)）
    kRender,     // GPU 命令编码与提交（单线程）
    kEncode,     // 编码器输入/输出，背压控制
    kAudio,      // 实时优先级，禁止加锁与分配
    kInference,  // AI 推理，可降级/可丢弃
};

// ---- 当前线程角色：标记与查询 --------------------------------------------

// 给**当前线程**打上角色标记。通常在线程入口处调用一次。
//   约定：宿主 App 启动时应在主线程调用 SetCurrentThreadRole(ThreadRole::kMain)，
//         否则 IsMainThread() 永远为 false —— SDK 无从得知哪根是 UI 线程。
void SetCurrentThreadRole(ThreadRole role);

// 当前线程的角色（未标记则为 kUnknown）。
ThreadRole CurrentThreadRole();

// 是否在被标记为主线程的线程上。
bool IsMainThread();

// 是否在被标记为音频线程的线程上（禁锁、禁分配的执行环境）。
bool IsAudioThread();

// 角色名（仅用于日志 / 调试文本，禁止进入计算与比较路径）。
const char* ThreadRoleName(ThreadRole role);

}  // namespace cq

#endif  // CQ_SESSION_THREAD_MODEL_H_
