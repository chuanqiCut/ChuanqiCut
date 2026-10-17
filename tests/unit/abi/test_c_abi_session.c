/* ChuanqiCut — 会话级模型 C ABI 验收（UIA-009 子步骤 1）
 *
 * 真正的 C 翻译单元（同 test_c_abi.c / test_c_abi_preview.c 的守卫方式）：
 * cq_sdk.h 混进任何 C++ 类型，本 TU 立即编译失败。
 *
 * 语义重点（cq_sdk.h 注释是契约）：
 *   * 提交是**异步**的 —— Ok 只代表入队；测试靠「轮询快照版本 + 查询」等最终一致。
 *   * 查询是同步读已发布快照：任意线程、无锁；未变更前为空时间线。
 *   * digest 为真实时间线指纹：加片段后 digest 必变。
 *   * 重叠 add_clip 在 session 线程校验失败：版本不推进、片段不出现。
 */

#include <stdio.h>
#include <string.h>

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

/* 等待快照版本到达 target（内核异步提交，测试轮询）。 */
static void WaitForVersion(const CQSession* s, uint64_t target) {
    for (int i = 0; i < 5000; ++i) {
        if (cq_session_current_snapshot(s).version >= target) return;
        /* 0.2ms 睡眠：跨平台 C 无 sleep_ms，用变更日志轮询兜底（见下） */
        for (volatile int j = 0; j < 20000; ++j) {
        }
    }
}

#define TS 120000

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("== ChuanqiCut 会话级模型 C ABI 验收（UIA-009 子步骤 1）==\n");

    /* ---- 初始状态：空时间线可查，digest 为真实指纹（空时间线也有值）---- */
    CQSession* s = cq_session_create();
    Check(s != NULL, "cq_session_create");

    int32_t count = -1;
    Check(cq_session_track_count(s, &count) == 0 && count == 0,
          "初始 track_count == 0（快照从构造起可读）");

    CQSnapshot snap0 = cq_session_current_snapshot(s);
    Check(snap0.version == 0, "初始版本 0");
    Check(snap0.digest != 0, "digest 为真实指纹（空时间线也有非零值）");

    /* ---- 注册素材 ---- */
    Check(cq_session_register_asset(s, 1, "/tmp/whatever.mp4") == 0,
          "register_asset 入队成功（素材不参与指纹，版本推进即可）");
    WaitForVersion(s, 1);
    Check(cq_session_current_snapshot(s).version == 1, "register_asset 后版本推进");
    Check(cq_session_current_snapshot(s).digest == snap0.digest,
          "素材注册不改变时间线指纹");

    /* ---- 加轨道 + 加片段（异步提交 → 轮询查询）---- */
    Check(cq_session_add_track(s, 0) == 0, "add_track(video) 入队");
    WaitForVersion(s, 2);

    count = -1;
    Check(cq_session_track_count(s, &count) == 0 && count == 1, "轨道出现");

    CQTrackInfo tracks[4];
    int32_t n_tracks = -1;
    Check(cq_session_query_tracks(s, NULL, 0, &n_tracks) == 0 && n_tracks == 1,
          "两段式：先查总数");
    Check(cq_session_query_tracks(s, tracks, 4, &n_tracks) == 0 && n_tracks == 1,
          "填充查询：rc=0 且写入 1 条");
    Check(tracks[0].kind == 0 && tracks[0].enabled == 1, "轨道字段正确");

    uint64_t digest_before_clip = cq_session_current_snapshot(s).digest;
    Check(cq_session_add_clip(s, tracks[0].track_id, 1,
                              0, TS, 5000, TS, 0, TS) == 0,
          "add_clip 入队");
    Check(cq_session_add_clip(s, tracks[0].track_id, 1,
                              8000, TS, 5000, TS, 0, TS) == 0,
          "add_clip #2 入队");
    WaitForVersion(s, 4);

    CQClipInfo clips[8];
    int32_t n_clips = -1;
    Check(cq_session_query_clips(s, 0, NULL, 0, &n_clips) == 0 && n_clips == 2,
          "两段式：片段总数 2");
    Check(cq_session_query_clips(s, 0, clips, 8, &n_clips) == 0 && n_clips == 2,
          "填充查询：rc=0 且写入 2 条");
    Check(clips[0].start_value < clips[1].start_value, "轨内按 start 升序");
    Check(clips[0].duration_value == 5000 && clips[0].duration_timescale == TS &&
              clips[0].asset_id == 1,
          "片段字段正确（值/刻度原样透传）");
    Check(clips[0].clip_id != clips[1].clip_id, "clip id 唯一");

    uint64_t digest_after_clip = cq_session_current_snapshot(s).digest;
    Check(digest_after_clip != digest_before_clip, "加片段后 digest 变化（真实指纹）");

    /* ---- track_id 过滤查询 ---- */
    n_clips = -1;
    Check(cq_session_query_clips(s, tracks[0].track_id, clips, 8, &n_clips) == 0 &&
              n_clips == 2, "按 track_id 过滤查询");
    Check(cq_session_query_clips(s, 999, clips, 8, &n_clips) == 0 && n_clips == 0,
          "不存在的轨道返回 0 条（rc 仍为 0）");

    /* ---- 失败语义：重叠 add_clip → 版本不推进、片段不出现 ---- */
    uint64_t ver_before = cq_session_current_snapshot(s).version;
    Check(cq_session_add_clip(s, tracks[0].track_id, 1,
                              2000, TS, 5000, TS, 0, TS) == 0,
          "重叠 add_clip 仍入队成功（校验在 session 线程）");
    WaitForVersion(s, ver_before + 1);
    /* 给一点余量等校验失败落地（版本停在 ver_before） */
    for (volatile int j = 0; j < 500000; ++j) {
    }
    Check(cq_session_current_snapshot(s).version == ver_before,
          "校验失败：版本不推进");
    n_clips = -1;
    cq_session_query_clips(s, 0, NULL, 0, &n_clips);
    Check(n_clips == 2, "校验失败：片段不出现");

    /* ---- 参数校验（同步，调用侧）---- */
    Check(cq_session_add_clip(s, 1, 1, 0, 0, 1000, TS, 0, TS) == 7000,
          "timescale 非法 → 同步拒绝");
    Check(cq_session_add_track(s, 7) == 7000, "kind 非法 → 同步拒绝");
    Check(cq_session_track_count(NULL, &count) == 7000, "NULL session → 7000");

    cq_session_destroy(s);

    printf("== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
