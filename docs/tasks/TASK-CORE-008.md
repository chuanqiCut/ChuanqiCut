# TASK-CORE-008：线程模型与队列骨架

- **层**：跨平台内核（`core/src/session/`）
- **依赖**：CORE-005（并发原语 / CancelToken / BoundedQueue，已完成）
- **阻塞**：CORE-009（EditorSession 门面）→ BIND-001（C ABI）→ BIND-002（Swift 绑定）
- **规格**：`docs/specs/ARCH-001-技术方案总纲.md` §6 线程模型
- **日期**：2026-09-29

## 背景

`CORE-005` 的 `concurrency.h` 文件头已明确划边界：

> 并发原语提供「必要的最小集合」，**不**做成通用线程库（无自己的线程池…）。
> 线程池/会话线程骨架属于 **CORE-008**，不在 base 层。

ARCH-001 §6 定义了 7 类线程角色与 4 条铁律，但**没有任何代码落地**：
所谓"线程模型"目前只是一张 ASCII 图，`Session Thread` 不存在。

## 目标

1. 落地**线程角色体系**（角色标识 / 查询 / 断言），使"主线程零阻塞"可被运行时检查
2. 落地**串行任务执行器**（Session Thread 骨架）：非阻塞投递 + 有界背压 + 可取消
3. 不重复发明 CORE-005 已有的东西：`CancelToken` / `BoundedQueue` 直接复用

## 写集（write_set）

| 文件 | 动作 | 说明 |
|---|---|---|
| `core/include/cq/session/thread_model.h` | 新增 | `ThreadRole` 枚举、角色查询、主线程/音频线程判定 |
| `core/src/session/thread_model.cpp` | 新增 | `thread_local` 角色状态 |
| `core/include/cq/session/task_runner.h` | 新增 | `TaskRunner`（串行执行器） |
| `core/src/session/task_runner.cpp` | 新增 | worker 线程与队列调度 |
| `core/CMakeLists.txt` | 修改 | 登记两个新 `.cpp` |
| `tests/unit/test_thread_model.cpp` | 新增 | 含「主线程零阻塞」实测 |
| `tests/CMakeLists.txt` | 修改 | 注册新用例 |
| `tools/pal/check_pal_headers.py` | 修改 | 扫描范围改为自动遍历（见下方"顺带修复"） |

## 设计决策（评审点）

### D1 · 角色靠**运行时标记**，不靠编译期推断

`thread_local ThreadRole` + `SetCurrentThreadRole()` 由宿主/线程自己声明。
不用 `#if __APPLE__` 或任何平台 API —— 内核头文件零平台类型（红线 #2）。

主线程身份**无法由 SDK 自己得知**（只有 App 知道哪个线程是 UI 线程），
故约定：宿主启动时在主线程调用 `SetCurrentThreadRole(ThreadRole::kMain)`。

### D2 · `Post()` 绝不阻塞 —— 背压用**有界队列**表达

队列满时 `Post` 立即返回 `kResourceExhausted`，调用方据此降速/丢帧。
**不提供 `PostAndWait`**：那会让"主线程零阻塞"铁律在 API 层面被破坏得更隐蔽。
（CORE-009 若确需同步语义，应自己做 future 包装，而不是污染这里。）

背压队列复用 CORE-005 的 `BoundedQueue<Task>` —— 它的阻塞 `Pop` 已经
支持 `CancelToken` ≤ ~1ms 唤醒，正是 worker 循环需要的。

### D3 · 任务内部**禁止抛异常**

内核禁用异常（红线 / ARCH-001），错误一律 `Status`。`Task` 为 `std::function<void()>`，
执行期若抛出会 terminate —— 这是**调用方的责任契约**，在头文件注释里写明。
（不在 `TaskRunner` 里 try/catch：那等于默许异常流向内核。）

### D4 · 析构必须保证 worker 已 join

`std::thread` 析构时若仍 joinable 会 `std::terminate`。故析构里无条件
`RequestCancel()` + `join()`，避免"忘记停就销毁"直接崩进程。

### D5 · ExecutedCount 仅为可测性

任务执行计数不是性能指标，是为了让单测能断言"任务真的跑了 N 个"。
不加采样、不进 perf 埋点（那是 PERF-001 的事）。

## 顺带修复：头文件门禁的静默缺口

`tools/pal/check_pal_headers.py` 原先硬编码扫描 `("pal","gfx","media")`。
CORE-008 新增的 `session/` **不会被扫到** —— 不报错、CTest 全绿、
`git status` 也看不出来，纯靠人记得加（与 `.gitignore` 裸 `build/`
把 `tools/build/` 一并忽略属同一种缺口）。

改为**递归遍历 `core/include/cq/` 全部目录**，仅排除 `base/`：
`base/time.h` 的显式 `ToSeconds()` 是 CORE-001 明确允许的转换
（禁止的是隐式 `operator double`），不该被 double 规则误伤。

修复后扫描数 16 → 17 个头，`session/` 自动纳入设防。

## 验证命令

```bash
tools/build/build_core.sh --platform=apple --config=Debug   --test
tools/build/build_core.sh --platform=apple --config=Release --test
tools/build/build_core_apple.sh --config=Release          # 三切片 + 链接冒烟
python3 tools/pal/check_pal_headers.py
```

## 验收标准（对应 BACKLOG「主线程零阻塞可测」）

- **实测**：`Post()` 一个 sleep 100ms 的任务，返回耗时 **< 16ms**（主线程预算）
- 任务确实在 **worker 线程**执行（`CurrentThreadRole()==kSession`、`IsMainThread()==false`）
- FIFO 执行顺序
- 队列满 → `kResourceExhausted`（有界背压，不无限增长）
- `RequestStop` + `Shutdown` 干净退出，worker join 完成
- 未启动 / 已停止状态下 `Post` 返回明确错误码，不崩溃
- 新增头文件被静态门禁覆盖（0 violation）

## 剩余风险

- `ThreadRole` 的正确性依赖宿主主动标记；宿主忘了标记 → 一律 `kUnknown`，
  断言失效。尚**没有**自动检测机制（需 App 层配合，见 BIND-002）。
- 16ms 预算是**本机 macOS** 实测；iPhone 17 Pro 上的主线程表现需真机回填。
- 本任务只做**骨架**：Decode Pool 的 N 路并发、Render/Encode/Audio 线程
  的具体调度留待对应 PALA/MEDIA/EXPORT 任务，此处不预设。
