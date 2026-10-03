/* ChuanqiCut — 片段编辑与撤销 C ABI 验收（UIA-005）
 *
 * 真正的 C 翻译单元（同 test_c_abi_session.c）：cq_sdk.h 混进任何 C++ 类型，
 * 本 TU 立即编译失败。只链 cq_core —— 新 ABI 不得引入 PAL 依赖（ADR-0011）。
 *
 * 同步手法（重要，别退化成 sleep）：
 *   提交是**异步**的（Ok = 已入队），校验在 session 线程发生 —— 而「校验
 *   失败」的表现是**版本不推进**，光靠等版本推进永远等不到。故统一用
 *   Drain()：提交一条必定成功的哨兵变更并等它落地。session 队列 FIFO，
 *   哨兵执行完 ⇒ 它之前的所有提交（含被拒的那些）都已执行完毕。
 *   这比「忙等 N 微秒然后猜」确定得多（pitfalls 里同类坑已踩过多次）。
 *
 * 覆盖：
 *   * move_clip 生效 / 与同轨片段重叠被拒（模型不动、版本只推进哨兵那一次）
 *   * trim_clip 生效 / duration ≤ 0 被拒 / 与下一片段重叠被拒
 *   * undo/redo 往返：值回到原状、digest 回到原状、clip id 不变（回放不重分配）
 *   * can_undo / can_redo 语义；空历史 undo 被拒
 *   * 参数校验：timescale ≤ 0 与 NULL session 同步拒绝
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

static int32_t SentinelOk(void* ctx) {
    (void)ctx;
    return 0; /* kOk */
}

/* 等快照版本到达 target。 */
static void WaitForVersion(const CQSession* s, uint64_t target) {
    for (int i = 0; i < 5000; ++i) {
        if (cq_session_current_snapshot(s).version >= target) return;
        for (volatile int j = 0; j < 20000; ++j) {
        }
    }
}

/* 同步点：投递哨兵并等它落地 ⇒ 此前所有提交都已执行完（含被拒的）。
 *
 * k = 本次预期**成功**的提交条数（预期被拒的不计）。session 队列 FIFO，
 * 哨兵落地时版本恰好推进 k+1 —— 这个「+1」同时是**失败语义的判据**：
 * 若 X 被拒，版本只推进哨兵那一次。
 *
 * ⚠️ 不能写成「等到 version >= before + 1」：那只要队列里任意一条先落地
 *    就满足了，后面的提交可能还没执行 —— 首版就是这么写的，结果 19 条断言
 *    集体失败（查询拿到的还是旧快照）。 */
static void DrainAfter(CQSession* s, int k) {
    uint64_t before = cq_session_current_snapshot(s).version;
    if (cq_session_submit(s, "test-sentinel", SentinelOk, NULL) != 0) return;
    WaitForVersion(s, before + (uint64_t)k + 1);
}

/* 取第 index 个片段（按查询顺序）。 */
static int QueryClips(const CQSession* s, CQClipInfo* out, int capacity, int32_t* n) {
    return cq_session_query_clips(s, 0, out, capacity, n);
}

#define TS 120000

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("== ChuanqiCut 片段编辑与撤销 C ABI 验收（UIA-005）==\n");

    CQSession* s = cq_session_create();
    Check(s != NULL, "cq_session_create");

    /* ---- 装配：1 轨 + 2 片段（历史里 3 条命令）---- */
    Check(cq_session_register_asset(s, 1, "/tmp/a.mp4") == 0, "register_asset 入队");
    Check(cq_session_add_track(s, 0) == 0, "add_track 入队");
    DrainAfter(s, 2);  /* register + add_track */

    CQTrackInfo tracks[4];
    int32_t n_tracks = -1;
    Check(cq_session_query_tracks(s, tracks, 4, &n_tracks) == 0 && n_tracks == 1, "轨道存在");

    Check(cq_session_add_clip(s, tracks[0].track_id, 1, 0, TS, 5000, TS, 0, TS) == 0,
          "add_clip A（0..5000）入队");
    Check(cq_session_add_clip(s, tracks[0].track_id, 1, 8000, TS, 5000, TS, 0, TS) == 0,
          "add_clip B（8000..13000）入队");
    DrainAfter(s, 2);

    CQClipInfo clips[8];
    int32_t n_clips = -1;
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && n_clips == 2, "两个片段在位");
    const uint64_t clip_a = clips[0].clip_id;
    const uint64_t clip_b = clips[1].clip_id;
    Check(clips[0].start_value == 0 && clips[1].start_value == 8000, "初始起点正确");
    Check(cq_session_can_undo(s) == 1, "有命令历史 → can_undo == 1");
    Check(cq_session_can_redo(s) == 0, "未撤销过 → can_redo == 0");

    /* ---- move：合法移动 ---- */
    uint64_t digest_before_move = cq_session_current_snapshot(s).digest;
    Check(cq_session_move_clip(s, clip_a, 1000, TS) == 0, "move_clip A → 1000 入队");
    DrainAfter(s, 1);
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && n_clips == 2, "move 后仍 2 片段");
    Check(clips[0].clip_id == clip_a && clips[0].start_value == 1000,
          "move 生效：A.start == 1000（内核真值，非 UI 本地预览）");
    Check(cq_session_current_snapshot(s).digest != digest_before_move, "move 改变时间线指纹");

    /* ---- move：与 B 重叠 → 拒绝 ---- */
    uint64_t ver_before = cq_session_current_snapshot(s).version;
    Check(cq_session_move_clip(s, clip_a, 7000, TS) == 0, "重叠 move 仍入队（校验在 session 线程）");
    DrainAfter(s, 0);  /* 预期被拒：版本只推进哨兵 */
    Check(cq_session_current_snapshot(s).version == ver_before + 1,
          "重叠 move 被拒：版本只推进了哨兵那一次");
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && clips[0].start_value == 1000,
          "重叠 move 被拒：A.start 保持 1000");

    /* ---- trim：合法裁剪（改 duration，不动 source_in）---- */
    uint64_t digest_before_trim = cq_session_current_snapshot(s).digest;
    Check(cq_session_trim_clip(s, clip_a, 3000, TS) == 0, "trim_clip A → 3000 入队");
    DrainAfter(s, 1);
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && clips[0].duration_value == 3000,
          "trim 生效：A.duration == 3000");
    Check(clips[0].source_in_value == 0, "trim 不动 source_in（MODEL-002 既定语义）");
    Check(cq_session_current_snapshot(s).digest != digest_before_trim, "trim 改变时间线指纹");

    /* ---- trim：非法（duration = 0 / 与 B 重叠）---- */
    ver_before = cq_session_current_snapshot(s).version;
    Check(cq_session_trim_clip(s, clip_a, 0, TS) == 0, "duration=0 的 trim 入队");
    DrainAfter(s, 0);
    Check(cq_session_current_snapshot(s).version == ver_before + 1, "duration=0 被拒");
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && clips[0].duration_value == 3000,
          "duration=0 被拒：A.duration 保持 3000");

    ver_before = cq_session_current_snapshot(s).version;
    Check(cq_session_trim_clip(s, clip_a, 9000, TS) == 0, "重叠 trim（1000+9000 > 8000）入队");
    DrainAfter(s, 0);
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && clips[0].duration_value == 3000,
          "重叠 trim 被拒：A.duration 保持 3000");

    /* ---- undo ×2：回到 move 之前 ---- */
    Check(cq_session_undo(s) == 0, "undo #1 入队（撤销 trim）");
    DrainAfter(s, 1);
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && clips[0].duration_value == 5000,
          "undo trim：A.duration 回到 5000");
    Check(cq_session_can_redo(s) == 1, "撤销后可重做 → can_redo == 1");

    Check(cq_session_undo(s) == 0, "undo #2 入队（撤销 move）");
    DrainAfter(s, 1);
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && clips[0].start_value == 0,
          "undo move：A.start 回到 0");
    Check(cq_session_current_snapshot(s).digest == digest_before_move,
          "undo 两次后指纹回到 move 之前（撤销真的还原了模型）");

    /* ---- redo ×2：再前进 ---- */
    Check(cq_session_redo(s) == 0, "redo #1 入队");
    DrainAfter(s, 1);
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && clips[0].start_value == 1000,
          "redo move：A.start 回到 1000");
    Check(cq_session_redo(s) == 0, "redo #2 入队");
    DrainAfter(s, 1);
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && clips[0].duration_value == 3000,
          "redo trim：A.duration 回到 3000");
    Check(cq_session_can_redo(s) == 0, "redo 到底 → can_redo == 0");

    /* ---- 全 undo 到空 → 全 redo：id 必须原样恢复 ---- */
    for (int i = 0; i < 5; ++i) {
        Check(cq_session_undo(s) == 0, "undo 到底入队");
        DrainAfter(s, 1);
    }
    n_tracks = -1;
    Check(cq_session_query_tracks(s, tracks, 4, &n_tracks) == 0 && n_tracks == 0,
          "全 undo 后时间线为空");
    Check(cq_session_can_undo(s) == 0, "历史空 → can_undo == 0");

    ver_before = cq_session_current_snapshot(s).version;
    Check(cq_session_undo(s) == 0, "空历史 undo 仍入队");
    DrainAfter(s, 0);
    Check(cq_session_current_snapshot(s).version == ver_before + 1,
          "空历史 undo 被拒：版本只推进哨兵");

    for (int i = 0; i < 5; ++i) {
        Check(cq_session_redo(s) == 0, "redo 回顶入队");
        DrainAfter(s, 1);
    }
    Check(QueryClips(s, clips, 8, &n_clips) == 0 && n_clips == 2, "全 redo 后 2 片段回归");
    Check(clips[0].clip_id == clip_a && clips[1].clip_id == clip_b,
          "redo 恢复原 clip id（RestoreClip 生效，未重分配）");
    Check(clips[0].start_value == 1000 && clips[0].duration_value == 3000,
          "全 redo 后状态与撤销前一致");
    Check(cq_session_can_undo(s) == 1 && cq_session_can_redo(s) == 0, "redo 到底后能力标志正确");

    /* ---- 参数校验（同步，调用侧）---- */
    Check(cq_session_move_clip(s, clip_a, 0, 0) == 7000, "move timescale=0 → 同步拒绝");
    Check(cq_session_trim_clip(s, clip_a, 100, 0) == 7000, "trim timescale=0 → 同步拒绝");
    Check(cq_session_undo(NULL) == 7000, "NULL session undo → 7000");
    Check(cq_session_redo(NULL) == 7000, "NULL session redo → 7000");
    Check(cq_session_can_undo(NULL) == 0, "NULL session can_undo → 0（数据非状态码）");
    Check(cq_session_can_redo(NULL) == 0, "NULL session can_redo → 0");

    cq_session_destroy(s);

    printf("== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
