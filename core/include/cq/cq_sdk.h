#ifndef CQ_SDK_H
#define CQ_SDK_H

/* ChuanqiCut — 对外 C ABI（BIND-001 冻结）
 *
 * 这是 SDK 的**唯一对外边界**：Swift / Kotlin / ArkTS 通过本文件调用内核。
 *
 * 红线约束（AGENTS.root.md）：
 *   #7 公共头只有 **C 类型 + opaque 句柄**。禁止 C++ 类型、禁止第三方类型、
 *      禁止平台类型（CVPixelBuffer / jobject / MTLTexture ... 一个都不许出现）。
 *   #3 能力必须**运行时查询**，不得编译期推断 —— 一律走 cq_query_capability()。
 *
 * 为什么这份约束要靠机器守住：
 *   人眼审查"这是不是纯 C"不可靠。tests/unit/test_c_abi.c 是一个**真正的 C 语言**
 *   翻译单元，只要本文件混进任何 C++ 类型，那个 TU 就编译失败。
 *
 * 线程约定（重要，接错就出 bug）：
 *   - cq_mark_main_thread() 必须在 App 的 UI 线程调用一次，否则内核无从得知
 *     哪根是主线程，「主线程零阻塞」的守卫会失效（见 CORE-008）。
 *   - 观察者回调（CQSnapshotObserver）在 **session 线程**执行，不是主线程。
 *     Swift 侧必须自行 dispatch 到 main queue 再更新 UI。
 *
 * 内核不使用异常（ARCH-001），错误一律通过状态码返回；本文件不抛任何东西。
 */

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ==========================================================================
 * 版本
 * ==========================================================================
 * 数值由构建系统（CMake project VERSION）注入，头文件**不**硬编码 ——
 * 否则会出现"头文件写 0.1、CMake 已是 0.2"的漂移。
 */
int32_t cq_version_major(void);
int32_t cq_version_minor(void);
int32_t cq_version_patch(void);

/* ==========================================================================
 * 状态码
 * ==========================================================================
 * 码值与内核 StatusCode **同构且稳定**（CORE-002 已固化数值区间）。
 * 这里**不**复制一份 C 枚举 —— 复制必然漂移（见任务卡 D3）。
 *
 * 约定：0 = 成功；6000 = 取消（非错误）；其余非 0 为错误。
 */
int32_t cq_status_is_ok(int32_t code);
int32_t cq_status_is_error(int32_t code);
int32_t cq_status_is_cancelled(int32_t code);

/* 返回码值对应的人类可读文本（静态存储，调用方不得释放、不得写）。
 * 仅用于日志与 UI 展示，禁止进入计算/比较路径。 */
const char* cq_status_to_string(int32_t code);

/* ==========================================================================
 * 线程角色
 * ==========================================================================
 * 宿主必须在 UI 线程调用一次 cq_mark_main_thread()。
 * 未标记时 cq_is_main_thread() 恒为 0（内核默认 kUnknown，不猜）。
 */
void cq_mark_main_thread(void);
int32_t cq_is_main_thread(void);

/* ==========================================================================
 * 能力查询（红线 #3 的执行入口）
 * ==========================================================================
 * capability 取值见内核 Capability 枚举（0..15）。
 * 返回 0=no / 1=yes / 2=degraded。
 *
 * ⚠️ 未安装平台后端时一律返回 0（no）—— 这是**安全默认**：
 *    上层据此走降级路径；若谎报 yes，上层会去调用不存在的能力并崩溃。
 */
int32_t cq_query_capability(int32_t capability);

/* ==========================================================================
 * 会话（EditorSession 的 C ABI 句柄）
 * ==========================================================================
 * ARCH-001 §4.1：session = 「串起各模块，对外唯一门面」。
 */

/* opaque 句柄：真实定义不对外暴露。 */
typedef struct CQSession CQSession;

/* 创建并启动会话；失败返回 NULL。
 * 不单独提供 start/shutdown：少一层状态，调用方不会忘（任务卡 D6）。 */
CQSession* cq_session_create(void);

/* 停止并释放；传 NULL 安全（幂等）。 */
void cq_session_destroy(CQSession* session);

/* 变更体：在 **session 线程** 内被调用。
 *   返回 0     —— 成功，快照版本推进
 *   返回非 0   —— 失败或取消，版本**不推进**、不记入变更日志
 * ctx 由调用方提供，内核原样透传、不接管其所有权。 */
typedef int32_t (*CQMutateFn)(void* ctx);

/* 提交变更。**不阻塞**调用线程：
 *   返回 0     —— 已入队
 *   返回 5000  —— 队列满（背压，调用方应降速或重试；内核不内置重试）
 *   返回 7000  —— session 无效
 * change_name 须指向**静态存储**（内核只存指针，不拷贝）。 */
int32_t cq_session_submit(CQSession* session, const char* change_name, CQMutateFn mutate,
                          void* ctx);

/* 快照。任意线程可调。 */
typedef struct CQSnapshot {
    uint64_t version; /* 单调递增；0 = 尚无变更 */
    uint64_t digest;  /* 状态摘要。**当前恒为 0**：模型层（MODEL-001）未接入 */
} CQSnapshot;

CQSnapshot cq_session_current_snapshot(const CQSession* session);

/* 变更日志（UI 可据此增量刷新）。
 * name 指向**静态存储**，调用方不得在其生命周期之外使用。
 * 返回实际写入 out 的条数（按 version 升序）；out 为 NULL 时返回 0。 */
typedef struct CQChangeRecord {
    uint64_t version;
    const char* name;
} CQChangeRecord;

int32_t cq_session_changes_since(const CQSession* session, uint64_t from_version,
                                 CQChangeRecord* out, int32_t capacity);
int32_t cq_session_change_count(const CQSession* session);

/* 快照变更观察者。
 * ⚠️ 回调在 **session 线程** 执行 —— 调用方须自行转发到 UI 线程。 */
typedef void (*CQSnapshotObserver)(CQSnapshot snapshot, void* ctx);

void cq_session_set_observer(CQSession* session, CQSnapshotObserver observer, void* ctx);

/* ==========================================================================
 * 预览（BIND-003）
 * ==========================================================================
 * CQPreview = 「时间线 + 素材表 + 取帧 + 渲染」的会话级预览器。
 * 典型用法：create → register_asset(若干) → add_clip(若干) → 每帧 render_frame。
 *
 * 时间一律 RationalTime{value, timescale}（红线 #4，禁止浮点秒）。
 * 本项目网格 timescale = 120000（ADR-0009）。
 *
 * ⚠️ 平台能力依赖：预览需要 PAL 的图形设备 / 全屏拷贝 pass / 帧提供器三项后端。
 *    缺失任一后端时 cq_preview_create 返回 NULL —— 这是**运行时**失败，上层据此
 *    走「预览不可用」路径。**不要**用编译期宏判断平台能力（红线 #3）。
 */

typedef struct CQPreview CQPreview;

/* 创建预览器。width/height 为离屏渲染目标尺寸；失败返回 NULL。
 * 注意：当前为「拉伸铺满」，不做宽高比适配（letterbox 待 UI 需求明确后加）。 */
CQPreview* cq_preview_create(uint32_t width, uint32_t height);

/* 释放；传 NULL 安全（幂等）。 */
void cq_preview_destroy(CQPreview* preview);

/* 注册素材（asset_id → 文件路径）。path 会被**拷贝**进内核，调用方可立即释放。
 * 重复注册同一 id 会整体替换。 */
int32_t cq_preview_register_asset(CQPreview* preview, uint64_t asset_id, const char* path);

/* 添加片段到视频轨。
 *   track_id  —— 轨道 id；不存在时**自动创建**一条视频轨
 *   asset_id  —— 必须先 register_asset
 *   start     —— 时间线起点
 *   duration  —— 时间线占时
 *   source_in —— 素材内入点
 * 同轨片段不得重叠（MODEL-001 语义），重叠返回 kInvalidArgument(7000)。
 *
 * ⚠️ 本期**只渲染第一条命中的视频轨** —— 多轨叠加/转场合成要等 RenderGraph
 *    （RENDER-001）落地。这里不假装支持多轨合成。 */
int32_t cq_preview_add_clip(CQPreview* preview, uint64_t track_id, uint64_t asset_id,
                            int64_t start_value, int32_t start_timescale,
                            int64_t duration_value, int32_t duration_timescale,
                            int64_t source_in_value, int32_t source_in_timescale);

/* 渲染 pts 处一帧到离屏目标，out_texture 返回**可显示的平台纹理句柄**
 * （中性句柄：iOS/macOS 上 reinterpret 为 id<MTLTexture>）。
 *
 * ⚠️ 绝不要在 Swift 侧「读回像素再上传」—— 每帧一次 CPU 往返会直接毁掉预览帧率。
 *
 * 返回：
 *   0     —— 成功
 *   1001  —— kIoNotFound：pts 处是空隙（无片段覆盖），已清屏为黑，out_texture 仍有效
 *   7000  —— kInvalidArgument：素材未注册 / 时间参数非法
 *   其它  —— 解码 / 导入 / 渲染失败原样透传
 *
 * out_texture 在下次 render_frame 或 resize 之前保持有效。 */
int32_t cq_preview_render_frame(CQPreview* preview, int64_t pts_value, int32_t pts_timescale,
                                void** out_texture);

/* 改变离屏目标尺寸。会丢弃当前目标纹理（此前返回的 out_texture 失效）。 */
int32_t cq_preview_resize(CQPreview* preview, uint32_t width, uint32_t height);

/* ---- 诊断量（不是渲染结果，供日志/埋点与自测使用）----
 * 静态素材（如彩条）的像素相同，无法区分「取到了 t 时刻的帧」与「复用旧帧」，
 * 故必须能取到实际帧 pts。 */

/* 上一帧是否命中片段（0/1）。 */
int32_t cq_preview_last_hit_clip(const CQPreview* preview);

/* 上一帧导入是否退化为 CPU 拷贝（0/1）。稳定态应为 0；持续为 1 说明零拷贝链路断了。 */
int32_t cq_preview_last_cpu_fallback(const CQPreview* preview);

/* 上一帧**实际取到的**解码帧 pts。out 可为 NULL（仅查询不取回）。 */
int32_t cq_preview_last_frame_pts(const CQPreview* preview, int64_t* out_value,
                                  int32_t* out_timescale);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CQ_SDK_H */
