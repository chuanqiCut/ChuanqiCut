/* ChuanqiCut — C ABI 验证（BIND-001）
 *
 * ⚠️ 本文件是**真正的 C 语言**翻译单元（.c，由 C 编译器编译），不是 C++。
 *
 * 存在的唯一理由：机器校验 core/include/cq/cq_sdk.h 确实是「零 C++ 类型」。
 * 只要那个头文件里混进任何 C++ 东西（std::* / class / 引用 / 模板 ...），
 * 本 TU 就会编译失败。这比"评审时看一眼"可靠得多。
 *
 * 顺带验证 C ABI 的端到端行为：创建会话 → 提交变更 → 版本递增 → 变更日志 → 销毁。
 */

#include <stdio.h>
#include <unistd.h>

#include "cq/cq_sdk.h"

static int g_failures = 0;
static int g_checks = 0;

static void Check(int cond, const char* msg) {
    ++g_checks;
    if (!cond) {
        ++g_failures;
        printf("  FAIL: %s\n", msg);
    }
}

/* 成功变更 */
static int32_t OkMutate(void* ctx) {
    (void)ctx;
    return 0;
}

/* 失败变更 */
static int32_t FailMutate(void* ctx) {
    (void)ctx;
    return 7000; /* kInvalidArgument */
}

/* 观察者：把收到的版本写回调用方给的 int* */
static void ObserverFn(CQSnapshot snap, void* ctx) {
    int* sink = (int*)ctx;
    if (sink != NULL) {
        *sink = (int)snap.version;
    }
}

static void WaitVersion(const CQSession* s, uint64_t target) {
    int waited = 0;
    while (cq_session_current_snapshot(s).version < target && waited < 5000) {
        usleep(1000);
        ++waited;
    }
}

int main(void) {
    printf("[test] 版本与状态码\n");
    /* 版本：头文件不硬编码，由 CMake 注入，这里只验证可取到且合理 */
    Check(cq_version_major() >= 0, "major 可取");
    Check(cq_version_minor() >= 0, "minor 可取");
    Check(cq_version_patch() >= 0, "patch 可取");

    Check(cq_status_is_ok(0) == 1, "0 是成功");
    Check(cq_status_is_ok(1000) == 0, "1000 不是成功");
    Check(cq_status_is_error(1000) == 1, "1000 是错误");
    Check(cq_status_is_error(6000) == 0, "6000(取消) 不算错误");
    Check(cq_status_is_cancelled(6000) == 1, "6000 是取消");
    Check(cq_status_to_string(0) != NULL, "状态码文本非空");

    printf("[test] 线程角色\n");
    Check(cq_is_main_thread() == 0, "未标记时 is_main_thread 为 0（不猜）");
    cq_mark_main_thread();
    Check(cq_is_main_thread() == 1, "标记后 is_main_thread 为 1");

    printf("[test] 能力查询（未安装后端 -> no）\n");
    Check(cq_query_capability(0) == 0, "未安装后端时返回 0（安全默认，不谎报）");

    printf("[test] 会话端到端\n");
    CQSession* s = cq_session_create();
    Check(s != NULL, "create 成功");
    if (s == NULL) {
        printf("\nFAILED: %d checks, %d failures\n", g_checks, g_failures);
        return 1;
    }

    Check(cq_session_current_snapshot(s).version == 0, "初始版本 0");

    Check(cq_session_submit(s, "c1", OkMutate, NULL) == 0, "submit 返回 0");
    WaitVersion(s, 1);
    Check(cq_session_current_snapshot(s).version == 1, "成功变更后版本为 1");
    Check(cq_session_change_count(s) == 1, "变更记录数为 1");

    /* D2：失败不推进版本 */
    cq_session_submit(s, "bad", FailMutate, NULL);
    usleep(50000);
    Check(cq_session_current_snapshot(s).version == 1, "失败变更后版本仍为 1");
    Check(cq_session_change_count(s) == 1, "失败变更不计入日志");

    /* 变更日志（UI 可 diff） */
    CQChangeRecord recs[8];
    int32_t n = cq_session_changes_since(s, 0, recs, 8);
    Check(n == 1, "changes_since 返回 1 条");
    Check(recs[0].version == 1, "记录版本为 1");
    Check(recs[0].name != NULL, "记录带名字");
    Check(cq_session_changes_since(s, 1, recs, 8) == 0, "从最新版本之后无变更");

    /* 观察者（在 session 线程回调） */
    int observed = -1;
    cq_session_set_observer(s, ObserverFn, &observed);
    cq_session_submit(s, "c2", OkMutate, NULL);
    {
        int waited = 0;
        while (observed < 0 && waited < 5000) {
            usleep(1000);
            ++waited;
        }
    }
    Check(observed == 2, "观察者收到递增后的版本 2");

    /* 空指针安全 */
    Check(cq_session_submit(NULL, "x", OkMutate, NULL) != 0, "session 为 NULL 时 submit 报错");
    Check(cq_session_change_count(NULL) == 0, "session 为 NULL 时 change_count 为 0");

    cq_session_destroy(s);
    cq_session_destroy(NULL); /* 幂等 */
    Check(1, "destroy(NULL) 安全");

    printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED", g_checks,
           g_failures);
    return g_failures == 0 ? 0 : 1;
}
