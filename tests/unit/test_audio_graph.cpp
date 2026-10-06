// ChuanqiCut — 音频图骨架 单测（AUDIO-001）
//
// 验收对应 TASK-AUDIO-001：
//   1. DAG 校验：成环 / 断链 / 自环 / 重复边 / 多源汇入 / 越界边 → kInvalidArgument。
//   2. 拓扑正确性：算术可验证的节点链（(x+1)*2+0.5），顺序错则结果必错。
//   3. pts 穿透：RationalTime 原样通过节点（节点不改块元数据）。
//   4. OnPrepare 失败传播：任一节点拒绝装配 → Prepare 返回其 Status，图为空。
//   5. 「音频线程零分配」实测：kAudio 标记线程上跑 Acquire→Ring→Process→Release
//      全路径，全局 operator new 计数增量必须为 0（先热身排除惰性初始化）。
//
// 计数原理：本 TU 重载全局 operator new/delete（测试二进制独占进程，替换全局生效，
// 连同 cq_core 静态库内的隐藏分配一起抓）。测量窗口内不得有 printf 等副作用。

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <thread>

#include "cq/audio/audio_graph.h"
#include "cq/audio/pcm_pool.h"
#include "cq/audio/spsc_ring.h"
#include "cq/session/thread_model.h"

// ---- 全局分配计数：operator new/delete 重载在链接期对整个测试进程生效
//      （含 cq_core 静态库内的分配），本 TU 持有 main，替换保证 ODR 唯一。----

namespace {

std::atomic<uint64_t> g_new_count{0};

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

cq::AudioGraphSpec TestSpec() {
    cq::AudioGraphSpec spec;
    spec.format = cq::SampleFormat::kFloat32;
    spec.channels = 2;
    spec.sample_rate = 48000;
    spec.frames_per_block = 512;
    return spec;
}

// 算术节点：原位 y = y*mul + add。结果与节点顺序一一对应，用于验证拓扑。
class ArithNode : public cq::IAudioNode {
public:
    ArithNode(float mul, float add) : mul_(mul), add_(add) {}
    cq::Status OnPrepare(const cq::AudioGraphSpec& spec) override {
        if (spec.format != cq::SampleFormat::kFloat32 || spec.channels == 0) {
            return cq::Status{cq::StatusCode::kInvalidArgument};
        }
        return cq::Status::Ok();
    }
    cq::Status Process(cq::AudioBuffer& block) override {
        auto* s = static_cast<float*>(block.data);
        const uint64_t n = block.frame_count * block.channels;
        for (uint64_t i = 0; i < n; ++i) {
            s[i] = s[i] * mul_ + add_;
        }
        return cq::Status::Ok();
    }

private:
    float mul_;
    float add_;
};

// OnPrepare 必败节点：验证失败传播。
class RefuseNode : public cq::IAudioNode {
public:
    cq::Status OnPrepare(const cq::AudioGraphSpec&) override {
        return cq::Status{cq::StatusCode::kResourceExhausted};
    }
    cq::Status Process(cq::AudioBuffer&) override { return cq::Status::Ok(); }
};

void TestPrepareValidation() {
    std::printf("[1] Prepare 拓扑校验\n");
    ArithNode a(1.0f, 0.0f), b(1.0f, 0.0f), c(1.0f, 0.0f);
    std::vector<cq::IAudioNode*> nodes = {&a, &b, &c};
    cq::AudioGraph graph;

    // 成环 0→1→0，节点 2 独立：边数 = n-1 但走不完 → 拒绝。
    std::vector<cq::AudioEdge> cycle = {{0, 1}, {1, 0}};
    Check(graph.Prepare(nodes, cycle, TestSpec()).code ==
              cq::StatusCode::kInvalidArgument,
          "成环拒绝");
    Check(graph.NodeCount() == 0, "失败后图为空");

    // 纯二环（无独立根）。
    std::vector<cq::IAudioNode*> two = {&a, &b};
    std::vector<cq::AudioEdge> two_cycle = {{0, 1}, {1, 0}};
    Check(graph.Prepare(two, two_cycle, TestSpec()).code ==
              cq::StatusCode::kInvalidArgument,
          "纯环拒绝");

    // 断链：两节点零边。
    Check(graph.Prepare(two, {}, TestSpec()).code == cq::StatusCode::kInvalidArgument,
          "断链拒绝");

    // 自环 / 越界 / 重复边 / 多源汇入。
    Check(graph.Prepare(two, {{0, 0}}, TestSpec()).code ==
              cq::StatusCode::kInvalidArgument,
          "自环拒绝");
    Check(graph.Prepare(two, {{0, 5}}, TestSpec()).code ==
              cq::StatusCode::kInvalidArgument,
          "越界边拒绝");
    Check(graph.Prepare(two, {{0, 1}, {0, 1}}, TestSpec()).code ==
              cq::StatusCode::kInvalidArgument,
          "重复边拒绝");
    std::vector<cq::AudioEdge> multi_in = {{0, 2}, {1, 2}};
    Check(graph.Prepare(nodes, multi_in, TestSpec()).code ==
              cq::StatusCode::kInvalidArgument,
          "多源汇入拒绝（混音是 AUDIO-004）");

    // 非法规格：未知格式。
    cq::AudioGraphSpec bad = TestSpec();
    bad.format = cq::SampleFormat::kUnknown;
    Check(graph.Prepare(nodes, {}, bad).code == cq::StatusCode::kInvalidArgument,
          "非法规格拒绝");
}

void TestTopoOrderAndPts() {
    std::printf("[2] 拓扑序正确性与 pts 穿透\n");
    // 链：Add(1) → Mul(2) → Add(0.5)。按给定的乱序节点数组装配，
    // 正确拓扑序结果 = (x+1)*2+0.5；若顺序错，结果必不同。
    ArithNode add1(1.0f, 1.0f);   // 实际是 y = y*1 + 1
    ArithNode mul2(2.0f, 0.0f);   // y = y*2
    ArithNode addhalf(1.0f, 0.5f);
    // 故意乱序传入：[mul2, addhalf, add1]，让拓扑排序有活干。
    std::vector<cq::IAudioNode*> nodes = {&mul2, &addhalf, &add1};
    std::vector<cq::AudioEdge> edges = {{2, 0}, {0, 1}};  // add1→mul2→addhalf

    cq::AudioGraph graph;
    const cq::Status ps = graph.Prepare(nodes, edges, TestSpec());
    Check(ps.IsOk(), "乱序装配成功");
    Check(graph.NodeCount() == 3, "节点数 = 3");

    cq::AudioBlockPool pool;
    Check(pool.Init(2, TestSpec()).IsOk(), "池 Init");
    cq::AudioBuffer block;
    Check(pool.Acquire(block).IsOk(), "取块");

    auto* s = static_cast<float*>(block.data);
    for (uint32_t i = 0; i < 512 * 2; ++i) s[i] = static_cast<float>(i);

    block.pts = cq::RationalTime{60000, 60000};  // 1.0s（项目 timescale）
    const cq::RationalTime pts_before = block.pts;
    Check(graph.Process(block).IsOk(), "Process 成功");

    bool math_ok = true;
    for (uint32_t i = 0; i < 4; ++i) {
        const float x = static_cast<float>(i);
        const float expected = (x + 1.0f) * 2.0f + 0.5f;
        if (s[i] != expected) math_ok = false;
    }
    Check(math_ok, "拓扑序数学验证：(x+1)*2+0.5");
    Check(block.pts.value == pts_before.value && block.pts.timescale == pts_before.timescale,
          "pts 穿透不变（节点不改元数据）");
    pool.Release(block);
}

void TestPrepareFailurePropagation() {
    std::printf("[3] OnPrepare 失败传播\n");
    ArithNode ok_node(1.0f, 0.0f);
    RefuseNode refuse;
    std::vector<cq::IAudioNode*> nodes = {&ok_node, &refuse};
    std::vector<cq::AudioEdge> edges = {{0, 1}};
    cq::AudioGraph graph;
    const cq::Status st = graph.Prepare(nodes, edges, TestSpec());
    Check(st.code == cq::StatusCode::kResourceExhausted, "失败节点 Status 原样返回");
    Check(graph.NodeCount() == 0, "失败后图为空（半装配不可用）");
}

void TestZeroAllocOnAudioThread() {
    std::printf("[4] 音频线程零分配实测（kAudio 标记线程全路径）\n");
    // 装配（允许分配）在主线程完成。
    ArithNode add1(1.0f, 1.0f), mul2(2.0f, 0.0f);
    std::vector<cq::IAudioNode*> nodes = {&add1, &mul2};
    std::vector<cq::AudioEdge> edges = {{0, 1}};
    cq::AudioGraph graph;
    Check(graph.Prepare(nodes, edges, TestSpec()).IsOk(), "图装配");

    cq::AudioBlockPool pool;
    Check(pool.Init(4, TestSpec()).IsOk(), "池 Init");
    cq::SpscSampleRing ring;
    Check(ring.Init(4096).IsOk(), "环 Init");

    std::atomic<int64_t> alloc_delta{-1};
    std::atomic<bool> is_audio{false};

    std::thread audio_worker([&]() {
        cq::SetCurrentThreadRole(cq::ThreadRole::kAudio);
        is_audio.store(cq::IsAudioThread());
        cq::AudioBuffer block;
        uint8_t scratch[8];

        // 热身一轮：排除首次路径的惰性初始化（若真有分配也会在此暴露计数，
        // 但不计入测量窗口）。
        for (int w = 0; w < 8; ++w) {
            if (!pool.Acquire(block).IsOk()) break;
            (void)graph.Process(block);
            (void)ring.Write(scratch, sizeof(scratch));
            (void)ring.Read(scratch, sizeof(scratch));
            pool.Release(block);
        }

        const uint64_t before = g_new_count.load(std::memory_order_seq_cst);
        for (int i = 0; i < 256; ++i) {
            if (!pool.Acquire(block).IsOk()) break;
            // 有理数推进 pts：60000/48000*512 = 640 tick/块，零浮点。
            block.pts = cq::RationalTime{static_cast<int64_t>(i) * 640, 60000};
            (void)graph.Process(block);
            (void)ring.Write(block.data, 8);
            (void)ring.Read(scratch, 8);
            pool.Release(block);
        }
        const uint64_t after = g_new_count.load(std::memory_order_seq_cst);
        alloc_delta.store(static_cast<int64_t>(after) - static_cast<int64_t>(before),
                          std::memory_order_release);
    });
    audio_worker.join();

    Check(is_audio.load(), "kAudio 标记 + IsAudioThread 闭环（CORE-008 集成）");
    Check(alloc_delta.load() == 0, "音频线程全路径 operator new 增量 = 0");
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::thread watchdog([]() {
        std::this_thread::sleep_for(std::chrono::seconds(30));
        std::fprintf(stderr, "FATAL: core_audio_graph 单测超过 30s 未结束，判定挂死\n");
        std::abort();
    });
    watchdog.detach();

    std::printf("== ChuanqiCut core_audio_graph 单测 ==\n");
    TestPrepareValidation();
    TestTopoOrderAndPts();
    TestPrepareFailurePropagation();
    TestZeroAllocOnAudioThread();

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
