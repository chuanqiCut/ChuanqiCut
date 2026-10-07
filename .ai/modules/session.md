# session 层：线程模型与队列骨架（CORE-008）

> **归属**：A 线（编辑器/UI；会话层） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

> 规格：`docs/specs/ARCH-001-技术方案总纲.md` §6
> 任务卡：`docs/tasks/TASK-CORE-008.md`
> 落地日期：2026-09-29

## 为什么有这一层

`core/include/cq/base/concurrency.h`（CORE-005）文件头明确划了边界：

> 并发原语提供「必要的最小集合」，**不**做成通用线程库（无自己的线程池…）。
> 线程池/会话线程骨架属于 **CORE-008**，不在 base 层。

在此之前，ARCH-001 §6 的线程模型**只是一张 ASCII 图**：7 类线程角色定义好了，
`Session Thread` 却不存在，"主线程零阻塞"这条铁律没有任何代码可以执行或验证。

## 文件

| 文件 | 内容 |
|---|---|
| `core/include/cq/session/thread_model.h` | `ThreadRole` 枚举（7 类 + kUnknown）、角色标记/查询 |
| `core/src/session/thread_model.cpp` | `thread_local` 角色状态实现 |
| `core/include/cq/session/task_runner.h` | `TaskRunner`：串行任务执行器 |
| `core/src/session/task_runner.cpp` | worker 线程循环、投递与背压 |
| `tests/unit/test_thread_model.cpp` | 含「主线程零阻塞」实测 |

## 线程角色

```
kUnknown(默认) / kMain / kSession / kDecode / kRender / kEncode / kAudio / kInference
```

- 用 `thread_local` + `SetCurrentThreadRole()` **运行时标记**，不用编译期宏推断
  （`#if __APPLE__` 猜不出当前跑在哪根线程上）。
- 默认 `kUnknown` 而非 `kMain`：**宁可"不知道"，不可把未标记线程误判成主线程**——
  误判会让"主线程零阻塞"的守卫形同虚设。
- **主线程身份 SDK 无法自得知**（只有 App 知道哪根是 UI 线程）。
  约定：宿主启动时在主线程调用 `SetCurrentThreadRole(ThreadRole::kMain)`。
  ⚠️ 宿主忘了标记 → 一律 kUnknown，守卫失效。需 BIND-002 在 Swift 侧兜住。

## TaskRunner（Session Thread 骨架）

```cpp
TaskRunner::Config cfg;
cfg.role = ThreadRole::kSession;   // worker 对外呈现的角色
cfg.queue_capacity = 64;           // 有界，背压
runner.Start();
runner.Post(task);                 // 非阻塞；满 -> kResourceExhausted
runner.Shutdown();                 // 请求停止 + join（会阻塞调用线程）
```

关键约束（详见任务卡 D1~D5）：

- **`Post()` 绝不阻塞**：队列满立即返回 `kResourceExhausted`，由调用方降速/丢帧
- **不提供 `PostAndWait`**：那会让"主线程零阻塞"在 API 面被破坏得更隐蔽
- 背压队列复用 CORE-005 的 `BoundedQueue<Task>`；其阻塞 `Pop` 已支持
  `CancelToken` ≤ ~1ms 唤醒，正合 worker 循环需要
- **任务内部禁止抛异常**：执行期抛出即 terminate，这是**调用方的责任契约**。
  `TaskRunner` 刻意不 try/catch —— 捕获等于默许异常流向内核
- **析构无条件 RequestCancel + join**：`std::thread` 在 joinable 状态析构会 terminate

## EditorSession（CORE-009，对外唯一门面）

```cpp
EditorSession session;                       // 或注入 ISessionState + Config
session.SetSnapshotObserver(on_snapshot);    // 应在 Start 之前设置
session.Start();
session.Submit("add-clip", mutate_fn);       // 异步，不阻塞
Snapshot s = session.CurrentSnapshot();      // {version, digest}，任意线程可读
session.ChangesSince(last_seen, &out);       // UI 增量刷新
```

| 约束 | 说明 |
|---|---|
| 变更串行 | 复用 `TaskRunner`（kSession 线程）。这是 Undo/Redo 与三端一致性的前提（红线 #5） |
| 版本推进 | **仅成功**推进；失败与取消都不推进（否则 UI 会以为状态变了而错刷） |
| 不阻塞 | `Submit` 实测 0.005~0.010 ms；**刻意不提供 `SubmitAndWait`** |
| 观察者线程 | 回调**在 session 线程**执行 —— BIND-002(Swift) 必须自己 dispatch 到主线程 |
| 读路径安全 | digest 由 session 线程算好存入 atomic，读路径绝不跨线程调用 `state->Digest()` |
| 背压 | 队列满返回 `kResourceExhausted`，不内置重试（重试属交互层语义） |

**边界（不越界）**：不定义 `TimelineModel`（MODEL-001）、不定义
`Command`/`CommandHistory`/Undo-Redo（MODEL-002）。状态内容通过 `ISessionState`
扩展点注入 —— 本期用测试实现跑通机制，避免门面变成空壳（防"断接口"第三次复发）。

## 铁律落地情况

| ARCH-001 §6 铁律 | 状态 |
|---|---|
| 1. 主线程零阻塞 | ✅ **可测**：单测实测 `Post()` 返回 0.030ms（16ms 预算的 1/533） |
| 2. 音频线程无锁无分配 | ⚠️ 仅提供 `IsAudioThread()` 判定；实际无锁路径待 AUDIO-001 落地 |
| 3. 背压（有界队列） | ✅ `BoundedQueue` + `kResourceExhausted`，不提供无界模式 |
| 4. 取消（CancelToken） | ✅ `RequestStop` → worker ≤ ~1ms 退出；`Shutdown` 保证 join |

## 实测数据

见 `.ai/memory/baselines.md`「CORE-008」段落。
⚠️ 16ms 预算是**本机 macOS** 实测，iPhone 17 Pro 需真机回填。

## 未做（留给后续任务）

- Decode Pool 的 N 路并发调度（MEDIA 侧）
- Render / Encode / Audio 线程的专属调度（PALA / EXPORT / AUDIO 侧）
- `EditorSession` 门面与快照（**CORE-009**，本层的直接下游）
- 主线程卡死的自动检测（watchdog 类机制，属 PERF 范畴）


---

# UIA-009 子步骤 1（2026-10-03）：内建模型状态与查询 ABI

## EditorModelState（ISessionState 的模型层实现）

`core/include/cq/model/editor_model_state.h` —— Timeline + AssetRegistry +
CommandHistory 组装为会话状态。`EditorSession` 默认构造即内建（注入自定义
ISessionState 时类型化接口返回 kInternal）。

- **变更**：仅 session 线程（经 Submit 投递）。类型化入口：
  `SubmitRegisterAsset / SubmitAddTrack / SubmitAddClip`（前两者/三者分别
  走素材表与 CommandHistory，可撤销的是片段命令）。
- **读**：每次成功变更后发布 `shared_ptr<const Timeline>` 不可变快照
  （mutex 保护的 shared_ptr，持锁 = 指针拷贝，纳秒级；⚠️ 本机 libc++ 未实现
  C++20 atomic<shared_ptr>，P0718，编译期即拒）。任意线程无阻塞读。
- **digest**：真实的 Timeline 结构指纹（FNV-1a，字段集见
  `EditorModelState::Fingerprint`）——「恒为 0」时代结束，CORE-009 旧断言
  已随语义更新。

## 新 C ABI（cq_sdk.h 会话级模型段）

| 函数 | 语义 |
|---|---|
| `cq_session_register_asset` | 异步提交；素材不参与 Undo、不进指纹 |
| `cq_session_add_track` / `cq_session_add_clip` | 异步提交；校验在 session 线程（失败=版本不推进+观察者不回调） |
| `cq_session_track_count` / `query_tracks` / `query_clips` | **同步读快照**；返回状态码，条数一律走 out_count（两段式：out=NULL 先取总数）|

⚠️ **查询函数的返回值 = 状态码，条数 = out_count**（与 changes_since 的
「返回条数」约定刻意不同 —— 混用会出「成功返回 1 被当错误码」的事故，P26）。
undo/redo 的 C ABI 归 UIA-008。

## 素材表查询与时长探测（UIA-009 子步骤 3，2026-10-03）

| 函数 | 语义 |
|---|---|
| `cq_session_asset_count` / `cq_session_query_assets` | 读快照（契约同其它查询）；`CQAssetInfo.path` 是 `char[512]` 值拷贝（NUL 结尾 + truncated 标记），**不是**指针 —— 快照发布后路径仍可读 |
| `cq_media_probe_duration(path, out)` | **同步**探测媒体时长（打开容器→读 duration→关闭，毫秒级；用户导入动作、低频）。实现调 PAL 工厂链，**独立 TU** `core/src/media/media_probe_abi.cpp`（已登记 ADR-0011 §3 TU 表） |

素材 id 由**调用方分配**（内核不生成）；AssetRegistry 新增 `ListAssets()` 遍历。

## 子步骤 2（2026-10-03）：预览收口，Session 成为模型唯一真源

`cq_preview_create(CQSession*, w, h)` —— 预览不再有本地模型，渲染读
`CurrentModelSnapshot()`（Timeline+AssetRegistry **配对**发布，model_snapshot.h）。
`cq_preview_register_asset / add_clip` 已删除。快照发布点从「仅时间线」扩为配对
（RegisterAsset 也发布）。CQSession 的真实定义抽到内核私有头
`core/src/cq_session_impl.h`（cq_sdk.cpp 与 cq_sdk_preview.cpp 共享；
include 用相对路径 `../cq_session_impl.h`，pod 构建无私有 search path）。

# UIA-005 落地（2026-10-03）：片段编辑与撤销的 C ABI

决策见 `docs/decisions/ADR-0012`（提交时机 + 撤销栈线程边界）。要点：

- **编辑类提交**：`SubmitMoveClip / SubmitTrimClip` —— 与 SubmitAddClip 同构
  （异步入队，校验在 session 线程：片段存在 / duration>0 / 同轨不重叠）。
- **撤销也是 session 线程操作**：`SubmitUndo / SubmitRedo` —— CommandHistory
  与 Timeline 都是 session 线程状态，UI 线程不能直接翻栈。空历史 → session
  线程返回 kInvalidArgument（版本不推进）。
- **撤销栈能力**：`EditorModelState` 维护 `atomic<bool> can_undo_/can_redo_`
  （Execute/Undo/Redo 成功后 `RefreshHistoryFlags()` 刷新），
  `EditorSession::CanUndo/CanRedo` 读原子量 —— **不直读 CommandHistory**。

| 新 C ABI | 语义 |
|---|---|
| `cq_session_move_clip` / `cq_session_trim_clip` | 异步提交（Ok=入队）；trim **只改 duration，不动 source_in** |
| `cq_session_undo` / `cq_session_redo` | 异步提交；空历史在 session 线程失败 |
| `cq_session_can_undo` / `cq_session_can_redo` | **同步**读原子标志；返回 **0/1 数据**，不是状态码（P26，别拿去比 cq_status_is_ok） |

守卫：`tests/unit/test_c_abi_edit.c`（61 条断言，只链 cq_core）。

⚠️ **左边缘裁剪本期不支持**：需同时改 start + source_in + duration，是另一条
命令。UI 左边缘归「移动」，见 ADR-0012 D5。

## 读路径的下游

- UIA-004 时间线视图：Session.queryTracks/queryClips（Swift 封装，主线程直读）
- UIA-009 子步骤 2 预览收口：EditorModelState.CurrentTimeline() 即预览该用的
  读路径（渲染时原子加载最新快照），替代 CQPreview 本地 Timeline
