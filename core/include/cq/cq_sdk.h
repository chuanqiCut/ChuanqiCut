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

/* 快照。任意线程可调。
 * digest 自 UIA-009 子步骤 1（2026-10-03）起为**真实时间线结构指纹**
 * （内建模型状态；注入自定义 ISessionState 时语义由注入方定义）。 */
typedef struct CQSnapshot {
    uint64_t version; /* 单调递增；0 = 尚无变更 */
    uint64_t digest;  /* 时间线结构指纹（FNV-1a；字段集见 EditorModelState::Fingerprint） */
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

/* --------------------------------------------------------------------------
 * 会话级模型：素材表 + 时间线（UIA-009 子步骤 1，2026-10-03）
 * --------------------------------------------------------------------------
 * EditorSession 内建真实模型状态（时间线 + 素材表 + 命令历史，可撤销）。
 *
 * ⚠️ 提交与查询是**两种线程语义**：
 *    - register_asset / add_track / add_clip：**异步提交**（入队 session 线程
 *      后立即返回）。Ok 只代表「已入队」；参数校验（重叠 / 素材类型 / 轨道缺失）
 *      在 session 线程执行 —— 失败表现为版本不推进 + 观察者不回调，调用方经
 *      查询接口确认最终状态。**不要**在提交后同步假设已生效。
 *    - track_count / query_tracks / query_clips：**同步读**已发布的不可变快照
 *      （任意线程、无锁、不阻塞），反映「最近一次成功变更之后」的完整状态。
 *      未发生变更前返回空时间线（track_count=0）。
 *
 * 时间一律 RationalTime{value, timescale}（红线 #4，项目 timescale = 120000）。 */

/* 注册素材到会话级素材表（id → 文件路径；path 被内核拷贝）。
 * 重复注册同一 id 整体替换。素材不参与 Undo（资料库语义，非时间线编辑）。 */
int32_t cq_session_register_asset(CQSession* session, uint64_t asset_id, const char* path);

/* 新增轨道。kind：0 = 视频，1 = 音频。 */
int32_t cq_session_add_track(CQSession* session, int32_t kind);

/* 新增片段（可撤销 —— 经 CommandHistory）。参数语义与 cq_preview_add_clip 相同：
 * 轨道不存在 / 类型不匹配 / 时长非正 / 同轨重叠 → session 线程校验失败。 */
int32_t cq_session_add_clip(CQSession* session, uint64_t track_id, uint64_t asset_id,
                            int64_t start_value, int32_t start_timescale,
                            int64_t duration_value, int32_t duration_timescale,
                            int64_t source_in_value, int32_t source_in_timescale);

/* ---- 时间线查询（读已发布快照；任意线程）---- */

typedef struct CQTrackInfo {
    uint64_t track_id;
    int32_t kind;     /* 0 = 视频，1 = 音频 */
    int32_t enabled;  /* 0/1 */
    int32_t muted;    /* 0/1 */
} CQTrackInfo;

typedef struct CQClipInfo {
    uint64_t track_id;
    uint64_t clip_id;
    uint64_t asset_id;
    int64_t start_value;
    int32_t start_timescale;
    int64_t duration_value;
    int32_t duration_timescale;
    int64_t source_in_value;
    int32_t source_in_timescale;
    int64_t source_duration_value;
    int32_t source_duration_timescale;
    int32_t in_transition;   /* 0=none 1=cross_fade 2=dip_to_black */
    int32_t out_transition;  /* 同上 */
    int64_t transition_duration_value;
    int32_t transition_duration_timescale;
} CQClipInfo;

/* 三个查询函数的统一契约（与 changes_since 的「返回条数」约定刻意不同）：
 *   返回值 = **状态码**（0 成功；7000 参数非法；其它见状态表）；
 *   out_count = **条数**（成功时：out 非 NULL 为实际写入条数，out 为 NULL 为总数
 *   —— 两段式查询：先 out=NULL 拿总数分配缓冲，再带缓冲取数据）。 */
int32_t cq_session_track_count(const CQSession* session, int32_t* out_count);

/* 查询轨道，按模型内顺序写入 out。 */
int32_t cq_session_query_tracks(const CQSession* session, CQTrackInfo* out,
                                int32_t capacity, int32_t* out_count);

/* 查询片段。track_id = 0 表示全部轨道（按轨道顺序、轨内按 start 升序）。 */
int32_t cq_session_query_clips(const CQSession* session, uint64_t track_id, CQClipInfo* out,
                               int32_t capacity, int32_t* out_count);

/* ---- 素材表查询（UIA-009 子步骤 3；读已发布快照，契约同上：状态码 + out_count）---- */

typedef struct CQAssetInfo {
    uint64_t asset_id;
    char path[512];            /* NUL 结尾；超长截断（path_truncated = 1） */
    int32_t path_truncated;    /* 0/1 */
} CQAssetInfo;

int32_t cq_session_asset_count(const CQSession* session, int32_t* out_count);

int32_t cq_session_query_assets(const CQSession* session, CQAssetInfo* out,
                                int32_t capacity, int32_t* out_count);

/* 媒体时长探测（UIA-009 子步骤 3；**同步**：打开容器读时长后立即关闭。
 * 导入流程用于确定片段时长 —— 用户动作、低频，非逐帧路径）。
 *   0 = 成功；7000 = 参数非法；其它 = 打开/解析失败原样透传。
 * ⚠️ 实现调用 PAL 工厂，隔离在独立 TU（ADR-0011 规则 1）。 */
int32_t cq_media_probe_duration(const char* path, int64_t* out_value,
                                int32_t* out_timescale);

/* ==========================================================================
 * 预览（BIND-003 建立；UIA-009 子步骤 2 收口，2026-10-03）
 * ==========================================================================
 * CQPreview = 「取帧 + 渲染」的会话级预览器。**时间线与素材表不在预览里**：
 * 渲染输入是 CQSession 发布的不可变模型快照（每次 render_frame 入口加载），
 * 模型的唯一真源是 CQSession（cq_session_register_asset / add_track / add_clip）。
 * 典型用法：session 装配模型 → cq_preview_create(session) → 每帧 render_frame。
 *
 * 时间一律 RationalTime{value, timescale}（红线 #4，禁止浮点秒）。
 * 本项目网格 timescale = 120000（ADR-0009）。
 *
 * ⚠️ 生命周期：CQPreview **不拥有** CQSession —— 必须 session 先活后死
 *    （Swift 绑定由对象图保证：Previewer 强持有 Session）。
 *
 * ⚠️ 平台能力依赖：预览需要 PAL 的图形设备 / 全屏拷贝 pass / 帧提供器三项后端。
 *    缺失任一后端、或 session 未内建模型时 cq_preview_create 返回 NULL ——
 *    这是**运行时**失败，上层据此走「预览不可用」路径。
 *    **不要**用编译期宏判断平台能力（红线 #3）。
 */

typedef struct CQPreview CQPreview;

/* 创建预览器（挂到 session 的模型快照上）。width/height 为离屏渲染目标尺寸；
 * 失败返回 NULL。注意：当前为「拉伸铺满」，不做宽高比适配（letterbox 待 UI
 * 需求明确后加）。 */
CQPreview* cq_preview_create(CQSession* session, uint32_t width, uint32_t height);

/* 释放；传 NULL 安全（幂等）。调用方保证 session 存活于此调用之前。 */
void cq_preview_destroy(CQPreview* preview);

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
