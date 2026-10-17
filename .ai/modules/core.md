# 模块：core/base 内核基础

> **归属**：集成机（内核基础 + 热点文件） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`engine/core/cq/base/`、`engine/core/cq/platform/`、`engine/core/cq/session/`（头与实现共置，ADR-0033/INFRA-024）

## 职责
时间、状态、日志、内存、并发、Platform 接口定义、ChqEditorSession 门面。

## 入口
- `ChqRationalTime` — **有理数时间**，禁止浮点秒。项目 timescale = 60000。
- `ChqStatus` — 跨端一致错误码。
- `Arena` / 内存池 — 支持纹理与帧缓冲预算记账。
- `ChqCancelToken` — 长任务取消。
- `ChqICapabilities` / `cq_query_capability()` — **运行时能力查询**。
- `ChqEditorSession` — 对外唯一门面，产出不可变快照 + 版本号。

## 依赖
无（本模块是最底层，不得反向依赖任何其他模块）

## 硬约束
1. Platform 头文件零平台类型 → 跨层用 opaque 句柄 `CQNativeImageHandle` 等。
2. 能力查询不得用编译期宏推断（Android 能力由机型决定，Apple 由芯片决定）。
3. 音频线程无锁、无分配；主线程零阻塞。
4. `ChqRationalTime` 运算做 timescale 归一化并检测溢出。

## 验证
```bash
ctest -R core_base
# 关键用例：29.97fps 累计 10000 次帧步进零漂移
```

## 构建与单测入口（INFRA-002 建立）

> 本地与 CI 唯一入口：`tools/build/build_core.sh`。cmake 不在 PATH，脚本内默认回退到
> 绝对路径，可用 `CMAKE_BIN` 环境变量覆盖；ctest 同目录，可用 `CTEST_BIN` 覆盖。

```bash
# 桌面（macOS）Debug 构建 + 单测（默认 cmake 绝对路径，零警告 -Werror）
tools/build/build_core.sh --platform=apple --config=Debug --test

# Release 构建（开 LTO/IPO）
tools/build/build_core.sh --platform=apple --config=Release

# 等价手写命令（若 PATH 无 cmake）：
CMAKE_BIN="$HOME/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake"
$CMAKE_BIN -S . -B build -DCMAKE_BUILD_TYPE=Debug
$CMAKE_BIN --build build
$(dirname $CMAKE_BIN)/ctest --test-dir build --output-on-failure
```

- C++20 硬锁：`cmake/CompileOptions.cmake` 的 `cq_require_cxx20(target)`（CXX_STANDARD 20 / REQUIRED / EXTENSIONS OFF）。
- 警告集合：`cmake/Warnings.cmake` 的 `apply_cq_warnings(target)`，显式 `-Wall -Wextra -Wconversion -Wshadow -Wold-style-cast` + `-Werror`（Debug/Release 都开）。
  红线：**禁止随手 `-Wno-*` 逃逸，只能改代码**（见文件内注释；特例需 ADR 记录）。

## 相关
ADR-0006（有理数时间与版本模型）、ARCH-001 §5/§6

---

## 已实现：CORE-001 ChqRationalTime（2026-09-25）

> 写集：`core/include/cq/base/time.h`、`core/src/base/time.cpp`、`tests/unit/base/test_time.cpp`（旧路径，当时如此）

- 存储 `struct ChqRationalTime { int64_t value; int32_t timescale; }`，全程 **int64 整数运算，零浮点中间值**。
- 项目 timescale 常量 `kProjectTimeScale = 60000`（沿用 ADR-0006，未就地改值）。
- **红线守卫**：头文件 `static_assert(!std::is_convertible_v<ChqRationalTime, double>)` 编译期禁止隐式 `double` 转换；唯一浮点出口是显式 `ToSeconds()`，注释写明仅限日志/UI，禁入计算路径。
- 运算：`AddRational` / `SubRational` / `ScaleRational`（retime，支持倒放负系数）/ `ModRational`（欧几里得，结果落在 `[0,base)`）/ `Rescale(target_ts, ChqRoundMode)`，全部以**公共 timescale（LCM 对齐）**归一化，不约到最简分数（防 timescale 漂移到 1）。
- `Rescale` 非整除时**强制显式 `ChqRoundMode`{Floor,Ceil,Round}**，无默认行为（对 seek 语义关键）。
- 比较用 `__int128` 交叉相乘，无浮点、无溢出。
- 所有运算溢出经 `ChqStatus`（CORE-002 的 `kOverflow`）返回，内核无异常。
- 单测覆盖：八帧率 × 10000 步进**零漂移**（实测 drift=0，见下）+ 跨 timescale 比较/减/缩放/取模 + 跨 timescale 舍入方向（含负数 Floor/Ceil）+ 溢出边界。

### ⚠️ ADR-0006 已知缺口（需决策，非本任务权限内就地修正）
**60000 不能精确表示 23.976fps 的单帧周期**。23.976 = 24000/1001，其帧周期 = 1001/24000 s；要在 timescale=60000 用整数 tick 表示需 60000×1001/24000 = **2502.5 tick（非整数）**，即 23.976 的「每帧」无法精确落在 60000 网格，逐帧必须舍入、累积误差。
其余七种帧率（含 29.97=30000/1001、59.94=60000/1001）在 60000 下均精确。
**建议 ADR-0006 将项目 timescale 修正为 `120000`（= lcm(60000,24000)）**：实测 23.976 @120000 = 5005 tick 精确，八种帧率全部整数化。本模块按 ADR 维持 60000，并在 `test_time.cpp::TestTimescale60000InsufficientFor23_976` 固化该事实。

### 溢出边界（实测，详见 `.ai/memory/baselines.md`）
- `value` 为 int64，`INT64_MAX = 9223372036854775807`。
- @60000 可表示最大时长 ≈ 1.537×10¹⁴ s ≈ **4.87×10⁶ 年**，远超 >24h 需求。
- 24h @60000：`value = 5,184,000,000`；1 年 @60000：`value = 1,892,160,000,000`，均远小于 INT64_MAX（static_assert 验证）。
- 运算溢出经 `kOverflow` 显式上报：`INT64_MAX + 1` 相加、`INT64_MAX × 2` 重定标均正确返回溢出而非崩溃/环绕。

---

## 已实现：CORE-002 ChqStatus（2026-09-25）

> 写集：`core/include/cq/base/chq_status.h`、`core/src/base/status.cpp`、`tests/unit/base/test_status.cpp`（旧路径，当时如此）

- **稳定数值错误码**：`enum class ChqStatusCode : int32_t`，每个值**显式写死**（不依赖编译器自动编号），保证 iOS/macOS/Android/鸿蒙/桌面三端一致、ABI 稳定。
- 分类覆盖媒体管线：I/O(1000)、解码(2000)、编码(3000)、格式不支持(4000)、资源不足(5000)、取消(6000)、参数非法(7000)、数值溢出(8000)、内部(9000)、未知(9900)。
- **取消与错误的语义分界**：`kCancelled(6000)` 是独立「停止信号」，**不是错误**——`IsError()` 对 `kCancelled` 返回 `false`，`IsCancelled()` 专门识别；CORE-005 的 `ChqCancelToken` 将来只产生 `kCancelled`，调用方收到后做清理而非报错（头文件已注释该约定，未实现 ChqCancelToken）。
- **零平台类型**：头文件仅用 `int32_t` / `const char*`，无 Apple/Android/鸿蒙类型。
- **无异常**（ARCH-001「禁用异常跨模块」）：错误一律经 `ChqStatus` 返回；`ChqStatus` 为仅含 `ChqStatusCode` 的轻量值，音频线程可安全拷贝/返回。
- 辅助：`StatusToString`（日志/UI）、`CategoryOf`（分类聚合）。
- 单测覆盖：全部码值 `static_assert` 稳定 + 分类映射 + 取消/错误分界 + 字符串。

## 实际目录（INFRA-001 + INFRA-002 建立）

> 由 `TASK-INFRA-001` 落盘的骨架路径，供后续 CORE 任务对齐存放位置（权威树以 ARCH-001 §8 为准）。

- `engine/core/CMakeLists.txt` — 内核 CMake 入口；`cq_core` 现为**真正的 STATIC 库**（含 `engine/core/cq/chq_build_anchor.cpp` 构建锚点，非业务逻辑）
- `engine/core/cq/cq_sdk.h` — 对外 C ABI（**BIND-001 已冻结**，2026-09-29；红线 #7：
仅 C 类型 + opaque 句柄）。实现在 `engine/core/cq/cq_sdk.cpp`。
覆盖：版本 / 状态码 / 线程角色标记 / **能力查询** / ChqEditorSession 会话门面。
由 `tests/unit/abi/test_c_abi.c`（**真正的 C 翻译单元**）机器校验"零 C++ 类型"——
已反向验证：临时插入 `std::string` 后该 TU 立即 fatal error。
⚠️ 观察者回调在 session 线程，Swift 侧（BIND-002）须自行 dispatch 到主线程。
- `engine/core/cq/chq_build_anchor.cpp` — 构建锚点 TU（INFRA-002 新增，可链接、零业务逻辑、证明 -Werror 下可编译）
- `core/src/` — 内核源码根，按模块分子目录：`base/ model/ gfx/ render/ media/ audio/ ai/ project/ export/ session/`（尚未创建，由对应 CORE 任务建）（旧路径，当时如此）
- `core/tests/` — 内核单测（实际落在 `tests/unit/`，见下）
- `core/include/cq/<module>/` — 内部 C++ 头（预留，未在骨架阶段创建）（旧路径，当时如此）

## 单测目录（INFRA-002 建立）

- `tests/CMakeLists.txt` — 启用 CTest，注册内核单测（顶层 `CMakeLists.txt` 已 `enable_testing()`）
- `tests/unit/base/cxx20_smoke.cpp` — 占位 smoke 用例：`static_assert(__cplusplus >= 202002L)`，证明 C++20 生效；链接 `cq_core`
- 运行：`ctest --test-dir build`（或 `build_core.sh --test`）

> 注：骨架阶段仅建占位，未创建 `core/src/<module>` 子目录与真实头文件，避免越界到 CORE 系列任务的写集。（旧路径，当时如此）

---

# base 层已实现（CORE-001 ~ CORE-005，2026-09-25）

按依赖顺序推进，为 CORE-006「Platform 接口冻结」打地基。BACKLOG 第 327 行要求：
**CORE-006 之前任何 Platform 实现不得开始**，故 base 类型必须先定型。

## CORE-001 `ChqRationalTime` — `engine/core/cq/base/chq_rational_time.h` / `engine/core/cq/base/chq_time.cpp`（原 `base/time.h`/`time.cpp`，已更名共置）

- `struct ChqRationalTime { int64_t value; int32_t timescale; }`，项目统一 timescale = 60000
- **禁止 `operator double`**；`ToSeconds()` 只用于日志/UI 展示，禁入计算路径（任务卡 risk 段明确警示）
- 加减/比较/取模/缩放全程 int64 有理数运算，中间不落浮点
- `Rescale(target)` 非整除**必须**显式指定舍入方向（Floor/Ceil/Round），无默认行为 —— 关系 seek 语义
- 约分要约到**公共 timescale** 而非最简分数
- 溢出：`INT64_MAX+1` 相加、`INT64_MAX×2` 重定标均返回 `ChqStatus::kOverflow`，不静默环绕
- 溢出边界：24h@60000 = 5.184e9，1y = 1.89216e12，INT64_MAX = 9.22e18 → 理论上限约 4.87e6 年

### ADR-0009：项目 timescale 已修订为 120000（2026-09-25 决策，勿改回）

ADR-0006 原定 60000，理由「可被 24/25/30/60/1001 整除」经实测**证伪**：
60000 不能被 24000 整除（= 2.5）→ 23.976fps 单帧周期 = 2502.5 tick，非整数。
（119.88fps 同理，500.5 tick。）23.976 是电影/专业内容主流帧率，不是边缘情况。

**决策：改 120000**（= lcm(60000, 24000) = 2⁶·3·5⁴）。
实测覆盖度：@60000 不精确 2 种；**@120000 不精确 0 种**（NTSC 全家 + 24/25/30/50/60/120）。
int64 上限 @120000 ≈ 243 万年（原 487 万年），仍远超需求。

**关键澄清：这不排斥「素材保留原生 timescale」**（ADR-0006 第 33 行仍有效）。
改的是**项目时间轴网格**；`ChqRationalTime` 本身仍可携带任意 timescale，两者互补。

改动点：`kProjectTimeScale`（time.h）、依赖它的断言、文档。
现在改成本最低 —— 仅 CORE-001~004 用到，Platform 接口（CORE-006）尚未开始。
单测 `TestProjectTimescaleCoversAllFrameRates` 固化覆盖度，并断言常量 == 120000 防止回退。

## CORE-002 `ChqStatus` — `engine/core/cq/base/chq_status.h` / `engine/core/cq/base/chq_status.cpp`

稳定数值错误码，跨端一致；不用异常（红线），一律返回值传播。

| 分类 | 码值 | 说明 |
|---|---|---|
| IO | 1000–1099 | kIoError/NotFound/Permission/Timeout |
| 解码 | 2000–2099 | kDecodeError/Unsupported/NoKeyframe |
| 编码 | 3000–3099 | kEncodeError/Unsupported |
| 格式 | 4000 | kFormatUnsupported |
| 资源 | 5000 | kResourceExhausted |
| **取消** | **6000** | **kCancelled —— `IsError()` 返回 false，是独立停止信号而非错误** |
| 参数 | 7000 | kInvalidArgument |
| 数值 | 8000 | kOverflow |
| 内部 | 9000 | kInternal |
| 未知 | 9900 | kUnknown |

与 CORE-005 `ChqCancelToken` 的分界已在注释约定（本期未实现 ChqCancelToken）。

## CORE-003 `Log` — `engine/core/cq/base/chq_logging.h` / `engine/core/cq/base/chq_log.cpp`（原 `base/chq_log.h`，已更名）

- 分级：Error / Warn / Info / Debug / Trace（Trace 可编译期剔除，Release 无开销）
- **Sink 可注入**：本模块**不**硬写 stdout/stderr，也不实现任何平台后端。
  iOS(os_log) / Android(logcat) 由 Platform 层（CORE-006 之后）提供实现。本期只给 sink 接口 + 默认 FILE* 实现
- **帧级 trace**：帧标识用 `ChqRationalTime` 的 pts，**不是**裸 int64，更不是 double 秒。
  媒体管线可按「哪一帧 + 哪个环节」追溯
- 单测 25 项，0 失败（覆盖级别过滤、Sink 注入、帧标识类型、阶段名可读）

## CORE-004 `Alloc` — `engine/core/cq/base/chq_alloc.h` / `engine/core/cq/base/chq_alloc.cpp`

- `ChqLinearArena`：bump 分配 + Reset（帧级临时数据的典型用法）
- `ChqFixedPool`：定长块借出/回收
- **`ChqTextureBudget` 纹理预算记账**：GPU 纹理是移动端最稀缺资源，可查询当前用量/上限，
  超预算返回 `ChqStatus::kResourceExhausted`(5000)。**只做"账本"，不定义任何 GFX 接口**（GFX-001 的事）
- 线程安全用 `<atomic>`/`<mutex>`（未实现 CORE-005 的并发原语）
-   单测 158 项，0 失败；含 8 线程 × 10 张 1MiB 并发登记 → UsedCount=80、UsedBytes=83,886,080 (80.00 MiB)

## CORE-005 `concurrency` — `engine/core/cq/base/chq_concurrency.h` / `engine/core/cq/base/chq_concurrency.cpp`（2026-09-25）

> 写集（边界内，未碰 CORE-001~004 头文件、未碰 platform/）：
> `core/include/cq/base/chq_concurrency.h`、`core/src/base/concurrency.cpp`、`tests/unit/base/test_concurrency.cpp`（旧路径，当时如此）
> `core/CMakeLists.txt`（加 `concurrency.cpp`）、`tests/CMakeLists.txt`（注册 ctest `core_concurrency`）

并发原语提供「必要的最小集合」——**只** ChqCancelToken（协作取消）+ ChqBoundedQueue（背压）。
不造线程池 / 读写锁 / future 封装（那属于 CORE-008 线程模型骨架）；`std::mutex`/`std::atomic`
直接沿用（CORE-004 已定此先例），不封装。

### ChqCancelToken（本任务重点）
- 共享状态：`shared_ptr<State>` 持有 `std::atomic<bool>`，使 token 可**值拷贝**并分发给多个
  worker 线程，共享同一取消标志（一个 source 请求，多方感知）。
- 协作式：长任务在 pass 边界 / 解码边界轮询 `IsCancelled()`；不传取消原因、不加回调/监听
  （避免额外加锁 —— 与「音频线程禁锁」红线冲突，且属过度设计）。若未来需区分取消原因，
  在 State 增 reason 字段即可（本期不动）。
- **语义闭合**：`Cancelled()` / 便捷函数 `CancelledStatus()` 返回 `ChqStatus{kCancelled}`；
  其 `IsError()` 为 false（CORE-002 已定，`static_assert` 在头文件与单测双重固化：
  kCancelled==6000 且 `!IsError()`）。调用方据此区分「用户取消 → 清理退出」vs「文件损坏 → 失败」。

### ChqBoundedQueue<T>（背压，ARCH-001 §6 铁律）
- 队列满的三种行为（验收要求）映射到 API：
  | 需求 | API | 行为 |
  |---|---|---|
  | 阻塞 | `Push(v, token)` | 满则阻塞直到有空间或被取消（可被取消唤醒） |
  | 丢弃 | `TryPush(v)` 返回 false | 调用方直接丢弃新帧（推理/预览丢帧） |
  | 返回 ChqStatus | `Push(v, token)` 被取消 → `kCancelled` | 非错误停止信号；若不允许阻塞，用 `TryPush` 的 false 自行映射本域 ChqStatus |
- 设计选择：背压优先「暂停」而非「失败」——满队列在预览场景应让上游暂停，而非抛错。
- 多生产者 / 多消费者安全（mutex + 双条件变量）；`T` 须可拷贝或可移动。

### 取消及时性（UI 响应性关键）
- 阻塞 `Push/Pop` 用 `cv.wait_for(1ms)` 步长轮询 `token.IsCancelled()`，同时正常入队/出队
  `notify_one`。故即使另一端已退出、无人 notify，取消请求也能在 **≤ ~1ms + 调度延迟**内唤醒
  阻塞方（远小于主线程 16ms 预算），无需在 token 上注册回调。实测取消延迟 **0.061ms**（见下）。

### ⚠️ 关键教训（已踩坑，记此防复发）
- `std::condition_variable::wait_for(lk, dur, pred)` 的语义是：**超时即返回 `pred()` 的值，并不会
  循环到 `pred()` 为真**。早版误写为 `wait_for(lk, 1ms, pred)` 后无条件 `front()`，导致正常阻塞
  （队列空、未取消）在 1ms 超时后 `pred()==false` 仍返回，随后对**空 deque 调 `front()`**——
  UBSan 抓到 `load of null pointer in deque::front`（SIGSEGV）。**修复**：改为显式
  `while (cond && !cancelled) { cv.wait_for(lk, 1ms); }` 守护，仅在「有元素/有空间」或「被取消」时
  离开等待（Push 同理，否则会在满队列上越界 push 破坏有界不变量）。
- 配套：单测 stdout 改无缓冲（`setvbuf(_IONBF)` + `Check` 内 `fflush`），否则管道/文件下全缓冲会
  掩盖进度、把「卡在第几个用例」藏起来；每个阻塞用例包 `WithTimeout` 护栏（超时即请求取消解除 cv
  阻塞并判失败，而非让 CI 挂死），外加 30s 全局看门狗兜底。

### 与 CORE-004 `ChqTextureBudget` 的关系（未改动，说明理由）
- **不动 `alloc.*`**。ChqTextureBudget 是「预算账本」（计数），无阻塞等待 / 队列 / 取消需求；
  其超预算返回 `kResourceExhausted(5000)` 与队列满（背压，应暂停而非失败）语义正交、职责不同。
  改用本任务原语既无必要也引入无关改动，故保持独立。

### 单测（`tests/unit/base/test_concurrency.cpp`，ctest `core_concurrency`）
- **32 项检查，0 失败**。覆盖：ChqCancelToken 基础 / 共享状态 / 语义闭合（static_assert + 运行期）；
  取消及时性（阻塞 Pop 被取消 0.061ms 返回）；正常路径不受影响；队列满（容量 3、第 4 次 TryPush
  返回 false）；满队列取消中断（返回 kCancelled 且非错误）；并发一致性（4 生产者×1000 / 4 消费者，
  produced=consumed=4000，sum=7998000 与期望一致，无丢失/重复/卡死）。

## 约束遵守（重要，勿回退）

- `-Werror` 零警告：警告集合含 `-Wconversion`，时间/分配代码里的 int64/int32 混用
  **一律 `static_cast` 修掉，禁止 `-Wno-*` 逃逸**（INFRA-002 红线）
- 头文件零平台类型；不抛异常；不含任何 Apple/Android/鸿蒙 API
- 单测落地 `tests/unit/base/test_{time,status,log,alloc}.cpp`，由 `tests/CMakeLists.txt` 注册为 ctest

## 下一步

- ~~CORE-005~~：并发原语 / 有界队列 / `ChqCancelToken`（已完成，2026-09-25）
- **CORE-006**：Platform 接口冻结（GFX/Media/Audio/Inference/FS/Clock/Log/Capabilities），依赖 CORE-001~005
  —— **base 层前置已全部就绪，现在可以冻结全部平台接口**

## CORE-010 · 日志 ChqWorkflow 维度（2026-10-06，已完成）

任务卡：`docs/tasks/TASK-CORE-010.md`；触发原因：MEDIA-027 排障暴露「日志没有链路这一维」。

### 装配形状（记住这三份文件的关系）

```
core/include/cq/base/chq_log.h       ← ChqWorkflow 枚举 + 筛选/提级 API + CQ_LOG_*_WF 宏族（旧路径，当时如此）
core/src/base/log.cpp            ← Logger 单例：min_level_ + wf_mask_ + wf_level_[]（-1=回落全局）（旧路径，当时如此）
core/include/cq/base/chq_perf.h      ← ChqSlowCallAlarm（带 workflow，Release 可用）（旧路径，当时如此）
core/include/cq/cq_sdk.h         ← C ABI：cq_log_configure_from_env() / cq_log_set_level()（旧路径，当时如此）
api/swift/Sources/ChuanqiCut/ChuanqiCut.swift ← Swift 投影：LogWorkflow / ChqLogLevel / configureLogFromEnvironment()
```

### 三维正交（别把 ChqWorkflow 和 ChqPipelineStage 混为一谈）

| 维度 | 答什么 | 面向 |
|---|---|---|
| Level | 多详细 | Trace/Debug/Info/Warn/Error，Release 下 Trace 由宏层编译期剔除 |
| Stage | 帧走到哪一步 | 只用于带 pts 的帧级 trace；`WorkflowForStage()` 让它自动继承链路标签 |
| **ChqWorkflow** | **我在排查哪条链路** | core/model/import/demux/decode/framecache/preview/render/export/camera/gfx/perf/mem/ai |

`WorkflowForStage()` 的意义：帧级 trace 不用改签名就能带上链路前缀
（`[wf:decode][decode][pts=...]`）。

### 关键决策与理由

1. **不用结构化 `Emit(ChqWorkflow, ...)` 接口**：那会 break 所有已有 sink。改为把 `[wf:xxx]`
   拼进 message —— 向后兼容且 grep 友好。将来要结构化再叠 `EmitEx`。
2. **过滤在格式化之前**：`logger.ShouldEmit(wf, level)` 先判，通过才 `vsnprintf`。
   逐帧日志走几十万次，一次格式化是真金白银。
3. **per-workflow 覆盖优先，全局兜底**，不是「两者取更严」。这样能把一条链路单独
   提到 Trace 而不引爆其它链路。
4. **环境变量解析非法时忽略，绝不猜默认值**；特别有一条 —— `CQ_LOG_WORKFLOW` 全段
   非法时回落到**全开**而不是全关（全关等于一声不响地关掉所有日志，最容易误伤）。
5. `ConfigureLogFromEnv()` 是**显式调用**而非隐式全局初始化：隐式初始化让「日志何时
   生效」不可预测，也给静态库消费者带来副作用。App 在 `init()` 里最早处调。

### 单测

`tests/unit/base/test_log_workflow.cpp`，ctest `core_log_workflow`，10 组用例：
名字/位唯一性、环节→链路归属、掩码白名单、独立提级、Warn 在 Release 可见、
Trace 在 Release 编译期剔除、帧 trace 继承链路前缀、env 正常/非法值、慢调用阈值。
Debug 43/43、Release 43/43（本机门禁 PASS=9 / FAIL=0）。

### 约束遵守

- `chq_log.h` 只用 C/C++ 基础类型、`std::atomic`、`const char*` —— 零平台类型（红线 #2）
- **禁止 `strcasecmp`**：它是 POSIX 不是标准 C++，会把平台约束带进 base 层。
  自己在 `log.cpp` 写了 `EqualsIgnoreCase()`（先转 `unsigned char` 再喂 `tolower`，负 char 直接传 int 是 UB）
- 补了 `#include <cstdio>`：之前 `chq_log.h` 用了 `FILE`/`stderr` 却指望调用方替它 include，
  `chq_perf.h` 一 include `chq_log.h` 就炸 —— 头文件必须自洽

---

## 代码风格基线（INFRA-034，2026-10-16 落地 `.clang-format` / `.editorconfig`）

`.clang-format` 是**描述现状**的配置（Google 基 + `IndentWidth: 4` + `AccessModifierOffset: -4` +
`ColumnLimit: 0` + `ReflowComments: false` + `DerivePointerAlignment: true` + `SortIncludes: false`），
不是理想态。每个选项都由实测变体计数反推（见 `.clang-format` 头部），冲突时以"能否 -Werror 编译 +
是否描述现状"为准。

违规基线（本机实测，`Apple clang-format 21.0.0`，`--dry-run --Werror` 逐文件计数）：

| 范围 | 违规 / 文件数 | 口径 |
|---|---|---|
| `engine/**/*.h` | **48 / 65** | 手工对齐的尾注（`AlignTrailingComments` 语义）无法被任何配置保留 |
| `engine/**/*.cpp` | **21 / 40** | 同上 + 局部指针风格混用 |
| `engine/**/*.mm` | **10 / 10** | ObjC++ 全部违规（`^` 指针对齐与 `@interface` 缩进） |
| `engine/**` 合计（h+cpp+mm+c） | **79 / 115** | `tools/ci/check_repo_hygiene.sh` 的 INFO 行口径 |
| `tests/**`（cpp/c/h） | **34 / 51** | 与 engine 同一份配置 |

**本批不重排任何源码**（红线：重排会把 300+ 文件塞进布局整改批，diff 淹没真实改动）。
违规数**只做 INFO、不做红闸**的理由与 P146/P153 同源：恒红的判据最后都是被人加 `|| true` 废掉，
不如一开始就把"当前是多少"写成可对照的数字。重排另开卡、按模块分批，每批窄检 + 双壳。

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| ChqTask ID | 标题 | 状态 |
|---|---|---|
| CORE-001~010 | 内核基础各卡 | 状态见 BACKLOG §2（现状口径：core 45/45 双配置） |
| INFRA-025 | 内核 Chq 前缀改名（ADR-0039，189 类型 + 83 文件） | ✅ 2026-10-11（本机，模块级验证过） |
| INFRA-026~035 | **仓库布局整改批**（ADR-0044：`ui/` · `api/swift/` · `engine/shaders/` · `tests/unit/<module>` · 治理补齐） | ✅ 026~033/035 已绿；**034 末批 2026-10-16 本机全量门禁 + 双壳收口**（整批**尚未 commit**，等传哲点头） |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| 2026-10-07 | 全量门禁 | PASS=9 / FAIL=0 / SKIP=0（core-dbg 45/45、core-rel 45/45） |
| 2026-10-09 | INFRA-024 目录共置 + 双 Pod 拆分 | **全量 ctest 46/46**（Debug；机器 macOS 26.7.1 / AppleClang 21 / cmake 4.4.3）。头文件由 `core/include/cq/**` 迁到 `core/cq/**` 与实现共置，CMake include root 改 `engine/core`，`#include "cq/..."` 不变；`platform_header_gate` 加契约目录白名单后 38 头 0 违规（P95）。**Release 与双壳构建未跑** |
| 2026-10-11 | INFRA-025 内核 Chq 前缀改名（模块级） | `build_core.sh --platform=apple` **Debug + Release 双配置 -Werror 全过**；**ctest 48/48**（154.5s，含 test_c_abi*.c 纯 C ABI 三卡零改动全绿）；check_platform_headers **41 头 0 违规**；golden **21/21** 齐备（python3.12）。`cq_sdk.h` 声明区 diff=0。收尾批：xcframework 三切片重建 + **bindings swift test 26/26**；修复 third_party ffmpeg 门禁（三 SDK 切片选择）与壳工程 Pods 远程依赖三件缺失（P108，edit_project.rb add-remote-dependency）→ **macOS（x86_64）+ iOS generic device（arm64）双壳 BUILD SUCCEEDED**（清 DerivedData 干净口径）。池 [13] 关；[14] = mac 通用双 arch × CP 1.17 兼容头 |
| 2026-10-16 | INFRA-029 + 030 单测夹具与测试树布局整改（全量门禁） | **PASS=15 / FAIL=0 / SKIP=0**（exit 0，`build/gate-logs/` 本次日志，非沿用）。ctest **Debug 52/52** 133.05s、**Release 52/52** 226.96s；头纯净性 **43 头 0 违规**；图层卫生 **119 文件 R1 违规 0**；golden **built_ok=21 / built_fail=0 / unbuilt=0 / 901784 bytes**。目录形态：`tests/unit/` 51 个源文件按 **12 个模块子目录**（abi/ai/audio/base/command/gfx/media/model/platform/preview/render/session）重排，`add_test(NAME …)` **52 条一字未动**、`ctest -N` 迁移前后 diff 为空；edit_plan 夹具 59 个由 `engine/core/cq/ai/plan/edit_plan_golden/` 迁到 `tests/golden/edit_plan/`（`CQ_EDIT_PLAN_GOLDEN_DIR` 随之注入）。`platform_apple_decode` 本轮 Debug 8.72s / Release 10.74s 双过（同日全量段曾以 147/150 帧假失败一次，见 P147）。**双壳构建（P129 配方）4 步 exit 0 全过**：ios `pod install` 14 dependencies / 14 pods、mac 7 / 7，`Podfile.lock` 两份**零 diff**（搬家未触碰 pod 根）；ios `xcodebuild -scheme ChuanqiCutApp -destination generic/platform=iOS` **BUILD SUCCEEDED**（error 0 行，warning 24 行全为既有 deployment-target 9.0 与 SHADER-001 run-script 无输出项告警）；mac `-scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES` **BUILD SUCCEEDED**（error 0 行，warning 6 行） |

| 2026-10-16 | **INFRA-034 治理补齐 + 整改批末批收口**（全量门禁 + 双壳，本机=集成机） | **17 步全量门禁 PASS=17 / FAIL=0 / SKIP=0**（exit 0，墙钟 **10m57s** 暖缓存；步数 15→**17**：新增 `api-doc`、`ios-compile`，原内联 `artifacts` 并入 `hygiene`）。ctest Debug **52/52** 78.96s、Release **52/52** 74.55s；headers **43 头 0 违规**；layer-hygiene 两趟 **119** R1 **0**；包段 bindings **26** / player **52** / camera **77** / import **16** / editor **81** = **252** 与前四批逐字相等；golden **21/0/0 901784B**。新增四条判据全绿：`check_repo_hygiene.sh` **4/4**（tracked **856** 产物 **0**、旧路径非豁免 **0**（23 行 raw 全带迁移标记）、editorconfig 四条件 **0**、clang-format **INFO 79/115**）；`gen_api_reference.py --check` 全文比对（`engine-api.md` 516→**538 行 / 95 块 / 11 子节**）；`check_ios_compile.sh` P146 收口（`nm` 取证 `RegisterSessionObservers` **ios-device 4 / ios-sim 3 / macos 0**，暖 **2~6s**）；`linkcheck_docs.py` **10 → 0**。P145 负向测试：`PYTHON_BIN=/bin/ls` 强制首步红 → exit **1**、摘要**仅 1 行**、未执行步零行、遗留日志开跑即清。双壳（P129 配方）：ios **14/14 pods** + mac **7/7** 均 **BUILD SUCCEEDED**（error **0**；warning 24/11 行——**行数不可比**，见 baselines 口径），壳内 `*.metallib` **9215/5792/8118B** 与 031 基线逐字节相等、`blit_msl.h` **1689B** = 033 数字 → 壳吃的是 `engine/shaders/portable/`。⚠️ 踩坑：非交互 shell 无 `LANG` → `pod install` 在 Ruby `unicode_normalize` 崩（**P159**）；`if cmd; then …; fi` 后读 `$?` 恒 0（**P158**）；`git ls-files` 不带 `-z` 漏检中文文件名（**P155**）；批量替换二次改写「原 」标注（**P156**）；未提交批里 `git checkout --` 销毁本批工作、靠保险提交恢复（**P157**）。**远端 workflow 首跑未验证**（core 段的本机等价复现是**次日**才跑的，且第一遍就是红的 —— 见 2026-10-17 行与 P160）。

| 2026-10-17 | **P160/P162：CI core 段干净复现 + shader 工具链装配脚本落地**（本机 = 集成机，`rm -rf build` 逐遍重装） | 首次复现（未装工具链）**红**：`build rc=2` → `cq_shaders_msl.dir/all Error 2`，`ctest rc=8`、`2% tests passed, 50 tests failed out of 51`（全是 `Could not find executable`）→ 根因 = **构建期第三方工具只在本机暖缓存里，仓库无脚本产出**（P160）。修复主体 = 新增 `tools/build/build_shader_toolchain.sh`（pin 读 `third_party/manifest.toml`）+ `ci.yml` 在内核构建**之前**插入装配步。**干净复现四遍**：run1/2/3/4 toolchain rc=0 / build rc=0 / **ctest 51/51 rc=0**（186.74s / 172.84s / 271.32s / 83.52s），四遍都显式打印排除名单 `Test #45: platform_apple_decode`；run2/run4 `hygiene rc=0`（4/4 PASS）。产物字节跨遍稳定：glslang **3 133 560 B**、spirv-cross **4 155 984 B**、`blit_msl.h` **1689 B**；干净单遍 **6m48s~11min**（run4 整段 09:42:02→09:48:50）。⚠️ ctest 墙钟四遍差 3 倍以上 → **本机 ctest 墙钟不可当指标**，只有 rc 与通过数可比。负向测试抓到两处脚本自身缺陷并修（**P162**）：`--check-only` 名义只读却走 `rm -rf` 分支、补丁指纹守卫拿 `:STRING=` grep 而裸 `-D` 在 cache 里是 `:UNINITIALIZED=`（恒不命中 → 每遍误删重编）；修后暖态完整跑 = 两工具均 `跳过编译`、"强制重编"零行，暖态 `--check-only` = 产物 md5 跑前后逐字节一致，藏 `glslang` 则 rc=**1** 报 `产物缺失`、恢复后 rc=**0**。⚠️ **口径更正**：10-16 的 `PASS=17` 与本模块册此前所有"绿"都**只在暖缓存上成立**，构建期依赖层从未进判据；今后引用"绿"必须同时说明缓存状态。未做：workflow **远端首跑**仍未验、CI 的 **FFmpeg 装配步**本机未复现、池 **[22]**（90 个 tracked 文件仍用上上代 `core/include/cq/**`，hygiene 判据射程外）、池 **[23]**（本机 SPIRV-Cross **不入库本地补丁**，待传哲判定） |

| 2026-10-17 | **INFRA-026~035 落库（三段提交）+ P163：判据脚本提交后把自己判红**（本机 = 集成机，**未 push**） | `294d518` 搬家（294 路径，`R100` 222）/ `a7a20b8` 治理（12 路径）/ `b08f78a` 活文档（91 路径）+ P163 修复段；`origin/main` 仍在 `5cfcdcb`。**提交后复测 hygiene 由 4/4 掉到 3/4**：`[legacy-paths]` 命中 `check_repo_hygiene.sh:124-125` **自己的旧路径正则定义行** —— 双层根因 = ① 扫描集取 `git ls-files`，脚本当时是 `??` 未跟踪、**长期不在自己射程内**；② 唯一豁免通道 `MARKER` 按行内容放行，代码行不可能带迁移标记。修 = `SELF` 排除自己（显式声明"判据不参与自己的判据"）→ **4/4 PASS**，`[legacy-paths] 零残留（豁免 33 行）`，**tracked 856 → 878**（22 个新入库文件）。规则：**新判据必须在自己已被跟踪的状态下再跑一遍**，未跟踪态的绿只算半个证据；提交动作本身是判据的输入变量 → 收尾一律取提交后那一列。已知归属错位：`build_shader_toolchain.sh` 实际落在搬家段而非治理段，已在两段正文声明，**以 `git show --stat` 为准**。 |
| 2026-10-17 | **INFRA-036/037（池 [22]/[18] 收口）：死路径判据扩三代根 + 双壳进总门禁**（本机 = 集成机） | hygiene **5/5 PASS**（新增判据 5 `scratch-dirs`；legacy 非豁免 **0**、豁免 33→**64**；tracked **878** 不变；clang-format INFO 79/115）；`check_apple_shells.sh` **冷 280s / 暖 39s** 两端 rc=0 error=0、pod install 14 pods；`build_core.sh --config=Debug --test` **52/52** real 111.55s；改动面 50 文件 +217 −158。**P164**：`-derivedDataPath ../../build/…` 在 `cd apps/apple/ios` 之后落到 `apps/build/`（**1.5G**）→ 绝对路径 + 前缀断言 + 跑完自查 + 判据 5 三层防复发。测量途中我自己把 `TASK-BACKLOG` 的 INFRA-035 行用「行首做锚点」的编辑方式撞坏（尾串跑到新行后），已按 `git show HEAD` **逐字节 cmp 复原**。**未做**（本行写作时）：全量门禁当时步数记为 16（**实为 18**，见下一行更正）、iOS 模拟器壳。 |

| 2026-10-17 | **INFRA-036/037 落库 + 18 步全量门禁实测 + 并行度 A/B（P166）**（本机 = 集成机，**提交到本地、未 push**） | 上一行「未做：全量 16 步门禁」已作废——`run_gate.sh` 无参数实跑 **PASS=18 / FAIL=0 / SKIP=0**，墙钟 **≈20m40s**（core 52/52 ×2、六包 252、双壳暖 44.5s、hygiene 5/5 且**提交后复跑**）。每步时长由日志 mtime 反推（脚本不记时长）：`core-dbg` **379.0s** + `core-rel` **438.4s** = **817s / 66%**，`apple-xcframework` 暖态只 **17.3s** → **P166**：我先前"三切片最贵"的结构推断被自家实测推翻，成本结论一律要实测。**根因与优化项**：`build_core.sh:85` / `build_core_apple.sh:178` 的 `cmake --build` **都没传 `--parallel`**（Unix Makefiles，12 逻辑核全程单线程；全仓只有 `build_shader_toolchain.sh` 传 `-j`）。同脏集 A/B 实测 **254s（73 TU）→ 70s（72 TU）= 3.6×** → 立 **INFRA-038（待批准，未开工）**。commit：`ae50a68` INFRA-036 / `4595865` INFRA-037 / 本段收尾文档 commit；`origin/main` 仍在 `55653bf`。**模拟器切片**：传哲先「没必要支持」、同轮改判「**先不动**」→ 冻结为池 **[24]** + **INFRA-039**（**同轮口径更正**：本行初稿写「`check_ios_compile.sh` 当前正吃 `ios-sim` 树、须先改指 `ios-device`」是错的，脚本第 37 行默认就是 `ios-device`；前置因此只剩「`build_core_apple.sh:199` 停产 sim slice」+「池 [16] 改判明确不支持」，外加清 `--slice` 的 simulator 死选项。sim slice 收益**无实测数字**，测量跑一半即停）。 |
| 2026-10-17 | **INFRA-038 门禁 C++ 段并行化（上一行那条"待批准，未开工"的卡，落地并实测）**（本机 = 集成机，传哲「开工」+「推」） | 三个 `cmake --build` 调用点全补 `--parallel "${CQ_JOBS}"`（`build_core.sh:88` / `build_core_apple.sh:181` / `check_ios_compile.sh:77`，核数默认 `hw.ncpu`=12，可用 `CQ_JOBS` 下调排障）。**全量门禁 PASS=18 / FAIL=0 / SKIP=0，墙钟 568s = 9m28s**（串行基线 1240s → **2.18×**）；`core-dbg` 379→**198s**、`core-rel` 438→**213s**，Debug/Release 各 **52/52**、`-Werror` 仍生效，六包 **26/52/77/16/81** 逐字相等（digest 未失配、未放宽正则）。`run_gate.sh` **开始自记每步时长**（摘要行末 `[Ns]` + 末行「墙钟/合计对账」，本趟差 **0s**）→ P166 的观测缺口关闭。Apple 三切片冷构建 **8m20s → 151s**（rc=0、smoke-link 过、重编 150 TU = 全量），`check_ios_compile.sh:19` 换数、旧数留 `TASK-INFRA-034` 不改写。**两条口径被本轮按实测纠正**：① 12:0x 外推的"全量 ~10min"作废——`--parallel` 只压构建段，ctest 一点没动，所以步骤墙钟只降 1.78×（独立实测 251s/208s）；加速比必须指明是**哪一段**的。② **P167**：同一版本脚本、同一棵树，"暖"的 `build_core_apple.sh` 实到 **91s / 重编 57 TU**，不是 17.3s 的 no-op → "暖"不是数而是状态，引用暖值必须附「重编几个 TU」；两条候选成因（两脚本共用 `build/apple/ios-device` 但 configure 参数不一致 / 每切片重跑 configure）**均未取证**。另记 **P168**：后台任务通知 `completed exit 0` 时任务实际只跑到 88%、输出文件为空——通知不是验收口径，取数要看日志结束行 + `ps` + 自写计时行。**未做**：ctest 保持串行；`media_sequential_real` 单例占 ctest **58%**（池 **[26]**）、Debug/Release 共用一棵 `build/`（池 **[25]**）——两条都是候选，待传哲判。 |
| 2026-10-17 | **INFRA-038 追加趟：门禁自出报告 + `build/ctest` 拆分取证**（本机 = 集成机，同档复跑） | `--fast` 档实跑 **PASS=8 / FAIL=0 / SKIP=3**（行数 11，墙钟 **239s**，`core-dbg` 225s）；全量档复跑 **PASS=18 / FAIL=0 / SKIP=0，墙钟 427s = 7m07s**（上一趟 568s，差 **141s 全是缓存态** → **P171**：引用时长要带档位+缓存态+拆分，跨趟只用比例）。新脚本 `write_report()` 每趟落 `build/gate-logs/gate-summary.md` + `gate-history.tsv`（不入库）。**两步拆分取证**：`core-dbg` 113s = **0 个 TU** + ctest **107.63s**；`core-rel` 207s = **95 个 TU** + ctest **136.49s** → 池 **[25]**（Debug/Release 共用一棵树）从推算变计数，池 **[26]** 的 `media_sequential_real` 本趟 **58.23s = Debug ctest 的 54%**（独立实测时 113.88s，**同一用例两趟差 2×**）。ctest 两段合计 **244s = 全程 57%** → 拆树也拆不掉的**下限 ≈6min**。⚠️ `write_report()` 首版踩 **P170**（`{ } > file` 里的 `return` 从函数返回 → tsv 一整条没写、末行没打、**门禁仍 rc=0**：判据自己的记账坏了不会响）。 |
| 2026-10-17 | **INFRA-043 版本批节奏 + ctest `heavy` 分档 + `gate_scope.sh` 路由**（本机 = 集成机，**按新规矩：本批不跑 18 步全量**） | 传哲命题「门禁要搞成一个小版本统一跑，别写个小功能就在那跑门禁浪费时间」→ 批次口径选**显式小版本号**（根 `VERSION` 为唯一真源，根 `CMakeLists.txt` 与 `run_gate.sh` 都从它读；批账在 `docs/reports/VERSIONS.md`），ADR-0030 §4 的"阶段批"换成 **L0/L1/L2/L3** 四层，**开发会话跑 L3 本身即违规**（真源 §验证分四层，5 份生成物已重刷）。**分档实跑**：`LABELS "heavy"` **14** 例，计数三件套 `-L 14` + `-LE 38` == 总 **52** 才算真打上；Debug 档 ctest **107.55s → 15.17s**（0 TU 暖态，**7.1×**）、Release 档不带 flag 仍 **52/52**（ctest **151.55s**，切配置重编 **95 TU**）、`--fast` 全档 **239s → 100s**（PASS=8/FAIL=0/SKIP=3，墙钟/合计差 0s）。**成本重心迁移**：分档后 `core-dbg` 整步仍 **86s**（构建 ≈70s / 95 TU + 测试 38.53s）→ 池 **[25]**（两档共用一棵 `build/`）现在是主要浪费，不再是 ctest 重复；**全量档 ≈344s 是推算 `[E]`，本批未实测**。**门禁产物**：`gate-history.tsv` 加 `version`/`batch` 两列并就地迁移（9→11 列，历史行补 `-`；新列只加行尾，加中间会把数字念错列）。**两个新坑**：**P172** `if(TEST _t)` 恒假（必须 `${_t}`）→ 分档以"更快"的姿态**静默失效**，被"跳过名单必须打印"这句设计当场抓住；**P173** `git diff --name-only` 把中文文件名八进制转义 → 路由对本仓最常见的文件类型**永久假阴**，且错向是"升档"（看着安全，一周后没人再用这工具）。`gate_scope.sh` 只读、六类样本各给不同窄检、podspec 必含双壳、陌生文件判升档。**同批两处声明式订正**：ADR-0046 初稿「CMake `project()` 不带版本」（实为 `VERSION 0.1.0`，本批改成从真源读）与「CI Debug 与本机同口径」（**改判：CI 保全 52 例**，充当 heavy 在 Debug 档的唯一覆盖点）。**未做**：L3 首趟（留给下一版本批 v0.2.0）、CI 远端首跑、池 [25]/[26] 待传哲判、`Info.plist` 的 `1.0` 与真源不一致仍挂待办。**提交后自查另立 P174**：本卡三处把归口写成不存在的 `.ai/modules/infra.md`（实际 = 本册），三条门禁全绿放行，取证 = `linkcheck_docs.py:61` 叙述域豁免反引号路径 + `:65` 只查 `docs/`/`../` 前缀；已订正并把「回写目标」改写成 Markdown 链接。提交 `e4bbde5`（已推送）。 |
| 2026-10-17 | **INFRA-045 Draft 包进门禁 + INFRA-046 全库 clang-format 重排 + v0.1.0 首趟 L3**（本机 = 集成机，传哲「infra先搞完再看编辑相关的」） | 收尾范围由集成机判定（传哲对"收尾做什么"答 *No preference*，**不是他的裁定**）。**INFRA-045**（收池 **[21]**）：`run_gate.sh` 加第 19 步 `apple-draft`，用 **`swift build` 不是 `swift test`** —— 该包零用例，实测 `swift test` **rc=1**（`error: no tests found`）、`swift build` **1.54s / rc=0**；判 build 还是 test 只看 `ui/<pkg>/Tests` 存不存在（六包实测：SharedUI/Draft 无，其余四包有），`gate_scope.sh` R4 的 `CQ_BUILD_ONLY_PKGS` 照此 → **P177**。**INFRA-046**：全库重排 **113 文件 / +1684 −1212**（engine/core 65 + engine/platform 14 + tests/unit 34），违规 **79/115 + 34/45 → 0/168**，重排后 Debug 重编 **92 TU**、ctest **38/38**、`gen_api_reference.py --check` 与 `sync_context.py --check` 均一致；`.clang-format` 头部从"描述存量"改为"基线 = 0，非零即新代码"。**⚠️ 顺手抓到 P176**：`clang-format -i` 把仓库**唯一**的符号链接 `api/swift/Sources/ChuanqiCutCore/include/cq_sdk.h` 写成 38624 字节普通副本（`mode change 120000 => 100644`），**内容逐字节相同 ⇒ 全部编译/测试/头文件判据照绿**，只有 `git diff --summary` 看得见；已 `ln -s` 恢复（该路径与 HEAD 一致）。另立 **P175**：我的违规统计连报两趟 0（`--dry-run` 不带 `-Werror` 时**违规也 rc=0**；漏 `-n` 时它直接输出改写结果、恒 0），而负向反证打在**二进制**上而非**我的循环**上，所以反证"通过"毫无意义 —— 真正拆穿的是打印样本 + 与 hygiene 的独立计数对撞。**v0.1.0 L3 首趟**（2026-10-17 16:06:22→16:14:55）：**PASS=19 / FAIL=0 / SKIP=0，墙钟 513s**；`core-dbg` 20s（0 TU 暖 + ctest **15.04s/38**）、`core-rel` 199s（95 TU **冷**，被重排顶掉 + ctest **141.99s/52**）、`apple-shells` 106s、`apple-xcframework` 102s、golden 5s、包段 26/52/77/16/81 例全绿。**池 [27] 关闭**：`≈344s [E]` 作废 → **513s（Release 冷态实测）**，暖态 **≈456s 仍是 `[E]`**。**池 [25] 改「📌 挂起」**（集成机判定 INFRA-040 不立项）：拆树现在只省 `core-rel` 构建段 **≈57s/版本批**，代价是 `--test-dir build` 实测 **96 处 / 64 文件**（`BUILD.md` 原写 43 处已失效；该计数会把"引用这条命令的叙述行"也算进去，本批自测已漂到 97 → 天生会漂）且 `BUILD.md:51-52` 是**有意决定**，反转要走 ADR。**池 [26] 改「📌 维持现状」**（传哲答 *No preference* = 不反对，≠ 裁定）。**真源订正**：L3 行「全量 18 步」→「步数以脚本为准」，避免每加一步改 6 个文件（5 份生成物已重刷）。**未做**：CI 远端首跑（传哲「本批不管，继续挂着」；本机 `gh` 未安装，状态取不到）、Draft 包在 `ui-apple.md` 的归属行、真机单。**提交前追加（R12）**：`gate_scope.sh` 把 `.clang-format`/`.editorconfig` 归为 **R12**（→ hygiene + 全量，显式 `NEED_FULL=1`，**升档不降级**：射程是全库 C/C++）；规则必须写在 R11 **之后**，因为 `linkcheck_docs.py` 不在 `run_gate.sh` 的 19 步里、只在 CI，放前面会把"文档+风格配置"同批的 diff 的链接判据挤掉。R12 落地当场暴露 **P178**：`UNCLASSIFIED` 第一次为空 → bash 3.2 `set -u` 下 `"${arr[@]}"` 报 unbound，且末段**无条件**喊"把路径加进规则里"（刚归类好的文件也被叫去修一个已经正确的路由）→ 拆成 `NEED_FULL`（要不要全量）/`UNCLASSIFIED_FULL`（为什么）两位，档位标题随之分叉；`--files` 六条边界全跑，含空数组那三条。**"只是空白"的证法（提交前补）**：抽掉全部空白比校验和，113 个文件 **112 个逐字符相同**；唯一不同的 `engine/core/cq/base/chq_logging.h` 再用字符频次对撞，差别**只有反斜杠 18→32**（宏体按续行拆开），无其它字符计数变化 ⇒ 与 92 TU + `-Werror` + ctest 38/38 互为佐证；命令进了 046 卡。同批把 hygiene 的 clang-format 计数射程从 `engine/**`（115，**看不见 34 个 tests 文件**）扩到五根 pathspec = **168**，反证打在完整路径上：注入违规 1/168、还原 0/168。 |
| 2026-10-17 | **INFRA-047 commit message 硬线判据 + 三笔改写重推**（集成机） | 上一批三笔逐条满足 INFRA-042 却仍是作文：那条只数行数不数行长，标题后又无空行 → git 里 `%b` 直接为空（**P179**）。硬线 H1–H7+W1 做成 `tools/ci/check_commit_msg.py`，进门禁 2f 步（19 → 20，水位 `8478c10`）＋本机钩子（不动 `git config`）。三笔用 `commit-tree` 只改消息、tree 不变，新 sha 见 HANDOFF-026。窄检 `--fast` **PASS=9/FAIL=0/SKIP=3、101s**；⚠️ L3 未跑，不与 513s（19 步）互推。自证 8 条与建卡登记欠账（池 **[28]**）见卡与 baselines。 |

### 调研 · 决策 · 池指针

- 热点文件守门（cq_sdk.h/CMakeLists）· ADR-0011（core 不调 Platform 工厂）
