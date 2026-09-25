#ifndef CQ_SDK_H
#define CQ_SDK_H

/* ChuanqiCut — 对外 C ABI 伞形头（INFRA-001 占位）。
 *
 * 本文件由 INFRA-001 建立为占位骨架，真实 API 由后续 CORE 系列任务填充。
 * 红线约束（AGENTS.root.md #7）：公共头只允许 C 类型 + opaque 句柄，
 * 禁止第三方类型、禁止平台类型。跨层一律走 opaque 句柄（如 CQSession）。
 */

#ifdef __cplusplus
extern "C" {
#endif

/* 占位 opaque 句柄：真实定义由后续任务给出。仅用于演示 ABI 边界。 */
typedef struct CQSession CQSession;

/* 占位版本查询声明（真实实现见后续任务）：
 *   int cq_version_major(void);
 *   int cq_version_minor(void);
 */

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CQ_SDK_H */
