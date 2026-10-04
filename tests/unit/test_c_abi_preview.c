/* ChuanqiCut — 预览 C ABI 验收（BIND-003 子步骤 5）
 *
 * 本文件是**真正的 C 翻译单元**（不是 C++）。存在的理由与 test_c_abi.c 一致：
 * 只要公共头 cq/cq_sdk.h 混进任何 C++ 类型，这个 TU 就编译失败 —— 人眼审查
 * 「这是不是纯 C」不可靠，靠编译器守。
 *
 * 与 test_preview_renderer.cpp 的分工：
 *   * 本用例   —— 证明 **C ABI 契约**可用且语义正确（句柄/状态码/诊断量）
 *   * C++ 用例 —— 证明 **画面像素**正确（读回断言，用到 Apple 内部辅助，C 侧做不到）
 * 像素正确性已有 C++ 用例覆盖，这里不重复；但「取到的是不是 t 时刻那一帧」
 * 必须在这里也能查（静态彩条像素相同，故靠 last_frame_pts）。
 */

#include <stdio.h>
#include <time.h> /* nanosleep：等泵渲染完（真实链路，用挂钟步进而不是忙等） */

#include "cq/cq_sdk.h"

#ifndef CQ_SOURCE_DIR
#define CQ_SOURCE_DIR "."
#endif

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

/* 项目网格（ADR-0009），与内核 kProjectTimeScale 一致。 */
#define TS 120000

int main(void) {
    const char* path = CQ_SOURCE_DIR "/tests/golden/frames/gf_1080p_h264.mp4";
    void* tex = NULL;
    int32_t rc = 0;
    int64_t pts = 0;
    int32_t pts_ts = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("== ChuanqiCut 预览 C ABI 验收（真正的 C 翻译单元）==\n");
    printf("样本: %s\n", path);

    /* ---- 状态码助手（先自查，后面全靠它判读返回值）---- */
    Check(cq_status_is_ok(0) == 1, "cq_status_is_ok(0)");
    Check(cq_status_is_error(1001) == 1, "cq_status_is_error(1001=kIoNotFound)");
    Check(cq_status_is_cancelled(6000) == 1, "cq_status_is_cancelled(6000)");
    Check(cq_status_to_string(1001) != NULL, "cq_status_to_string 返回非空静态串");

    /* ---- 装配会话模型（UIA-009 子步骤 2：预览挂 session，模型真源在 session）---- */
    CQSession* session = cq_session_create();
    Check(session != NULL, "cq_session_create");
    Check(cq_session_register_asset(session, 1, path) == 0, "register_asset 入队");
    Check(cq_session_add_track(session, 0) == 0, "add_track 入队");
    /* 提交异步：轮询版本等 add_track 生效，查询真实轨道 id */
    for (int i = 0; i < 5000 && cq_session_current_snapshot(session).version < 2; ++i) {
        for (volatile int j = 0; j < 20000; ++j) {
        }
    }
    CQTrackInfo tracks[4];
    int32_t n_tracks = 0;
    Check(cq_session_query_tracks(session, tracks, 4, &n_tracks) == 0 && n_tracks == 1,
          "轨道已生效");
    Check(cq_session_add_clip(session, tracks[0].track_id, 1,
                              0, TS, 3 * TS, TS, 0, TS) == 0, "add_clip 入队");
    for (int i = 0; i < 5000 && cq_session_current_snapshot(session).version < 3; ++i) {
        for (volatile int j = 0; j < 20000; ++j) {
        }
    }

    /* ---- 创建 ---- */
    CQPreview* p = cq_preview_create(session, 256, 256);
    Check(p != NULL, "cq_preview_create(session,256,256) 返回非 NULL（PAL 后端齐备）");
    Check(cq_preview_create(NULL, 256, 256) == NULL,
          "cq_preview_create(NULL,...) 返回 NULL");
    Check(cq_preview_create(session, 0, 0) == NULL, "cq_preview_create(0,0) 返回 NULL（尺寸非法）");
    if (p == NULL) {
        printf("\n无法创建预览器（PAL 后端缺失），用例终止。\n");
        return 1;
    }

    /* （素材与片段已改经 session 装配 —— 见 create 之前。
     *  add_clip 的 timescale 校验属 cq_session_add_clip，在 c_abi_session 用例。） */

    /* ---- 渲染 t = 0.5s ---- */
    tex = NULL;
    rc = cq_preview_render_frame(p, 60000, TS, &tex);
    printf("  render_frame(0.5s) -> %d, texture=%s\n", rc, tex ? "non-null" : "NULL");
    Check(rc == 0, "render_frame(0.5s) 返回 0");
    Check(tex != NULL, "导出平台纹理句柄非空（中性句柄，Swift 侧 reinterpret）");
    Check(cq_preview_last_hit_clip(p) == 1, "last_hit_clip == 1");
    Check(cq_preview_last_cpu_fallback(p) == 0, "last_cpu_fallback == 0（零拷贝成立）");
    Check(cq_preview_last_frame_pts(p, &pts, &pts_ts) == 0, "last_frame_pts 可取回");
    printf("  实际帧 pts = %lld / %d\n", (long long)pts, pts_ts);
    Check(pts_ts == TS, "帧 pts 的 timescale == 项目网格 120000");
    Check(pts >= 60000 - 4800 && pts <= 60000 + 4800, "帧 pts ≈ 0.5s（不是复用同一帧）");

    /* ---- 渲染 t = 1.0s：帧必须随之推进 ---- */
    tex = NULL;
    rc = cq_preview_render_frame(p, 120000, TS, &tex);
    Check(rc == 0, "render_frame(1.0s) 返回 0");
    {
        int64_t pts2 = 0;
        int32_t ts2 = 0;
        cq_preview_last_frame_pts(p, &pts2, &ts2);
        printf("  实际帧 pts = %lld / %d\n", (long long)pts2, ts2);
        Check(pts2 >= 120000 - 4800 && pts2 <= 120000 + 4800, "帧 pts ≈ 1.0s");
        Check(pts2 != pts, "帧 pts 与 0.5s 那次不同（时间真的推进了）");
    }

    /* ---- 空隙：t = 5s 超出片段 ---- */
    tex = NULL;
    rc = cq_preview_render_frame(p, 600000, TS, &tex);
    printf("  render_frame(5.0s) -> %d\n", rc);
    Check(rc == 1001, "空隙返回 kIoNotFound(1001)（不伪造成功）");
    Check(cq_preview_last_hit_clip(p) == 0, "空隙时 last_hit_clip == 0");
    Check(tex != NULL, "空隙时仍返回可用的目标纹理（已清屏为黑）");

    /* ---- 片段引用未注册素材（独立 session：不注册素材直接建片段）---- */
    {
        CQSession* s2 = cq_session_create();
        Check(s2 != NULL, "第二个 session 创建成功");
        Check(cq_session_add_track(s2, 0) == 0, "s2 add_track 入队");
        for (int i = 0; i < 5000 && cq_session_current_snapshot(s2).version < 1; ++i) {
            for (volatile int j = 0; j < 20000; ++j) {
            }
        }
        CQTrackInfo t2info[4];
        int32_t n2 = 0;
        cq_session_query_tracks(s2, t2info, 4, &n2);
        Check(cq_session_add_clip(s2, t2info[0].track_id, 999,
                                  0, TS, 3 * TS, TS, 0, TS) == 0,
              "s2 add_clip 引用未注册素材（允许提交，注册是独立动作）");
        for (int i = 0; i < 5000 && cq_session_current_snapshot(s2).version < 2; ++i) {
            for (volatile int j = 0; j < 20000; ++j) {
            }
        }
        CQPreview* q = cq_preview_create(s2, 128, 128);
        Check(q != NULL, "第二个预览器创建成功");
        if (q != NULL) {
            void* t2 = NULL;
            rc = cq_preview_render_frame(q, 60000, TS, &t2);
            printf("  render_frame(asset_id=999) -> %d\n", rc);
            Check(rc == 7000, "未注册素材渲染返回 kInvalidArgument(7000)");
            cq_preview_destroy(q);
        }
        cq_session_destroy(s2);
    }

    /* ---- Resize ---- */
    rc = cq_preview_resize(p, 128, 128);
    Check(rc == 0, "cq_preview_resize(128,128) 返回 0");
    tex = NULL;
    rc = cq_preview_render_frame(p, 120000, TS, &tex);
    Check(rc == 0, "Resize 后 render_frame 仍成功");
    Check(rc == 0 && cq_preview_last_hit_clip(p) == 1, "Resize 后仍命中片段");

    /* ---- 耗时埋点（UIA-010 子步骤 5：预览帧率的所有讨论都要有实测数字）---- */
    {
        int64_t acq = 0;
        int64_t imp = 0;
        int64_t drw = 0;
        int64_t tot = 0;
        Check(cq_preview_last_timings(p, &acq, &imp, &drw, &tot) == 0, "last_timings 可取回");
        printf("  上一帧耗时(ns): acquire=%lld import=%lld draw=%lld total=%lld\n",
               (long long)acq, (long long)imp, (long long)drw, (long long)tot);
        Check(tot > 0, "total_ns > 0（埋点真的在计时）");
        Check(acq > 0, "acquire_ns > 0（取帧段被计时）");
        Check(tot >= acq + imp + drw, "total >= 各段之和（段耗时不越界）");
        Check(cq_preview_last_timings(NULL, &acq, &imp, &drw, &tot) == 7000,
              "last_timings(NULL) 返回 7000");
    }

    /* ---- 共享命令队列（跨队列顺序的前提，见 cq_sdk.h 的泵注释）---- */
    Check(cq_preview_shared_queue(p) != NULL, "cq_preview_shared_queue 返回非空句柄");
    Check(cq_preview_shared_queue(NULL) == NULL, "shared_queue(NULL) 返回 NULL");

    /* ---- 取帧泵（UIA-010 子步骤 5）----
     * ⚠️ 本段之后就不再直接调 cq_preview_render_frame / cq_preview_resize：
     *    挂上泵后渲染只在泵线程发生，主线程再调是数据竞争。 */
    {
        struct timespec step;
        uint64_t seq = 0;
        void* ptex = NULL;
        int64_t ppts = 0;
        int32_t ppts_ts = 0;
        step.tv_sec = 0;
        step.tv_nsec = 2 * 1000 * 1000; /* 2ms */

        /* 参数防御：NULL 一律 7000，不静默成功 */
        Check(cq_preview_pump_request(NULL, 60000, TS) == 7000, "pump_request(NULL) 返回 7000");
        Check(cq_preview_pump_lock(NULL, &ptex, &ppts, &ppts_ts, &seq) == 7000,
              "pump_lock(NULL) 返回 7000");
        Check(cq_preview_pump_unlock(NULL) == 7000, "pump_unlock(NULL) 返回 7000");
        Check(cq_preview_pump_stats(NULL, NULL, NULL, NULL, NULL) == 7000,
              "pump_stats(NULL) 返回 7000");
        Check(cq_preview_pump_stop(NULL) == 7000, "pump_stop(NULL) 返回 7000");
        Check(cq_preview_pump_start(NULL) == 7000, "pump_start(NULL) 返回 7000");
        Check(cq_preview_pump_request_resize(NULL, 64, 64) == 7000,
              "pump_request_resize(NULL) 返回 7000");
        Check(cq_preview_pump_create(NULL) == NULL, "pump_create(NULL) 返回 NULL");

        CQPreviewPump* pump = cq_preview_pump_create(p);
        Check(pump != NULL, "cq_preview_pump_create（创建即启动）");
        if (pump != NULL) {
            Check(cq_preview_pump_lock(pump, &ptex, &ppts, &ppts_ts, &seq) == 0,
                  "pump_lock 返回 0");
            Check(seq == 0 && ptex == NULL, "尚无帧时 seq==0 且句柄为 NULL（不伪造）");
            Check(cq_preview_pump_unlock(pump) == 0, "pump_unlock 返回 0");

            Check(cq_preview_pump_request(pump, 60000, TS) == 0, "pump_request(0.5s)");
            Check(cq_preview_pump_request(pump, 60000, 0) == 7000,
                  "pump_request timescale=0 返回 7000");

            /* 等泵渲染完（真实解码，给 5s 上限） */
            for (int i = 0; i < 2500 && seq == 0; ++i) {
                nanosleep(&step, NULL);
                cq_preview_pump_lock(pump, &ptex, &ppts, &ppts_ts, &seq);
                cq_preview_pump_unlock(pump);
            }
            Check(seq != 0, "泵渲染出了帧（seq 前进）");
            Check(ptex != NULL, "泵发布的纹理句柄非空");
            Check(ppts == 60000 && ppts_ts == TS, "泵发布的 pts == 请求的 0.5s");
            Check(cq_preview_last_hit_clip(p) == 1, "泵路径仍命中片段");
            Check(cq_preview_last_cpu_fallback(p) == 0, "泵路径零拷贝仍成立（无静默降级）");

            {
                uint64_t req = 0;
                uint64_t ren = 0;
                uint64_t coa = 0;
                uint64_t nok = 0;
                Check(cq_preview_pump_stats(pump, &req, &ren, &coa, &nok) == 0, "stats 可取回");
                printf("  pump stats: requested=%llu rendered=%llu coalesced=%llu non_ok=%llu\n",
                       (unsigned long long)req, (unsigned long long)ren,
                       (unsigned long long)coa, (unsigned long long)nok);
                Check(req >= 1 && ren >= 1, "requested/rendered 均 >= 1");
            }

            /* resize 走泵（RT 只能由持有它的线程销毁）→ 旧句柄必须作废 */
            {
                uint64_t seq_before = seq;
                Check(cq_preview_pump_request_resize(pump, 128, 128) == 0,
                      "pump_request_resize(128,128)");
                Check(cq_preview_pump_request_resize(pump, 0, 0) == 7000,
                      "pump_request_resize(0,0) 返回 7000");
                for (int i = 0; i < 2500 && seq <= seq_before; ++i) {
                    nanosleep(&step, NULL);
                    cq_preview_pump_lock(pump, &ptex, &ppts, &ppts_ts, &seq);
                    cq_preview_pump_unlock(pump);
                }
                Check(seq > seq_before, "resize 后 seq 前进");
                Check(ptex == NULL, "resize 后旧句柄作废（texture == NULL）");
            }

            Check(cq_preview_pump_stop(pump) == 0, "pump_stop");
            Check(cq_preview_pump_start(pump) == 0, "pump_start（可重启）");
            /* 生命周期：泵必须先于 preview 销毁（持有指向渲染器的非拥有指针）。 */
            cq_preview_pump_destroy(pump);
        }
        cq_preview_pump_destroy(NULL); /* 幂等，不得崩 */
        Check(1, "pump_destroy(NULL) 幂等不崩");
    }

    /* ---- 参数防御 & 幂等释放 ---- */
    Check(cq_preview_render_frame(p, 60000, 0, &tex) == 7000, "timescale=0 返回 7000");
    Check(cq_preview_render_frame(NULL, 60000, TS, &tex) == 7000, "preview=NULL 返回 7000");
    cq_preview_destroy(p);
    cq_preview_destroy(NULL); /* 幂等，不得崩 */
    Check(1, "destroy(NULL) 幂等不崩");

    /* 生命周期：preview 必须先于 session 销毁（CQPreview 不拥有 session）。 */
    cq_session_destroy(session);

    printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
