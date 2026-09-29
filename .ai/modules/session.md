# session 层：线程模型与队列骨架（CORE-008）

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
