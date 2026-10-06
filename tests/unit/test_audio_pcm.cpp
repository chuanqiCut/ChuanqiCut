// ChuanqiCut — 音频缓冲池 + SPSC 无锁样本环 单测（AUDIO-001）
//
// 验收对应 TASK-AUDIO-001：
//   1. Pool 装配校验：0 槽/未知格式/重复 Init → kInvalidArgument。
//   2. Pool 往返：Acquire 元数据正确、槽位互不重叠；耗尽 kResourceExhausted（不回退堆）。
//   3. Pool 防护：重复 Release / 外来指针 / null → kInvalidArgument；InUse 记账闭合。
//   4. Pool 多线程：4 线程 × 2 万次 Acquire/Release 并发，末态 InUse==0 且可整池取空。
//   5. Ring 装配校验：容量取整到 2 的幂；0 容量 / 重复 Init → kInvalidArgument。
//   6. Ring 单线程：读写回环、跨边界回绕数据完整性、满/空 → kResourceExhausted。
//   7. Ring SPSC 跨线程压测：20 万个序号按变长块往返，序号连续无丢失无重复。
//
// 所有测试只报统计与结论，不做听感/性能断言（性能归 baselines 回写）。

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>

#include "cq/audio/pcm_pool.h"
#include "cq/audio/spsc_ring.h"
#include "cq/base/status.h"

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
    spec.frames_per_block = 512;  // 单块 = 512*2*4 = 4096 字节
    return spec;
}

constexpr uint64_t kSpinLimit = 100000000;  // 自旋护栏（约数秒量级）
constexpr uint64_t kMaxChunk = 4;           // 压测变长块上限（uint64 个数）

void TestPoolInitValidation() {
    std::printf("[1] Pool Init 校验\n");
    cq::AudioBlockPool pool;
    Check(pool.Init(0, TestSpec()).code == cq::StatusCode::kInvalidArgument,
          "0 槽位应拒绝");
    cq::AudioGraphSpec bad = TestSpec();
    bad.format = cq::SampleFormat::kUnknown;
    Check(pool.Init(4, bad).code == cq::StatusCode::kInvalidArgument,
          "未知格式应拒绝");
    Check(pool.Init(4, TestSpec()).IsOk(), "合法规格应成功");
    Check(pool.Init(4, TestSpec()).code == cq::StatusCode::kInvalidArgument,
          "重复 Init 应拒绝");
}

void TestPoolRoundtrip() {
    std::printf("[2] Pool Acquire/Release 往返与耗尽\n");
    cq::AudioBlockPool pool;
    Check(pool.Init(3, TestSpec()).IsOk(), "Init 3 槽");
    cq::AudioBuffer a, b, c;
    Check(pool.Acquire(a).IsOk(), "Acquire #1");
    Check(pool.Acquire(b).IsOk(), "Acquire #2");
    Check(a.data != nullptr && b.data != nullptr && a.data != b.data,
          "槽位互不重叠");
    const bool same_meta = a.format == cq::SampleFormat::kFloat32 &&
                           a.channels == 2 && a.sample_rate == 48000 &&
                           a.frame_count == 512 && a.data_bytes == 4096;
    Check(same_meta, "Acquire 元数据来自规格模板");
    Check(pool.InUse() == 2, "InUse 记账 = 2");

    // 写入-读回验证内存可用性（pool 只管发放，内容归用户）。
    auto* samples = static_cast<float*>(a.data);
    for (uint32_t i = 0; i < 512 * 2; ++i) samples[i] = static_cast<float>(i) * 0.25f;
    Check(samples[100] == 25.0f, "写入后可读回");

    Check(pool.Acquire(c).IsOk(), "Acquire #3（取空）");
    cq::AudioBuffer d;
    Check(pool.Acquire(d).code == cq::StatusCode::kResourceExhausted,
          "第 4 次 Acquire 应耗尽拒绝（不回退堆）");
    Check(pool.Release(a).IsOk() && pool.Release(b).IsOk() && pool.Release(c).IsOk(),
          "逐块 Release 成功");
    Check(pool.InUse() == 0, "InUse 清零");
    Check(pool.Acquire(d).IsOk(), "归还后可再取");
    Check(pool.Release(d).IsOk(), "再还成功");
}

void TestPoolGuards() {
    std::printf("[3] Pool 重复归还 / 外来指针防护\n");
    cq::AudioBlockPool pool;
    Check(pool.Init(2, TestSpec()).IsOk(), "Init");
    cq::AudioBuffer a;
    Check(pool.Acquire(a).IsOk(), "Acquire");
    Check(pool.Release(a).IsOk(), "第一次 Release");
    Check(pool.Release(a).code == cq::StatusCode::kInvalidArgument, "重复 Release 拒绝");

    cq::AudioBuffer foreign{};
    foreign.format = cq::SampleFormat::kFloat32;
    foreign.channels = 2;
    float stack_bytes[64];
    foreign.data = stack_bytes;
    Check(pool.Release(foreign).code == cq::StatusCode::kInvalidArgument,
          "外来指针拒绝");

    cq::AudioBuffer nul{};
    nul.data = nullptr;
    Check(pool.Release(nul).code == cq::StatusCode::kInvalidArgument, "null 拒绝");
}

void TestPoolConcurrent() {
    std::printf("[4] Pool 多线程并发 Acquire/Release（4 线程 × 2 万次）\n");
    cq::AudioBlockPool pool;
    Check(pool.Init(4, TestSpec()).IsOk(), "Init 4 槽");
    constexpr int kThreads = 4;
    constexpr int kIters = 20000;
    std::atomic<int> bad_rw{0};
    std::atomic<int> bad_status{0};

    std::thread threads[kThreads];
    for (int t = 0; t < kThreads; ++t) {
        threads[t] = std::thread([t, &pool, &bad_rw, &bad_status]() {
            for (int i = 0; i < kIters; ++i) {
                cq::AudioBuffer buf;
                const cq::Status st = pool.Acquire(buf);
                if (!st.IsOk()) {
                    bad_status.fetch_add(1);
                    continue;
                }
                auto* samples = static_cast<float*>(buf.data);
                const float stamp = static_cast<float>(t) + 1.0f;
                samples[0] = stamp;
                samples[1023] = stamp;
                // 同一块内两个写点自读校验：若槽被双重发放会读到别人的值。
                if (samples[0] != stamp || samples[1023] != stamp) {
                    bad_rw.fetch_add(1);
                }
                if (!pool.Release(buf).IsOk()) {
                    bad_status.fetch_add(1);
                }
            }
        });
    }
    for (int t = 0; t < kThreads; ++t) threads[t].join();
    Check(bad_status.load() == 0, "并发期间无异常 Status");
    Check(bad_rw.load() == 0, "并发期间无槽位交叉污染");
    Check(pool.InUse() == 0, "并发结束 InUse 清零");
    // 末态不变量：整池可再次取空再全还。
    cq::AudioBuffer all[4];
    bool all_ok = true;
    for (int i = 0; i < 4; ++i) all_ok = all_ok && pool.Acquire(all[i]).IsOk();
    Check(all_ok, "末态整池可取空");
    Check(pool.Acquire(all[0]).code == cq::StatusCode::kResourceExhausted,
          "末态确认耗尽");
    for (int i = 0; i < 4; ++i) pool.Release(all[i]);
}

void TestRingInitValidation() {
    std::printf("[5] Ring Init 校验与 2 的幂取整\n");
    cq::SpscSampleRing ring;
    Check(ring.Init(0).code == cq::StatusCode::kInvalidArgument, "0 容量拒绝");
    Check(ring.Init(1000).IsOk(), "合法 Init");
    Check(ring.CapacityBytes() == 1024, "容量向上取整到 2 的幂");
    Check(ring.Init(1024).code == cq::StatusCode::kInvalidArgument, "重复 Init 拒绝");
}

void TestRingSingleThread() {
    std::printf("[6] Ring 单线程读写/回绕/满空\n");
    cq::SpscSampleRing ring;
    Check(ring.Init(16).IsOk(), "Init 16 字节");
    uint8_t buf[32];

    Check(ring.Write(buf, 0).IsOk(), "0 字节写为 no-op");
    Check(ring.Read(buf, 0).IsOk(), "0 字节读为 no-op");
    Check(ring.Read(buf, 1).code == cq::StatusCode::kResourceExhausted, "空读拒绝");
    Check(ring.Write(buf, 17).code == cq::StatusCode::kInvalidArgument,
          "单块超容量拒绝");

    // 回绕完整性：三轮「写 10 读 10」，第 2、3 轮跨越环形边界。
    for (int round = 0; round < 3; ++round) {
        for (int i = 0; i < 10; ++i) buf[i] = static_cast<uint8_t>(round * 10 + i);
        Check(ring.Write(buf, 10).IsOk(), "写 10 字节");
        std::memset(buf, 0, sizeof(buf));
        Check(ring.Read(buf, 10).IsOk(), "读 10 字节");
        bool ok = true;
        for (int i = 0; i < 10; ++i) {
            ok = ok && buf[i] == static_cast<uint8_t>(round * 10 + i);
        }
        Check(ok, "回绕后数据完整");
    }
    Check(ring.ReadableBytes() == 0, "读尽");
    Check(ring.WritableBytes() == 16, "写满可用空间恢复");
    Check(ring.Write(buf, 16).IsOk(), "恰好写满");
    Check(ring.Write(buf, 1).code == cq::StatusCode::kResourceExhausted, "满写拒绝");
}

void TestRingSpscStress() {
    std::printf("[7] Ring SPSC 跨线程压测（20 万序号，变长块）\n");
    cq::SpscSampleRing ring;
    Check(ring.Init(4096).IsOk(), "Init 4KB");
    constexpr uint64_t kTotalValues = 200000;  // uint64 序号流
    // 变长块调度：第 k 块写 1+(k%4) 个 uint64。生产/消费两侧同构，保证确定性。
    auto chunk_values = [](uint64_t k) -> uint64_t { return 1 + (k % 4); };

    std::atomic<bool> producer_done{false};
    std::atomic<int> producer_errors{0};
    std::atomic<uint64_t> consumer_read{0};
    std::atomic<int> consumer_errors{0};

    std::thread producer([&]() {
        uint64_t seq = 0;
        uint64_t chunk_index = 0;
        uint64_t spins = 0;
        uint64_t values[kMaxChunk];  // kMaxChunk = 4
        while (seq < kTotalValues) {
            uint64_t n = chunk_values(chunk_index++);
            if (seq + n > kTotalValues) n = kTotalValues - seq;
            for (uint64_t i = 0; i < n; ++i) values[i] = seq + i;
            if (ring.Write(values, n * sizeof(uint64_t)).IsOk()) {
                seq += n;
                spins = 0;
            } else if (++spins > kSpinLimit) {
                producer_errors.fetch_add(1);  // 死锁护栏：拒绝无限自旋
                return;
            } else {
                std::this_thread::yield();
            }
        }
        producer_done.store(true);
    });

    uint64_t expected = 0;
    uint64_t chunk_index = 0;
    uint64_t spins = 0;
    uint64_t values[kMaxChunk];
    while (expected < kTotalValues) {
        uint64_t n = chunk_values(chunk_index++);
        if (expected + n > kTotalValues) n = kTotalValues - expected;
        if (ring.Read(values, n * sizeof(uint64_t)).IsOk()) {
            for (uint64_t i = 0; i < n; ++i) {
                if (values[i] != expected + i) {
                    consumer_errors.fetch_add(1);  // 乱序/丢失/重复
                    break;
                }
            }
            expected += n;
            consumer_read.fetch_add(n);
            spins = 0;
        } else if (producer_done.load() && ring.ReadableBytes() < n * sizeof(uint64_t)) {
            consumer_errors.fetch_add(1);  // 生产者已结束却读不够 = 丢失
            break;
        } else if (++spins > kSpinLimit) {
            consumer_errors.fetch_add(1);  // 死锁护栏
            break;
        } else {
            std::this_thread::yield();
        }
    }
    producer.join();
    Check(producer_errors.load() == 0, "生产者无异常退出");
    Check(consumer_errors.load() == 0, "消费者校验通过（序号连续无丢失无重复）");
    Check(consumer_read.load() == kTotalValues, "读出总量 = 写入总量");
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::thread watchdog([]() {
        std::this_thread::sleep_for(std::chrono::seconds(30));
        std::fprintf(stderr, "FATAL: core_audio_pcm 单测超过 30s 未结束，判定挂死\n");
        std::abort();
    });
    watchdog.detach();

    std::printf("== ChuanqiCut core_audio_pcm 单测 ==\n");
    TestPoolInitValidation();
    TestPoolRoundtrip();
    TestPoolGuards();
    TestPoolConcurrent();
    TestRingInitValidation();
    TestRingSingleThread();
    TestRingSpscStress();

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
