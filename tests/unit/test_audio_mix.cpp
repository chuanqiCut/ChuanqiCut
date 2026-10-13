// ChuanqiCut — 多轨混音原语单测（AUDIO-004）
//
// 验收对应 TASK-AUDIO-004 acceptance：
//   [A] 增益语义：1 直通 / 0 静音 / 衰减 / 放大 / 负增益反相。
//   [B] 多轨累加：三轨求和正确；累加顺序不敏感（浮点非结合，容差断言）。
//   [C] 无溢出：超幅截 ±1；NaN / ±Inf 按 0；界内值不动（输出恒在 [-1,1]）。
//   [D] 分码纪律：nullptr / 零值 / 非有限 gain / acc 侧越界 → kInvalidArgument，
//       且拒绝时**一个该厂商都不写**（哨兵缓冲前后比对）。
//   [E] 部分区间：src/dst 帧偏移正确，区间外样本不受影响。
//   [F] 音频线程零分配实测：kAudio 标记线程全路径 operator new 增量 = 0
//       （先热身排除惰性初始化；手法同 core_audio_graph）。
//
// 附带结构性断言（本卡"消灭并行实现"的验收）：预览混音器不得再有内联求和/削波
// 循环 —— 该断言是 grep 级人工核验（chq_preview_mixer.cpp 只允许出现对
// MixAccumulateRange / MixClipRange 的调用），不在此用源码自省（单测不做文件 IO）。

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <thread>

#include "cq/audio/chq_mix.h"
#include "cq/session/chq_thread_model.h"

// ---- 全局分配计数：operator new/delete 重载在链接期对整个测试进程生效
//      （含 cq_core 静态库内的分配），本 TU 持有 main，替换保证 ODR 唯一。----

namespace {

std::atomic<uint64_t> g_new_count{0};

const float kNaN = std::numeric_limits<float>::quiet_NaN();
const float kPosInf = std::numeric_limits<float>::infinity();

}  // namespace

void* operator new(std::size_t count) {
    void* p = std::malloc(count);
    if (p == nullptr) throw std::bad_alloc{};
    g_new_count.fetch_add(1, std::memory_order_relaxed);
    return p;
}
void* operator new[](std::size_t count) {
    void* p = std::malloc(count);
    if (p == nullptr) throw std::bad_alloc{};
    g_new_count.fetch_add(1, std::memory_order_relaxed);
    return p;
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (!cond) {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
    std::fflush(stdout);
}

// 浮点比较容差。混音是线性运算，参考值可由精确算术得出，
// 容差取 1e-6（float32 少数累加项的保守上界）。
bool Near(float a, float b) { return std::fabs(a - b) <= 1e-6f; }

const uint32_t kCh = 2;    // 测试统一双声道交错
const size_t kFrames = 4;  // 测试统一 4 帧一块

// ---------------------------------------------------------------------------
// [A] 增益语义
// ---------------------------------------------------------------------------
void TestGainSemantics() {
    std::printf("[A] 增益语义\n");

    // gain = 1：直通求和。
    {
        float acc[8] = {0.1f, -0.1f, 0.2f, -0.2f, 0.3f, -0.3f, 0.4f, -0.4f};
        const float src[8] = {0.5f, -0.5f, 0.5f, -0.5f, 0.5f, -0.5f, 0.5f, -0.5f};
        Check(cq::MixAccumulateRange(acc, kFrames, kCh, src, 0, kFrames, 0, 1.0f).IsOk(),
              "gain=1 应成功");
        // acc 偶数位 0.1/0.2/0.3/0.4、奇数位其负值，加 src 的 ±0.5。
        bool ok = true;
        for (size_t i = 0; i < 8; ++i) {
            const float base = 0.1f * static_cast<float>(i / 2 + 1);
            const float expect = (i % 2 == 0) ? (base + 0.5f) : -(base + 0.5f);
            ok = ok && Near(acc[i], expect);
        }
        Check(ok, "gain=1 直通求和正确");
    }
    // gain = 0：静音（acc 一该厂商不动）。
    {
        const float before[8] = {0.1f, -0.1f, 0.2f, -0.2f, 0.3f, -0.3f, 0.4f, -0.4f};
        float acc[8];
        std::memcpy(acc, before, sizeof(acc));
        const float src[8] = {0.5f, -0.5f, 0.5f, -0.5f, 0.5f, -0.5f, 0.5f, -0.5f};
        Check(cq::MixAccumulateRange(acc, kFrames, kCh, src, 0, kFrames, 0, 0.0f).IsOk(),
              "gain=0 应成功（合法静音）");
        Check(std::memcmp(acc, before, sizeof(acc)) == 0, "gain=0 时 acc 不变");
    }
    // gain = 0.5：衰减。
    {
        float acc[8] = {0};
        const float src[8] = {0.4f, -0.4f, 0.4f, -0.4f, 0.4f, -0.4f, 0.4f, -0.4f};
        Check(cq::MixAccumulateRange(acc, kFrames, kCh, src, 0, kFrames, 0, 0.5f).IsOk(),
              "gain=0.5 应成功");
        Check(Near(acc[0], 0.2f) && Near(acc[1], -0.2f), "gain=0.5 衰减正确");
    }
    // gain = 2：放大（不削峰，削峰是 MixClipRange 的事）。
    {
        float acc[8] = {0};
        const float src[8] = {0.3f, -0.3f, 0.3f, -0.3f, 0.3f, -0.3f, 0.3f, -0.3f};
        Check(cq::MixAccumulateRange(acc, kFrames, kCh, src, 0, kFrames, 0, 2.0f).IsOk(),
              "gain=2 应成功");
        Check(Near(acc[0], 0.6f) && Near(acc[1], -0.6f), "gain=2 放大正确");
    }
    // gain < 0：反相（合法特性，不是错误）。
    {
        float acc[8] = {0};
        const float src[8] = {0.3f, -0.3f, 0.3f, -0.3f, 0.3f, -0.3f, 0.3f, -0.3f};
        Check(cq::MixAccumulateRange(acc, kFrames, kCh, src, 0, kFrames, 0, -1.0f).IsOk(),
              "负增益应成功（反相是合法特性）");
        Check(Near(acc[0], -0.3f) && Near(acc[1], 0.3f), "负增益反相正确");
    }
}

// ---------------------------------------------------------------------------
// [B] 多轨累加：三轨求和 + 顺序不敏感
// ---------------------------------------------------------------------------
void TestMultiTrackSum() {
    std::printf("[B] 多轨累加\n");
    const float t1[8] = {0.1f, 0.1f, 0.1f, 0.1f, 0.1f, 0.1f, 0.1f, 0.1f};
    const float t2[8] = {0.2f, -0.2f, 0.2f, -0.2f, 0.2f, -0.2f, 0.2f, -0.2f};
    const float t3[8] = {0.3f, 0.3f, -0.3f, -0.3f, 0.3f, 0.3f, -0.3f, -0.3f};

    float a[8] = {0};
    float b[8] = {0};
    Check(cq::MixAccumulateRange(a, kFrames, kCh, t1, 0, kFrames, 0, 1.0f).IsOk() &&
              cq::MixAccumulateRange(a, kFrames, kCh, t2, 0, kFrames, 0, 1.0f).IsOk() &&
              cq::MixAccumulateRange(a, kFrames, kCh, t3, 0, kFrames, 0, 1.0f).IsOk(),
          "三轨依次累加应成功");
    Check(cq::MixAccumulateRange(b, kFrames, kCh, t3, 0, kFrames, 0, 1.0f).IsOk() &&
              cq::MixAccumulateRange(b, kFrames, kCh, t1, 0, kFrames, 0, 1.0f).IsOk() &&
              cq::MixAccumulateRange(b, kFrames, kCh, t2, 0, kFrames, 0, 1.0f).IsOk(),
          "逆序累加应成功");
    bool same = true;
    for (size_t i = 0; i < 8; ++i) same = same && Near(a[i], b[i]);
    Check(same, "累加顺序不敏感（容差 1e-6）");
    Check(Near(a[0], 0.6f) && Near(a[1], 0.2f), "三轨求和值正确（第 0 帧）");
    Check(Near(a[2], 0.0f) && Near(a[3], -0.4f), "三轨求和值正确（第 1 帧）");

    // 混合增益求和：0.5*t1 + 1.0*t2。
    float c[8] = {0};
    Check(cq::MixAccumulateRange(c, kFrames, kCh, t1, 0, kFrames, 0, 0.5f).IsOk() &&
              cq::MixAccumulateRange(c, kFrames, kCh, t2, 0, kFrames, 0, 1.0f).IsOk(),
          "混合增益累加应成功");
    Check(Near(c[0], 0.25f) && Near(c[1], -0.15f), "混合增益求和值正确（0.05±0.2）");
}

// ---------------------------------------------------------------------------
// [C] 无溢出：削波 + 非有限值处置
// ---------------------------------------------------------------------------
void TestClipNoOverflow() {
    std::printf("[C] 无溢出（削波 + 非有限值）\n");

    // 累加溢出场景：三轨 0.9 求和 = 2.7 → 削到 ±1。
    {
        float acc[8] = {0};
        const float hot[8] = {0.9f, -0.9f, 0.9f, -0.9f, 0.9f, -0.9f, 0.9f, -0.9f};
        Check(cq::MixAccumulateRange(acc, kFrames, kCh, hot, 0, kFrames, 0, 1.0f).IsOk() &&
                  cq::MixAccumulateRange(acc, kFrames, kCh, hot, 0, kFrames, 0, 1.0f).IsOk() &&
                  cq::MixAccumulateRange(acc, kFrames, kCh, hot, 0, kFrames, 0, 1.0f).IsOk(),
              "三轨 0.9 累加应成功");
        Check(Near(acc[0], 2.7f), "削波前累加值为 2.7（未被提前截断）");
        Check(cq::MixClipRange(acc, kFrames, kCh).IsOk(), "削波应成功");
        bool clipped = true;
        for (size_t i = 0; i < 8; ++i) {
            clipped = clipped && Near(acc[i], (i % 2 == 0) ? 1.0f : -1.0f);
        }
        Check(clipped, "超幅样本截到 ±1");
    }
    // 非有限值按 0：NaN / +Inf / -Inf；界内与边界值不动。
    {
        float d[8] = {kNaN, kPosInf, -kPosInf, 0.5f, -0.5f, 1.0f, -1.0f, 2.0f};
        Check(cq::MixClipRange(d, kFrames, kCh).IsOk(), "含非有限值的削波应成功");
        Check(d[0] == 0.0f, "NaN 按 0 处置");
        Check(d[1] == 0.0f, "+Inf 按 0 处置");
        Check(d[2] == 0.0f, "-Inf 按 0 处置");
        Check(Near(d[3], 0.5f) && Near(d[4], -0.5f), "界内值不动");
        Check(Near(d[5], 1.0f) && Near(d[6], -1.0f), "边界值 ±1 不动");
        Check(Near(d[7], 1.0f), "2.0 截到 1.0");
    }
    // 输出恒在 [-1,1]（无溢出验收的全量扫描形式）。
    {
        float d[8] = {1e30f, -1e30f, kNaN, 0.0f, 0.25f, -0.25f, 3.0f, -3.0f};
        Check(cq::MixClipRange(d, kFrames, kCh).IsOk(), "极端值削波应成功");
        bool in_range = true;
        for (size_t i = 0; i < 8; ++i) in_range = in_range && d[i] >= -1.0f && d[i] <= 1.0f;
        Check(in_range, "输出恒在 [-1,1]（无 inf/NaN 穿透）");
    }
}

// ---------------------------------------------------------------------------
// [D] 分码纪律：非法参数 → kInvalidArgument，且不写任何内存
// ---------------------------------------------------------------------------
void TestValidationNoWrite() {
    std::printf("[D] 分码纪律（拒绝即不写内存）\n");
    const float src[8] = {0.5f, -0.5f, 0.5f, -0.5f, 0.5f, -0.5f, 0.5f, -0.5f};

    // 哨兵 acc：任何被拒的调用都不得改动它一个该厂商。
    const float kSentinel[8] = {0.11f, -0.11f, 0.22f, -0.22f, 0.33f, -0.33f, 0.44f, -0.44f};

    struct Case {
        const char* name;
        float* acc;
        size_t acc_frames;
        uint32_t channels;
        const float* s;
        size_t src_frame0;
        size_t frames;
        size_t dst_frame0;
        float gain;
    };
    float mutable_acc[8];
    std::memcpy(mutable_acc, kSentinel, sizeof(mutable_acc));

    const Case cases[] = {
        {"acc 为空", nullptr, kFrames, kCh, src, 0, kFrames, 0, 1.0f},
        {"src 为空", mutable_acc, kFrames, kCh, nullptr, 0, kFrames, 0, 1.0f},
        {"channels=0", mutable_acc, kFrames, 0u, src, 0, kFrames, 0, 1.0f},
        {"frames=0", mutable_acc, kFrames, kCh, src, 0, 0, 0, 1.0f},
        {"acc_frames=0", mutable_acc, 0, kCh, src, 0, kFrames, 0, 1.0f},
        {"gain=NaN", mutable_acc, kFrames, kCh, src, 0, kFrames, 0, kNaN},
        {"gain=+Inf", mutable_acc, kFrames, kCh, src, 0, kFrames, 0, kPosInf},
        {"dst 恰好一帧越界", mutable_acc, kFrames, kCh, src, 0, kFrames, 1, 1.0f},
        {"frames 超过 acc", mutable_acc, kFrames, kCh, src, 0, kFrames + 1, 0, 1.0f},
        {"dst_frame0 远超 acc", mutable_acc, kFrames, kCh, src, 0, 1, 1000, 1.0f},
    };
    for (const Case& c : cases) {
        const cq::ChqStatus st = cq::MixAccumulateRange(
            c.acc, c.acc_frames, c.channels, c.s, c.src_frame0, c.frames, c.dst_frame0, c.gain);
        Check(st.code == cq::ChqStatusCode::kInvalidArgument, c.name);
    }
    Check(std::memcmp(mutable_acc, kSentinel, sizeof(mutable_acc)) == 0,
          "全部被拒后 acc 一该厂商未动（全有或全无）");

    // 边界合法：dst_frame0 + frames == acc_frames 恰好放满。
    {
        float acc[8];
        std::memcpy(acc, kSentinel, sizeof(acc));
        Check(cq::MixAccumulateRange(acc, kFrames, kCh, src, 0, kFrames, 0, 1.0f).IsOk(),
              "恰好放满应成功");
        Check(Near(acc[0], 0.61f), "恰好放满时第 0 样本已累加");
    }

    // MixClipRange 的参数校验同样不写内存。
    {
        float d[8];
        std::memcpy(d, kSentinel, sizeof(d));
        Check(cq::MixClipRange(nullptr, kFrames, kCh).code == cq::ChqStatusCode::kInvalidArgument,
              "clip: data 为空应拒绝");
        Check(cq::MixClipRange(d, kFrames, 0u).code == cq::ChqStatusCode::kInvalidArgument,
              "clip: channels=0 应拒绝");
        Check(cq::MixClipRange(d, 0, kCh).code == cq::ChqStatusCode::kInvalidArgument,
              "clip: frames=0 应拒绝");
        Check(std::memcmp(d, kSentinel, sizeof(d)) == 0, "clip 被拒后一该厂商未动");
    }
}

// ---------------------------------------------------------------------------
// [E] 部分区间：帧偏移正确，区间外样本不受影响
// ---------------------------------------------------------------------------
void TestPartialRanges() {
    std::printf("[E] 部分区间（帧偏移）\n");
    // acc 4 帧；src 4 帧。只把 src 第 [1,3) 帧累加进 acc 第 [2,4) 帧。
    float acc[8] = {0};
    const float src[8] = {0.1f, 0.1f, 0.2f, 0.2f, 0.3f, 0.3f, 0.4f, 0.4f};
    Check(cq::MixAccumulateRange(acc, kFrames, kCh, src, 1, 2, 2, 1.0f).IsOk(),
          "部分区间累加应成功");
    Check(acc[0] == 0.0f && acc[1] == 0.0f, "acc 前 2 样本不受影响（dst 起点前）");
    Check(acc[2] == 0.0f && acc[3] == 0.0f, "acc 第 1 帧不受影响（dst 起点前）");
    Check(Near(acc[4], 0.2f) && Near(acc[5], 0.2f), "acc 第 2 帧 = src 第 1 帧");
    Check(Near(acc[6], 0.3f) && Near(acc[7], 0.3f), "acc 第 3 帧 = src 第 2 帧");

    // 单帧累加（frames=1）也应正确 —— 预览路径的块内片段即此形态。
    {
        float one[8] = {0};
        Check(cq::MixAccumulateRange(one, kFrames, kCh, src, 3, 1, 0, 0.5f).IsOk(),
              "单帧累加应成功");
        Check(Near(one[0], 0.2f) && Near(one[1], 0.2f), "单帧值 = 0.5 * src[3]");
        Check(one[2] == 0.0f && one[7] == 0.0f, "单帧累加只写一帧");
    }
}

// ---------------------------------------------------------------------------
// [F] 音频线程零分配实测
// ---------------------------------------------------------------------------
void TestZeroAllocOnAudioThread() {
    std::printf("[F] 音频线程零分配实测（kAudio 标记线程全路径）\n");
    // 装配（允许分配）在主线程完成。
    float acc[8] = {0};
    const float src[8] = {0.1f, -0.1f, 0.2f, -0.2f, 0.3f, -0.3f, 0.4f, -0.4f};

    std::atomic<int64_t> alloc_delta{-1};
    std::atomic<bool> is_audio{false};

    std::thread audio_worker([&]() {
        cq::SetCurrentThreadRole(cq::ChqThreadRole::kAudio);
        is_audio.store(cq::IsAudioThread());

        // 热身一轮：排除首次路径的惰性初始化（若真有分配也会在此暴露计数，
        // 但不计入测量窗口）。
        for (int w = 0; w < 8; ++w) {
            (void)cq::MixAccumulateRange(acc, kFrames, kCh, src, 0, kFrames, 0, 1.0f);
            (void)cq::MixClipRange(acc, kFrames, kCh);
        }

        const uint64_t before = g_new_count.load(std::memory_order_seq_cst);
        for (int i = 0; i < 1024; ++i) {
            (void)cq::MixAccumulateRange(acc, kFrames, kCh, src, 0, kFrames, 0, 0.5f);
            (void)cq::MixClipRange(acc, kFrames, kCh);
        }
        const uint64_t after = g_new_count.load(std::memory_order_seq_cst);
        alloc_delta.store(static_cast<int64_t>(after) - static_cast<int64_t>(before),
                          std::memory_order_release);
    });
    audio_worker.join();

    Check(is_audio.load(), "kAudio 标记 + IsAudioThread 闭环");
    Check(alloc_delta.load() == 0, "音频线程混音全路径 operator new 增量 = 0");
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::thread watchdog([]() {
        std::this_thread::sleep_for(std::chrono::seconds(30));
        std::fprintf(stderr, "FATAL: core_audio_mix 单测超过 30s 未结束，判定挂死\n");
        std::abort();
    });
    watchdog.detach();

    std::printf("== ChuanqiCut core_audio_mix 单测 ==\n");
    TestGainSemantics();
    TestMultiTrackSum();
    TestClipNoOverflow();
    TestValidationNoWrite();
    TestPartialRanges();
    TestZeroAllocOnAudioThread();

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
