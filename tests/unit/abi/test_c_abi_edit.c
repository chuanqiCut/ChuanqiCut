/* ChuanqiCut — 片段编辑与撤销 C ABI 验收（UIA-005）
 *
 * 真正的 C 翻译单元（同 test_c_abi_session.c）：cq_sdk.h 混进任何 C++ 类型，
 * 本 TU 立即编译失败。只链 cq_core —— 新 ABI 不得引入 Platform 依赖（ADR-0011）。
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
 *   * EDIT-007：split（左半保 id / 右半新 id / 边界拒绝）+ remove_clip /
 *     remove_track 的删除与原 id 恢复
 *   * EDIT-008：trim_clip_in（start / source_in / duration 三字段联动、右缘
 *     不动、越界拒绝）
 *   * UIA-040：set_canvas / get_canvas（默认 9:16、可撤销）+ move_clip_to_track
 *     （id 不变上画中画轨、undo 回原轨）
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
    DrainAfter(s, 2); /* register + add_track */

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
    DrainAfter(s, 0); /* 预期被拒：版本只推进哨兵 */
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

    /* ========================================================================
     * EDIT-007/008：split / trim_in / remove（独立新会话，避免历史纠缠）
     * ====================================================================== */
    CQSession* s2 = cq_session_create();
    Check(s2 != NULL, "第二会话创建");

    Check(cq_session_register_asset(s2, 1, "/tmp/a.mp4") == 0, "register_asset 入队");
    Check(cq_session_add_track(s2, 0) == 0, "add_track 入队");
    DrainAfter(s2, 2);
    n_tracks = -1;
    Check(cq_session_query_tracks(s2, tracks, 4, &n_tracks) == 0 && n_tracks == 1,
          "第二会话轨道在位（id 空间独立，必须重查）");
    Check(cq_session_add_clip(s2, tracks[0].track_id, 1, 0, TS, 5000, TS, 0, TS) == 0,
          "add_clip A（0..5000）入队");
    DrainAfter(s2, 1);
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && n_clips == 1, "片段 A 在位");
    const uint64_t a_id = clips[0].clip_id;

    /* ---- split：左半保 id，右半新 id，媒体引用联动 ---- */
    Check(cq_session_split_clip(s2, a_id, 2000, TS) == 0, "split A @2000 入队");
    DrainAfter(s2, 1);
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && n_clips == 2, "split 后 2 片段");
    Check(clips[0].clip_id == a_id && clips[0].duration_value == 2000, "左半保 id 且收缩");
    const uint64_t right_id = clips[1].clip_id;
    Check(right_id != a_id, "右半获得新 id（经查询确认，与 add_clip 同约定）");
    Check(clips[1].start_value == 2000 && clips[1].duration_value == 3000, "右半占 [at, end)");
    Check(clips[1].source_in_value == 2000 && clips[1].source_duration_value == 3000,
          "右半 source_in / source_duration 联动");

    ver_before = cq_session_current_snapshot(s2).version;
    Check(cq_session_split_clip(s2, a_id, 0, TS) == 0, "切在 start 边界仍入队");
    DrainAfter(s2, 0);
    Check(cq_session_current_snapshot(s2).version == ver_before + 1, "切在边界被拒");

    /* ---- trim_clip_in：右缘不动，三字段联动 ---- */
    Check(cq_session_trim_clip_in(s2, right_id, 3000, TS) == 0, "trim_clip_in 右半 → 3000 入队");
    DrainAfter(s2, 1);
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && clips[1].start_value == 3000 &&
              clips[1].duration_value == 2000 && clips[1].source_in_value == 3000,
          "trim_in 生效：start / duration / source_in 三字段联动");
    Check(clips[1].start_value + clips[1].duration_value == 5000, "右缘（end）保持 5000 不动");

    ver_before = cq_session_current_snapshot(s2).version;
    Check(cq_session_trim_clip_in(s2, right_id, 6000, TS) == 0, "越界 trim_in 仍入队");
    DrainAfter(s2, 0);
    Check(cq_session_current_snapshot(s2).version == ver_before + 1,
          "trim_in 越过右缘被拒（duration ≤ 0）");

    /* ---- 撤销链：trim_in → split 逐层还原，再 redo 逐层重放 ---- */
    Check(cq_session_undo(s2) == 0, "undo trim_in 入队");
    DrainAfter(s2, 1);
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && clips[1].start_value == 2000 &&
              clips[1].duration_value == 3000,
          "undo trim_in：右半回到分割后原状");
    Check(cq_session_undo(s2) == 0, "undo split 入队");
    DrainAfter(s2, 1);
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && n_clips == 1 &&
              clips[0].clip_id == a_id && clips[0].duration_value == 5000,
          "undo split：回到单片段原状（原 id 原时长）");
    Check(cq_session_redo(s2) == 0, "redo split 入队");
    DrainAfter(s2, 1);
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && n_clips == 2 &&
              clips[1].clip_id == right_id,
          "redo split：右半原 id 恢复（RestoreClip 生效）");

    /* ---- remove_clip / remove_track：删除与原 id 恢复 ---- */
    Check(cq_session_remove_clip(s2, right_id) == 0, "remove_clip 右半入队");
    DrainAfter(s2, 1);
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && n_clips == 1, "删除后只剩左半");
    Check(cq_session_undo(s2) == 0, "undo remove_clip 入队");
    DrainAfter(s2, 1);
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && n_clips == 2 &&
              clips[1].clip_id == right_id,
          "undo remove_clip：原 id 恢复");

    Check(cq_session_remove_track(s2, tracks[0].track_id) == 0, "remove_track 入队");
    DrainAfter(s2, 1);
    n_tracks = -1;
    Check(cq_session_query_tracks(s2, tracks, 4, &n_tracks) == 0 && n_tracks == 0,
          "轨道连同片段一起消失");
    Check(cq_session_undo(s2) == 0, "undo remove_track 入队");
    DrainAfter(s2, 1);
    n_tracks = -1;
    Check(cq_session_query_tracks(s2, tracks, 4, &n_tracks) == 0 && n_tracks == 1,
          "undo remove_track：轨道恢复");
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && n_clips == 2 &&
              clips[0].clip_id == a_id && clips[1].clip_id == right_id,
          "轨道内片段原 id 全部恢复");

    /* ---- UIA-040：画布比例 + 跨轨移动 ---- */
    int32_t cw = 0, ch = 0;
    Check(cq_session_get_canvas(s2, &cw, &ch) == 0 && cw == 1080 && ch == 1920,
          "get_canvas 默认 1080×1920（9:16）");
    Check(cq_session_set_canvas(s2, 1080, 1080) == 0, "set_canvas 1:1 入队");
    DrainAfter(s2, 1);
    Check(cq_session_get_canvas(s2, &cw, &ch) == 0 && cw == 1080 && ch == 1080, "画布生效");
    Check(cq_session_undo(s2) == 0, "undo 画布入队");
    DrainAfter(s2, 1);
    Check(cq_session_get_canvas(s2, &cw, &ch) == 0 && ch == 1920, "undo 画布回 9:16（画布可撤销）");

    Check(cq_session_add_track(s2, 0) == 0, "add_track 画中画轨入队");
    DrainAfter(s2, 1);
    n_tracks = -1;
    Check(cq_session_query_tracks(s2, tracks, 4, &n_tracks) == 0 && n_tracks == 2, "两条轨道");
    const uint64_t overlay_track = tracks[1].track_id;
    Check(cq_session_move_clip_to_track(s2, right_id, overlay_track, 0, TS) == 0,
          "跨轨移动入队");
    DrainAfter(s2, 1);
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && n_clips == 2, "跨轨后仍 2 片段");
    Check(clips[1].track_id == overlay_track && clips[1].clip_id == right_id &&
              clips[1].start_value == 0,
          "右半上画中画轨：id 不变、新起点生效");
    Check(cq_session_undo(s2) == 0, "undo 跨轨入队");
    DrainAfter(s2, 1);
    Check(QueryClips(s2, clips, 8, &n_clips) == 0 && n_clips == 2 &&
              clips[1].track_id == tracks[0].track_id,
          "undo 跨轨回原轨原位");

    /* ---- CORE-011：轨道静音写路径（可撤销 + 未知轨失败）---- */
    Check(cq_session_set_track_muted(s2, tracks[0].track_id, 1) == 0, "静音入队");
    DrainAfter(s2, 1);
    n_tracks = -1;
    Check(cq_session_query_tracks(s2, tracks, 4, &n_tracks) == 0 && tracks[0].muted == 1,
          "查询回读 muted=1");
    Check(cq_session_undo(s2) == 0, "undo 静音入队");
    DrainAfter(s2, 1);
    n_tracks = -1;
    Check(cq_session_query_tracks(s2, tracks, 4, &n_tracks) == 0 && tracks[0].muted == 0,
          "undo 回 muted=0（进撤销栈，不是绕过历史的裸写）");
    Check(cq_session_set_track_muted(s2, 999999, 1) == 0, "未知轨也先入队（Ok≠校验通过）");
    DrainAfter(s2, 0);
    n_tracks = -1;
    Check(cq_session_query_tracks(s2, tracks, 4, &n_tracks) == 0 && tracks[0].muted == 0,
          "未知轨失败没动模型");

    /* ---- 新 ABI 参数校验（同步，调用侧）---- */
    Check(cq_session_split_clip(s2, a_id, 100, 0) == 7000, "split timescale=0 → 同步拒绝");
    Check(cq_session_trim_clip_in(s2, a_id, 100, 0) == 7000, "trim_in timescale=0 → 同步拒绝");
    Check(cq_session_split_clip(NULL, a_id, 100, TS) == 7000, "NULL session split → 7000");
    Check(cq_session_trim_clip_in(NULL, a_id, 100, TS) == 7000, "NULL session trim_in → 7000");
    Check(cq_session_remove_clip(NULL, a_id) == 7000, "NULL session remove_clip → 7000");
    Check(cq_session_remove_track(NULL, 1) == 7000, "NULL session remove_track → 7000");
    Check(cq_session_move_clip_to_track(NULL, 1, 1, 0, TS) == 7000, "NULL session 跨轨 → 7000");
    Check(cq_session_set_canvas(NULL, 100, 100) == 7000, "NULL session set_canvas → 7000");
    Check(cq_session_set_track_muted(NULL, 1, 1) == 7000, "NULL session set_track_muted → 7000");
    Check(cq_session_get_canvas(NULL, &cw, &ch) == 7000, "NULL session get_canvas → 7000");

    cq_session_destroy(s2);

    printf("== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
