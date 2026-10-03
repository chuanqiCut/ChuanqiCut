/* ChuanqiCut — 播放时钟与时间线时长 C ABI 验收（UIA-010）
 *
 * 真正的 C 翻译单元：cq_sdk.h 混进任何 C++ 类型，本 TU 立即编译失败。
 * 只链 cq_core —— 播放时钟是纯计算，不引 PAL 依赖。
 *
 * 覆盖：
 *   * 时刻随墙钟推进（不依赖调用频率）；恒为整帧
 *   * 暂停冻结 / 停止归 0 / 定位量化
 *   * 边界：到时长末尾 tick 后停止（loop 开则回绕）
 *   * NULL 与非法参数：不崩，返回约定值
 *   * cq_session_timeline_duration：空时间线 0；加片段后为真实时长
 *
 * ⚠️ 等待手法：不 sleep（C 无便携 sleep），改为**轮询到目标时刻**或超时。
 *   这同时是断言本身 —— 时钟若不随墙钟走，轮询必然超时。
 */

#include <stdio.h>

#include "cq/cq_sdk.h"

static int g_failures = 0;
static int g_checks = 0;

static void Check(int cond, const char* msg) {
    ++g_checks;
    if (cond) {
        printf("  ok  : %s\n", msg);
    } else {
        ++g_failures;
        printf("  FAIL: %s\n", msg);
    }
}

static int64_t Now(const CQPlayer* p) {
    int64_t v = 0;
    int32_t ts = 0;
    cq_player_current_time(p, &v, &ts);
    return v;
}

/* 轮询直到时刻 >= target（或超时）。返回最终时刻。 */
static int64_t WaitUntilAtLeast(const CQPlayer* p, int64_t target, int max_iters) {
    for (int i = 0; i < max_iters; ++i) {
        int64_t v = Now(p);
        if (v >= target) return v;
        for (volatile int j = 0; j < 20000; ++j) {
        }
    }
    return Now(p);
}

static void WaitVersion(const CQSession* s, uint64_t target) {
    for (int i = 0; i < 5000; ++i) {
        if (cq_session_current_snapshot(s).version >= target) return;
        for (volatile int j = 0; j < 20000; ++j) {
        }
    }
}

static int32_t SentinelOk(void* ctx) {
    (void)ctx;
    return 0;
}

static void DrainAfter(CQSession* s, int k) {
    uint64_t before = cq_session_current_snapshot(s).version;
    if (cq_session_submit(s, "test-sentinel", SentinelOk, NULL) != 0) return;
    WaitVersion(s, before + (uint64_t)k + 1);
}

#define FRAME_TICKS 1001
#define TS 30000

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("== ChuanqiCut 播放时钟 C ABI 验收（UIA-010）==\n");

    CQPlayer* p = cq_player_create(FRAME_TICKS, TS);
    Check(p != NULL, "cq_player_create");

    /* ---- 初始：停止态时刻恒 0 ---- */
    Check(cq_player_is_playing(p) == 0, "初始不在播放");
    int64_t v = -1;
    int32_t ts = 0;
    Check(cq_player_current_time(p, &v, &ts) == 0 && v == 0, "初始时刻 0");
    Check(ts == TS, "时刻 timescale = 帧网格");

    /* ---- 播放：推进随墙钟（轮询到 0.1s，超时即失败）---- */
    Check(cq_player_play(p) == 0, "play");
    Check(cq_player_is_playing(p) == 1, "play 后 is_playing == 1");
    const int64_t reached = WaitUntilAtLeast(p, 3000, 20000);  // 0.1s = 3000 ticks
    Check(reached >= 3000 && reached < 30000, "时刻随墙钟推进到 ≥0.1s（非帧数累加）");
    Check(reached % FRAME_TICKS == 0, "时刻恒为整帧（帧网格量化）");

    /* ---- 暂停：冻结 ---- */
    cq_player_pause(p);
    Check(cq_player_is_playing(p) == 0, "pause 后不在播放");
    const int64_t frozen = Now(p);
    WaitUntilAtLeast(p, frozen + 100000, 2000);  // 空转一会（会超时返回）
    Check(Now(p) == frozen, "暂停后时刻冻结");

    /* ---- 定位：量化到整帧 ---- */
    Check(cq_player_seek(p, 15000, TS) == 0, "seek 到 0.5s");
    Check(Now(p) == 14 * FRAME_TICKS, "seek 量化到整帧（向下，不越帧）");

    /* ---- 停止：归 0 ---- */
    cq_player_stop(p);
    Check(Now(p) == 0, "stop 后归 0");

    /* ---- 边界：播完自然结束 → 停止回 0 ---- */
    Check(cq_player_set_duration(p, 6000, TS) == 0, "设置时长 0.2s");
    cq_player_play(p);
    WaitUntilAtLeast(p, 6000, 20000);
    Check(Now(p) == 6000, "超过边界后 clamp 到时长");
    Check(cq_player_tick(p) == 0, "tick 到边界");
    Check(cq_player_is_playing(p) == 0, "播完自然结束 → 停止");
    Check(Now(p) == 0, "结束后时刻回 0（语义单一）");

    /* ---- 循环 ---- */
    cq_player_set_duration(p, 6000, TS);
    cq_player_set_loop(p, 1);
    cq_player_play(p);
    WaitUntilAtLeast(p, 6000, 20000);
    cq_player_tick(p);
    Check(cq_player_is_playing(p) == 1, "loop 模式：到边界后仍在播放");
    Check(Now(p) < 6000, "loop 模式：回绕（时刻小于时长）");

    /* ---- NULL / 非法参数 ---- */
    Check(cq_player_is_playing(NULL) == 0, "NULL player is_playing → 0");
    Check(cq_player_current_time(NULL, &v, &ts) == 7000, "NULL player current_time → 7000");
    Check(cq_player_play(NULL) == 7000, "NULL player play → 7000");
    Check(cq_player_seek(p, 0, 0) == 7000, "seek timescale=0 → 7000");
    Check(cq_player_set_duration(p, 1, 0) == 7000, "set_duration timescale=0 → 7000");
    cq_player_pause(NULL);   /* 不得崩 */
    cq_player_stop(NULL);
    cq_player_destroy(NULL);
    Check(1, "NULL 上的 void 接口不崩（幂等）");

    /* 非法帧时长不返回 NULL（纯计算对象，回落到默认） */
    CQPlayer* weird = cq_player_create(-5, 0);
    Check(weird != NULL, "非法帧时长不返回 NULL（内部回落）");
    cq_player_destroy(weird);

    cq_player_destroy(p);

    /* ---- 时间线总时长（播放边界的唯一真源）---- */
    CQSession* s = cq_session_create();
    Check(s != NULL, "session 创建");
    int64_t dur = -1;
    int32_t dts = 0;
    Check(cq_session_timeline_duration(s, &dur, &dts) == 0 && dur == 0,
          "空时间线时长 0");

    uint64_t base = cq_session_current_snapshot(s).version;
    cq_session_register_asset(s, 1, "/tmp/a.mp4");
    cq_session_add_track(s, 0);
    DrainAfter(s, 2);
    CQTrackInfo tracks[4];
    int32_t n_tracks = -1;
    cq_session_query_tracks(s, tracks, 4, &n_tracks);
    Check(n_tracks == 1, "轨道存在（前置）");

    base = cq_session_current_snapshot(s).version;
    cq_session_add_clip(s, tracks[0].track_id, 1, 0, 120000, 600000, 120000, 0, 120000);
    DrainAfter(s, 1);

    Check(cq_session_timeline_duration(s, &dur, &dts) == 0, "查询时长");
    Check(dur == 600000 && dts == 120000,
          "时长 = 末片段结束（5s @120000）—— 播放边界由内核算，UI 不自己算");
    Check(cq_session_timeline_duration(NULL, &dur, &dts) == 7000, "NULL session → 7000");

    cq_session_destroy(s);

    printf("== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
