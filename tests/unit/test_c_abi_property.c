/* ChuanqiCut — 片段效果属性 C ABI 验收（MODEL-003）
 *
 * 真正的 C 翻译单元（同 test_c_abi_edit.c）：cq_sdk.h 混进任何 C++ 类型，
 * 本 TU 立即编译失败。只链 cq_core —— 新 ABI 不得引入 Platform 依赖（ADR-0011）。
 *
 * 同步手法与 test_c_abi_edit.c 完全一致：提交是异步的（Ok = 已入队），
 * 校验在 session 线程发生，「失败」表现为版本不推进。统一用 DrainAfter()
 * 投递哨兵并等它落地 —— session 队列 FIFO，哨兵执行完代表此前全部提交
 * （含被拒的）都已执行。不写 sleep 轮询。
 *
 * 覆盖：
 *   * add_clip_effect → 两段式查询（总数 + 数据）、条目字段（id/name/enabled）
 *   * 五类参数 setter（i64/float/bool/color/vec2）→ query 读回类型与值
 *   * set_enabled → 查询反映启用位
 *   * 撤销链：remove → undo（参数与顺序整栈还原）→ redo；参数命令逐层 undo
 *   * digest 真断言：改参数 → 指纹变（模型层字段覆盖的端到端证明）
 *   * 失败语义：重复 effect_id / 效果不存在设参 / clip 不存在查询
 *   * 同步参数校验：NULL session / NULL 字符串 → 7000
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
 * k = 本次预期**成功**的提交条数。 */
static void DrainAfter(CQSession* s, int k) {
    uint64_t before = cq_session_current_snapshot(s).version;
    if (cq_session_submit(s, "test-sentinel", SentinelOk, NULL) != 0) return;
    WaitForVersion(s, before + (uint64_t)k + 1);
}

#define TS 120000

/* 造 1 轨 + 1 片段，返回 clip_id（0 = 失败）。 */
static uint64_t MakeClip(CQSession* s) {
    if (cq_session_register_asset(s, 1, "/tmp/a.mp4") != 0) return 0;
    if (cq_session_add_track(s, 0) != 0) return 0;
    DrainAfter(s, 2);
    CQTrackInfo tracks[4];
    int32_t n_tracks = -1;
    if (cq_session_query_tracks(s, tracks, 4, &n_tracks) != 0 || n_tracks != 1) return 0;
    if (cq_session_add_clip(s, tracks[0].track_id, 1, 0, TS, 5000, TS, 0, TS) != 0) return 0;
    DrainAfter(s, 1);
    CQClipInfo clips[4];
    int32_t n_clips = -1;
    if (cq_session_query_clips(s, 0, clips, 4, &n_clips) != 0 || n_clips != 1) return 0;
    return clips[0].clip_id;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("== 片段效果属性 C ABI 验收（MODEL-003）==\n");

    CQSession* s = cq_session_create();
    Check(s != NULL, "cq_session_create");

    const uint64_t clip_id = MakeClip(s);
    Check(clip_id != 0, "装配：1 轨 + 1 片段（clip_id 经查询确认）");

    /* ---- 空时间线上的效果查询：clip 不存在 → 7000 ---- */
    {
        int32_t n = -1;
        Check(cq_session_clip_effect_count(s, 99999, &n) == 7000,
              "clip 不存在 → effect_count 返回 7000（不是 0，分码）");
    }

    /* ---- add_clip_effect ---- */
    Check(cq_session_add_clip_effect(s, clip_id, "cq.effect.blur", "高斯模糊") == 0,
          "add_clip_effect 入队");
    DrainAfter(s, 1);

    int32_t n_effects = -1;
    Check(cq_session_clip_effect_count(s, clip_id, &n_effects) == 0 && n_effects == 1,
          "效果计数 == 1（异步提交已落地）");

    /* 两段式查询：先 out=NULL 拿总数 */
    n_effects = -1;
    Check(cq_session_query_clip_effects(s, clip_id, NULL, 0, &n_effects) == 0 && n_effects == 1,
          "两段式：out=NULL 返回总数 1");

    CQEffectInfo effects[4];
    n_effects = -1;
    Check(cq_session_query_clip_effects(s, clip_id, effects, 4, &n_effects) == 0 &&
              n_effects == 1,
          "query_clip_effects 写入 1 条");
    Check(strcmp(effects[0].effect_id, "cq.effect.blur") == 0, "effect_id 正确");
    Check(strcmp(effects[0].effect_name, "高斯模糊") == 0, "effect_name 正确（UTF-8 原样）");
    Check(effects[0].enabled == 1, "默认启用");
    Check(effects[0].param_count == 0, "初始参数袋为空");
    Check(effects[0].truncated == 0, "短字符串未截断");

    /* ---- 五类参数 setter ---- */
    Check(cq_session_set_clip_effect_param_float(s, clip_id, "cq.effect.blur", "opacity",
                                                 0.5f) == 0,
          "set param float 入队");
    Check(cq_session_set_clip_effect_param_i64(s, clip_id, "cq.effect.blur", "preset",
                                               3) == 0,
          "set param i64 入队");
    Check(cq_session_set_clip_effect_param_bool(s, clip_id, "cq.effect.blur", "hi_pass",
                                                1) == 0,
          "set param bool 入队");
    Check(cq_session_set_clip_effect_param_color(s, clip_id, "cq.effect.blur", "tint", 0.1f,
                                                 0.2f, 0.3f, 0.4f) == 0,
          "set param color 入队");
    Check(cq_session_set_clip_effect_param_vec2(s, clip_id, "cq.effect.blur", "scale", 1.5f,
                                                -2.5f) == 0,
          "set param vec2 入队");
    DrainAfter(s, 5);

    int32_t n_params = -1;
    Check(cq_session_clip_effect_param_count(s, clip_id, "cq.effect.blur", &n_params) == 0 &&
              n_params == 5,
          "参数计数 == 5（五类各一）");
    Check(cq_session_query_clip_effect_params(s, clip_id, "cq.effect.blur", NULL, 0,
                                              &n_params) == 0 && n_params == 5,
          "参数两段式：out=NULL 返回总数 5");

    CQEffectParamInfo params[8];
    n_params = -1;
    Check(cq_session_query_clip_effect_params(s, clip_id, "cq.effect.blur", params, 8,
                                              &n_params) == 0 && n_params == 5,
          "query 参数写入 5 条");
    {
        /* map 有序 ⇒ 输出按 key 升序：hi_pass, opacity, preset, scale, tint */
        int seen_float = 0, seen_i64 = 0, seen_bool = 0, seen_color = 0, seen_vec2 = 0;
        for (int32_t i = 0; i < n_params; ++i) {
            const CQEffectParamInfo* p = &params[i];
            if (strcmp(p->key, "opacity") == 0 && p->type == 1 && p->v[0] == 0.5f) seen_float = 1;
            if (strcmp(p->key, "preset") == 0 && p->type == 0 && p->i == 3) seen_i64 = 1;
            if (strcmp(p->key, "hi_pass") == 0 && p->type == 2 && p->b == 1) seen_bool = 1;
            if (strcmp(p->key, "tint") == 0 && p->type == 3 && p->v[0] == 0.1f &&
                p->v[1] == 0.2f && p->v[2] == 0.3f && p->v[3] == 0.4f)
                seen_color = 1;
            if (strcmp(p->key, "scale") == 0 && p->type == 4 && p->v[0] == 1.5f &&
                p->v[1] == -2.5f)
                seen_vec2 = 1;
            Check(p->truncated == 0, "参数 key 未截断");
        }
        Check(seen_float, "float 参数读回：type=1, v[0]=0.5");
        Check(seen_i64, "i64 参数读回：type=0, i=3");
        Check(seen_bool, "bool 参数读回：type=2, b=1");
        Check(seen_color, "color 参数读回：type=3, 四分量一致");
        Check(seen_vec2, "vec2 参数读回：type=4, 两分量一致");
    }

    /* ---- digest 真断言：改参数 → 指纹变 ---- */
    uint64_t digest_before = cq_session_current_snapshot(s).digest;
    Check(cq_session_set_clip_effect_param_float(s, clip_id, "cq.effect.blur", "opacity",
                                                 0.7f) == 0,
          "改 opacity 0.5 → 0.7 入队");
    DrainAfter(s, 1);
    Check(cq_session_current_snapshot(s).digest != digest_before,
          "改参数 → 快照 digest 变（端到端证明指纹字段覆盖）");

    /* ---- 启用开关 ---- */
    Check(cq_session_set_clip_effect_enabled(s, clip_id, "cq.effect.blur", 0) == 0,
          "set_enabled(0) 入队");
    DrainAfter(s, 1);
    Check(cq_session_query_clip_effects(s, clip_id, effects, 4, &n_effects) == 0 &&
              n_effects == 1 && effects[0].enabled == 0,
          "查询反映启用位 = 0");
    Check(cq_session_set_clip_effect_enabled(s, clip_id, "cq.effect.blur", 1) == 0,
          "set_enabled(1) 入队");
    DrainAfter(s, 1);
    Check(cq_session_query_clip_effects(s, clip_id, effects, 4, &n_effects) == 0 &&
              effects[0].enabled == 1,
          "再启用后查询反映启用位 = 1");

    /* ---- 失败语义（异步提交被拒：版本只推进哨兵）---- */
    uint64_t ver_before = cq_session_current_snapshot(s).version;
    Check(cq_session_add_clip_effect(s, clip_id, "cq.effect.blur", "重复 id") == 0,
          "重复 effect_id 仍入队（校验在 session 线程）");
    DrainAfter(s, 0);
    Check(cq_session_current_snapshot(s).version == ver_before + 1,
          "重复 effect_id 被拒：版本只推进哨兵");
    n_effects = -1;
    Check(cq_session_clip_effect_count(s, clip_id, &n_effects) == 0 && n_effects == 1,
          "重复被拒后仍只有 1 个效果");

    ver_before = cq_session_current_snapshot(s).version;
    Check(cq_session_set_clip_effect_param_float(s, clip_id, "no.such.effect", "k", 1.0f) == 0,
          "不存在的效果设参仍入队");
    DrainAfter(s, 0);
    Check(cq_session_current_snapshot(s).version == ver_before + 1,
          "效果不存在设参被拒：版本只推进哨兵");

    ver_before = cq_session_current_snapshot(s).version;
    Check(cq_session_add_clip_effect(s, 99999, "cq.effect.x", "X") == 0, "不存在的 clip 挂效果仍入队");
    DrainAfter(s, 0);
    Check(cq_session_current_snapshot(s).version == ver_before + 1,
          "clip 不存在挂效果被拒：版本只推进哨兵");

    /* ---- 撤销链：remove → undo（整栈还原）→ redo ---- */
    Check(cq_session_remove_clip_effect(s, clip_id, "cq.effect.blur") == 0, "remove_clip_effect 入队");
    DrainAfter(s, 1);
    n_effects = -1;
    Check(cq_session_clip_effect_count(s, clip_id, &n_effects) == 0 && n_effects == 0,
          "remove 后效果计数 == 0");

    Check(cq_session_undo(s) == 0, "undo remove 入队");
    DrainAfter(s, 1);
    n_effects = -1;
    Check(cq_session_clip_effect_count(s, clip_id, &n_effects) == 0 && n_effects == 1,
          "undo remove：效果回来");
    n_params = -1;
    Check(cq_session_query_clip_effect_params(s, clip_id, "cq.effect.blur", params, 8,
                                              &n_params) == 0 && n_params == 5,
          "undo remove：5 个参数全部还原（整栈快照，不是空壳）");
    {
        int opacity_ok = 0;
        for (int32_t i = 0; i < n_params; ++i) {
            if (strcmp(params[i].key, "opacity") == 0 && params[i].v[0] == 0.7f) opacity_ok = 1;
        }
        Check(opacity_ok, "undo remove：opacity 仍是 0.7（撤销前最后改的值）");
    }

    Check(cq_session_redo(s) == 0, "redo remove 入队");
    DrainAfter(s, 1);
    n_effects = -1;
    Check(cq_session_clip_effect_count(s, clip_id, &n_effects) == 0 && n_effects == 0,
          "redo remove：效果再消失");

    /* ---- 参数命令逐层 undo ----
     * 当前 undo 栈（底→顶）：register_asset, add_track, add_clip,
     * add_clip_effect, 5×param, opacity 0.7, enabled 0, enabled 1, remove
     * （remove 已被 undo+redo 消耗回栈顶）—— 共 13 条。
     * pop 10 条即回到 add_clip_effect 之前：效果与全部参数一起消失。 */
    for (int i = 0; i < 10; ++i) {
        Check(cq_session_undo(s) == 0, "逐层 undo 入队");
        DrainAfter(s, 1);
    }
    n_effects = -1;
    Check(cq_session_clip_effect_count(s, clip_id, &n_effects) == 0 && n_effects == 0,
          "逐层 undo 到 add 之前：效果消失");
    Check(cq_session_can_undo(s) == 1, "仍有更早的历史（add_clip 本身）");
    Check(cq_session_can_redo(s) == 1, "undo 后可 redo");

    /* ---- 同步参数校验（调用侧，不等 session 线程）---- */
    Check(cq_session_add_clip_effect(NULL, clip_id, "e", "E") == 7000, "NULL session add → 7000");
    Check(cq_session_add_clip_effect(s, clip_id, NULL, "E") == 7000, "NULL effect_id → 7000");
    Check(cq_session_add_clip_effect(s, clip_id, "e", NULL) == 7000, "NULL effect_name → 7000");
    Check(cq_session_remove_clip_effect(NULL, clip_id, "e") == 7000, "NULL session remove → 7000");
    Check(cq_session_set_clip_effect_param_float(NULL, clip_id, "e", "k", 1.0f) == 7000,
          "NULL session set param → 7000");
    Check(cq_session_set_clip_effect_param_float(s, clip_id, "e", NULL, 1.0f) == 7000,
          "NULL key → 7000");
    Check(cq_session_set_clip_effect_enabled(NULL, clip_id, "e", 1) == 7000,
          "NULL session set_enabled → 7000");
    Check(cq_session_clip_effect_count(NULL, clip_id, &n_effects) == 7000,
          "NULL session count → 7000");
    Check(cq_session_clip_effect_count(s, clip_id, NULL) == 7000, "NULL out_count → 7000");
    Check(cq_session_query_clip_effects(s, clip_id, effects, 0, &n_effects) == 7000,
          "capacity=0 且 out 非 NULL → 7000");
    Check(cq_session_query_clip_effect_params(s, clip_id, "e", params, 8, NULL) == 7000,
          "NULL out_count（params）→ 7000");
    Check(cq_session_clip_effect_param_count(s, clip_id, "no.such.effect", &n_params) == 1001,
          "效果不存在的参数计数 → 1001 (kIoNotFound)");

    cq_session_destroy(s);

    printf("\n== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
