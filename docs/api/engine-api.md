# ChuanqiCutEngine 公共接口参考（C ABI）

> 由 `tools/docs/gen_api_reference.py` 从
> `engine/bindings/swift/Sources/CChuanqiCut/include/cq_sdk.h` 自动生成
> ——**不要手改本文件**；接口变更后重跑生成器。红线 #7：这是唯一对外接口。

## 版本

```c
int32_t cq_version_major(void);
```

```c
int32_t cq_version_minor(void);
```

```c
int32_t cq_version_patch(void);
```

## 状态码

```c
int32_t cq_status_is_ok(int32_t code);
```

```c
int32_t cq_status_is_error(int32_t code);
```

```c
int32_t cq_status_is_cancelled(int32_t code);
```

```c
const char* cq_status_to_string(int32_t code);
```

## 线程角色

```c
void cq_mark_main_thread(void);
```

```c
int32_t cq_is_main_thread(void);
```

## 能力查询（红线 #3 的执行入口）

```c
int32_t cq_query_capability(int32_t capability);
```

## 会话（EditorSession 的 C ABI 句柄）

```c
CQSession* cq_session_create(void);
```

```text
停止并释放；传 NULL 安全（幂等）。
```

```c
void cq_session_destroy(CQSession* session);
```

```c
int32_t cq_session_submit(CQSession* session, const char* change_name, CQMutateFn mutate, void* ctx);
```

```c
typedef struct CQSnapshot { uint64_t version; uint64_t digest; } CQSnapshot;
```

```c
typedef struct CQChangeRecord { uint64_t version; const char* name; } CQChangeRecord;
```

```c
int32_t cq_session_changes_since(const CQSession* session, uint64_t from_version, CQChangeRecord* out, int32_t capacity);
```

```c
int32_t cq_session_change_count(const CQSession* session);
```

```c
void cq_session_set_observer(CQSession* session, CQSnapshotObserver observer, void* ctx);
```

```c
int32_t cq_session_register_asset(CQSession* session, uint64_t asset_id, const char* path);
```

```text
新增轨道。kind：0 = 视频，1 = 音频。
```

```c
int32_t cq_session_add_track(CQSession* session, int32_t kind);
```

```c
int32_t cq_session_add_clip(CQSession* session, uint64_t track_id, uint64_t asset_id, int64_t start_value, int32_t start_timescale, int64_t duration_value, int32_t duration_timescale, int64_t source_in_value, int32_t source_in_timescale);
```

```c
int32_t cq_session_move_clip(CQSession* session, uint64_t clip_id, int64_t start_value, int32_t start_timescale);
```

```c
int32_t cq_session_trim_clip(CQSession* session, uint64_t clip_id, int64_t duration_value, int32_t duration_timescale);
```

```c
int32_t cq_session_undo(CQSession* session);
```

```c
int32_t cq_session_redo(CQSession* session);
```

```c
int32_t cq_session_can_undo(const CQSession* session);
```

```c
int32_t cq_session_can_redo(const CQSession* session);
```

```text
---- 时间线查询（读已发布快照；任意线程）----
```

```c
typedef struct CQTrackInfo { uint64_t track_id; int32_t kind; int32_t enabled; int32_t muted; } CQTrackInfo;
```

```c
typedef struct CQClipInfo { uint64_t track_id; uint64_t clip_id; uint64_t asset_id; int64_t start_value; int32_t start_timescale; int64_t duration_value; int32_t duration_timescale; int64_t source_in_value; int32_t source_in_timescale; int64_t source_duration_value; int32_t source_duration_timescale; int32_t in_transition; int32_t out_transition; int64_t transition_duration_value; int32_t transition_duration_timescale; } CQClipInfo;
```

```c
int32_t cq_session_track_count(const CQSession* session, int32_t* out_count);
```

```text
查询轨道，按模型内顺序写入 out。
```

```c
int32_t cq_session_query_tracks(const CQSession* session, CQTrackInfo* out, int32_t capacity, int32_t* out_count);
```

```text
查询片段。track_id = 0 表示全部轨道（按轨道顺序、轨内按 start 升序）。
```

```c
int32_t cq_session_query_clips(const CQSession* session, uint64_t track_id, CQClipInfo* out, int32_t capacity, int32_t* out_count);
```

```text
---- 素材表查询（UIA-009 子步骤 3；读已发布快照，契约同上：状态码 + out_count）----
```

```c
typedef struct CQAssetInfo { uint64_t asset_id; char path[512]; int32_t path_truncated; } CQAssetInfo;
```

```c
int32_t cq_session_asset_count(const CQSession* session, int32_t* out_count);
```

```c
int32_t cq_session_query_assets(const CQSession* session, CQAssetInfo* out, int32_t capacity, int32_t* out_count);
```

```c
int32_t cq_media_probe_duration(const char* path, int64_t* out_value, int32_t* out_timescale);
```

## 预览（BIND-003 建立；UIA-009 子步骤 2 收口，2026-10-03）

```c
CQPreview* cq_preview_create(CQSession* session, uint32_t width, uint32_t height);
```

```text
释放；传 NULL 安全（幂等）。调用方保证 session 存活于此调用之前。
```

```c
void cq_preview_destroy(CQPreview* preview);
```

```c
int32_t cq_preview_render_frame(CQPreview* preview, int64_t pts_value, int32_t pts_timescale, void** out_texture);
```

```text
改变离屏目标尺寸。会丢弃当前目标纹理（此前返回的 out_texture 失效）。
```

```c
int32_t cq_preview_resize(CQPreview* preview, uint32_t width, uint32_t height);
```

```c
int32_t cq_preview_set_fit_mode(CQPreview* preview, int32_t fit_mode);
```

```text
上一帧是否命中片段（0/1）。
```

```c
int32_t cq_preview_last_hit_clip(const CQPreview* preview);
```

```text
上一帧导入是否退化为 CPU 拷贝（0/1）。稳定态应为 0；持续为 1 说明零拷贝链路断了。
```

```c
int32_t cq_preview_last_cpu_fallback(const CQPreview* preview);
```

```text
上一帧**实际取到的**解码帧 pts。out 可为 NULL（仅查询不取回）。
```

```c
int32_t cq_preview_last_frame_pts(const CQPreview* preview, int64_t* out_value, int32_t* out_timescale);
```

```c
int32_t cq_preview_last_timings(const CQPreview* preview, int64_t* out_acquire_ns, int64_t* out_import_ns, int64_t* out_draw_ns, int64_t* out_total_ns);
```

```c
CQPreviewPump* cq_preview_pump_create(CQPreview* preview);
```

```text
停止泵线程并释放。传 NULL 安全。
```

```c
void cq_preview_pump_destroy(CQPreviewPump* pump);
```

```text
停止（可再 start 重启）。停止后 request 仍可入队，重启后会渲染最新的那个。
```

```c
int32_t cq_preview_pump_stop(CQPreviewPump* pump);
```

```text
重启（已运行时返回 kOk，无副作用）。
```

```c
int32_t cq_preview_pump_start(CQPreviewPump* pump);
```

```text
请求渲染 pts 处一帧。任意线程可调；不阻塞（只入队 + 通知）。
```

```c
int32_t cq_preview_pump_request(CQPreviewPump* pump, int64_t pts_value, int32_t pts_timescale);
```

```text
请求改变离屏目标尺寸（在泵线程执行 —— RT 只能由持有它的线程销毁）。
```

```c
int32_t cq_preview_pump_request_resize(CQPreviewPump* pump, uint32_t width, uint32_t height);
```

```c
int32_t cq_preview_pump_lock(CQPreviewPump* pump, void** out_texture, int64_t* out_pts_value, int32_t* out_pts_timescale, uint64_t* out_seq);
```

```text
释放消费锁。必须与 lock 成对调用。
```

```c
int32_t cq_preview_pump_unlock(CQPreviewPump* pump);
```

```c
int32_t cq_preview_pump_stats(CQPreviewPump* pump, uint64_t* out_requested, uint64_t* out_rendered, uint64_t* out_coalesced, uint64_t* out_non_ok);
```

```c
void* cq_preview_shared_queue(CQPreview* preview);
```

## 播放时钟（UIA-010）

```c
CQPlayer* cq_player_create(int64_t frame_value, int32_t frame_timescale);
```

```text
释放；传 NULL 安全。
```

```c
void cq_player_destroy(CQPlayer* player);
```

```text
播放边界（时间线总时长）。不设置 = 无边界（一直播）。
```

```c
int32_t cq_player_set_duration(CQPlayer* player, int64_t value, int32_t timescale);
```

```text
循环播放开关（1/0）。
```

```c
void cq_player_set_loop(CQPlayer* player, int32_t loop);
```

```text
开始 / 继续播放（从当前时刻起；停止态即从 0 起）。
```

```c
int32_t cq_player_play(CQPlayer* player);
```

```text
暂停（冻结在当前时刻）。
```

```c
void cq_player_pause(CQPlayer* player);
```

```text
停止并回到 0。
```

```c
void cq_player_stop(CQPlayer* player);
```

```text
定位（量化到整帧，向下）。播放中调用会重锚。
```

```c
int32_t cq_player_seek(CQPlayer* player, int64_t value, int32_t timescale);
```

```text
是否正在播放（返回**数据** 0/1，不是状态码）。
```

```c
int32_t cq_player_is_playing(const CQPlayer* player);
```

```text
当前播放时刻。返回状态码，时刻经 out 参数给出（P26：数据与错误码不混用）。
```

```c
int32_t cq_player_current_time(const CQPlayer* player, int64_t* out_value, int32_t* out_timescale);
```

```text
边界推进。到末尾：loop 开 → 回绕；否则停止。未播放 = no-op。
```

```c
int32_t cq_player_tick(CQPlayer* player);
```

```c
int32_t cq_session_timeline_duration(const CQSession* session, int64_t* out_value, int32_t* out_timescale);
```

## 日志：按「端到端链路（workflow）」筛选（CORE-010）

```c
void cq_log_configure_from_env(void);
```

```c
void cq_log_set_level(int32_t level);
```

