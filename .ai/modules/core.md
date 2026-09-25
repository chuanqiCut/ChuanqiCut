# 模块：core/base 内核基础

**边界**：`core/src/base/`、`core/include/cq/base/`、`core/include/cq/pal/`、`core/src/session/`

## 职责
时间、状态、日志、内存、并发、PAL 接口定义、EditorSession 门面。

## 入口
- `RationalTime` — **有理数时间**，禁止浮点秒。项目 timescale = 60000。
- `Status` — 跨端一致错误码。
- `Arena` / 内存池 — 支持纹理与帧缓冲预算记账。
- `CancelToken` — 长任务取消。
- `ICapabilities` / `cq_query_capability()` — **运行时能力查询**。
- `EditorSession` — 对外唯一门面，产出不可变快照 + 版本号。

## 依赖
无（本模块是最底层，不得反向依赖任何其他模块）

## 硬约束
1. PAL 头文件零平台类型 → 跨层用 opaque 句柄 `CQNativeImageHandle` 等。
2. 能力查询不得用编译期宏推断（Android 能力由机型决定，Apple 由芯片决定）。
3. 音频线程无锁、无分配；主线程零阻塞。
4. `RationalTime` 运算做 timescale 归一化并检测溢出。

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
CMAKE_BIN=/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake
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

## 已实现：CORE-001 RationalTime（2026-09-25）

> 写集：`core/include/cq/base/time.h`、`core/src/base/time.cpp`、`tests/unit/test_time.cpp`

- 存储 `struct RationalTime { int64_t value; int32_t timescale; }`，全程 **int64 整数运算，零浮点中间值**。
- 项目 timescale 常量 `kProjectTimeScale = 60000`（沿用 ADR-0006，未就地改值）。
- **红线守卫**：头文件 `static_assert(!std::is_convertible_v<RationalTime, double>)` 编译期禁止隐式 `double` 转换；唯一浮点出口是显式 `ToSeconds()`，注释写明仅限日志/UI，禁入计算路径。
- 运算：`AddRational` / `SubRational` / `ScaleRational`（retime，支持倒放负系数）/ `ModRational`（欧几里得，结果落在 `[0,base)`）/ `Rescale(target_ts, RoundMode)`，全部以**公共 timescale（LCM 对齐）**归一化，不约到最简分数（防 timescale 漂移到 1）。
- `Rescale` 非整除时**强制显式 `RoundMode`{Floor,Ceil,Round}**，无默认行为（对 seek 语义关键）。
- 比较用 `__int128` 交叉相乘，无浮点、无溢出。
- 所有运算溢出经 `Status`（CORE-002 的 `kOverflow`）返回，内核无异常。
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

## 已实现：CORE-002 Status（2026-09-25）

> 写集：`core/include/cq/base/status.h`、`core/src/base/status.cpp`、`tests/unit/test_status.cpp`

- **稳定数值错误码**：`enum class StatusCode : int32_t`，每个值**显式写死**（不依赖编译器自动编号），保证 iOS/macOS/Android/鸿蒙/桌面三端一致、ABI 稳定。
- 分类覆盖媒体管线：I/O(1000)、解码(2000)、编码(3000)、格式不支持(4000)、资源不足(5000)、取消(6000)、参数非法(7000)、数值溢出(8000)、内部(9000)、未知(9900)。
- **取消与错误的语义分界**：`kCancelled(6000)` 是独立「停止信号」，**不是错误**——`IsError()` 对 `kCancelled` 返回 `false`，`IsCancelled()` 专门识别；CORE-005 的 `CancelToken` 将来只产生 `kCancelled`，调用方收到后做清理而非报错（头文件已注释该约定，未实现 CancelToken）。
- **零平台类型**：头文件仅用 `int32_t` / `const char*`，无 Apple/Android/鸿蒙类型。
- **无异常**（ARCH-001「禁用异常跨模块」）：错误一律经 `Status` 返回；`Status` 为仅含 `StatusCode` 的轻量值，音频线程可安全拷贝/返回。
- 辅助：`StatusToString`（日志/UI）、`CategoryOf`（分类聚合）。
- 单测覆盖：全部码值 `static_assert` 稳定 + 分类映射 + 取消/错误分界 + 字符串。

## 实际目录（INFRA-001 + INFRA-002 建立）

> 由 `TASK-INFRA-001` 落盘的骨架路径，供后续 CORE 任务对齐存放位置（权威树以 ARCH-001 §8 为准）。

- `core/CMakeLists.txt` — 内核 CMake 入口；`cq_core` 现为**真正的 STATIC 库**（含 `src/cq_build_anchor.cpp` 构建锚点，非业务逻辑）
- `core/include/cq/cq_sdk.h` — 对外 C ABI 伞形头（占位；红线 #7：仅 C 类型 + opaque 句柄）
- `core/src/cq_build_anchor.cpp` — 构建锚点 TU（INFRA-002 新增，可链接、零业务逻辑、证明 -Werror 下可编译）
- `core/src/` — 内核源码根，按模块分子目录：`base/ model/ gfx/ render/ media/ audio/ ai/ project/ export/ session/`（尚未创建，由对应 CORE 任务建）
- `core/tests/` — 内核单测（实际落在 `tests/unit/`，见下）
- `core/include/cq/<module>/` — 内部 C++ 头（预留，未在骨架阶段创建）

## 单测目录（INFRA-002 建立）

- `tests/CMakeLists.txt` — 启用 CTest，注册内核单测（顶层 `CMakeLists.txt` 已 `enable_testing()`）
- `tests/unit/cxx20_smoke.cpp` — 占位 smoke 用例：`static_assert(__cplusplus >= 202002L)`，证明 C++20 生效；链接 `cq_core`
- 运行：`ctest --test-dir build`（或 `build_core.sh --test`）

> 注：骨架阶段仅建占位，未创建 `core/src/<module>` 子目录与真实头文件，避免越界到 CORE 系列任务的写集。

---

# base 层已实现（CORE-001 ~ CORE-005，2026-09-25）

按依赖顺序推进，为 CORE-006「PAL 接口冻结」打地基。BACKLOG 第 327 行要求：
**CORE-006 之前任何 PAL 实现不得开始**，故 base 类型必须先定型。

## CORE-001 `RationalTime` — `core/include/cq/base/time.h` / `core/src/base/time.cpp`

- `struct RationalTime { int64_t value; int32_t timescale; }`，项目统一 timescale = 60000
- **禁止 `operator double`**；`ToSeconds()` 只用于日志/UI 展示，禁入计算路径（任务卡 risk 段明确警示）
- 加减/比较/取模/缩放全程 int64 有理数运算，中间不落浮点
- `Rescale(target)` 非整除**必须**显式指定舍入方向（Floor/Ceil/Round），无默认行为 —— 关系 seek 语义
- 约分要约到**公共 timescale** 而非最简分数
- 溢出：`INT64_MAX+1` 相加、`INT64_MAX×2` 重定标均返回 `Status::kOverflow`，不静默环绕
- 溢出边界：24h@60000 = 5.184e9，1y = 1.89216e12，INT64_MAX = 9.22e18 → 理论上限约 4.87e6 年

### ADR-0009：项目 timescale 已修订为 120000（2026-09-25 决策，勿改回）

ADR-0006 原定 60000，理由「可被 24/25/30/60/1001 整除」经实测**证伪**：
60000 不能被 24000 整除（= 2.5）→ 23.976fps 单帧周期 = 2502.5 tick，非整数。
（119.88fps 同理，500.5 tick。）23.976 是电影/专业内容主流帧率，不是边缘情况。

**决策：改 120000**（= lcm(60000, 24000) = 2⁶·3·5⁴）。
实测覆盖度：@60000 不精确 2 种；**@120000 不精确 0 种**（NTSC 全家 + 24/25/30/50/60/120）。
int64 上限 @120000 ≈ 243 万年（原 487 万年），仍远超需求。

**关键澄清：这不排斥「素材保留原生 timescale」**（ADR-0006 第 33 行仍有效）。
改的是**项目时间轴网格**；`RationalTime` 本身仍可携带任意 timescale，两者互补。

改动点：`kProjectTimeScale`（time.h）、依赖它的断言、文档。
现在改成本最低 —— 仅 CORE-001~004 用到，PAL 接口（CORE-006）尚未开始。
单测 `TestProjectTimescaleCoversAllFrameRates` 固化覆盖度，并断言常量 == 120000 防止回退。

## CORE-002 `Status` — `core/include/cq/base/status.h` / `core/src/base/status.cpp`

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

与 CORE-005 `CancelToken` 的分界已在注释约定（本期未实现 CancelToken）。

## CORE-003 `Log` — `core/include/cq/base/log.h` / `core/src/base/log.cpp`

- 分级：Error / Warn / Info / Debug / Trace（Trace 可编译期剔除，Release 无开销）
- **Sink 可注入**：本模块**不**硬写 stdout/stderr，也不实现任何平台后端。
  iOS(os_log) / Android(logcat) 由 PAL 层（CORE-006 之后）提供实现。本期只给 sink 接口 + 默认 FILE* 实现
- **帧级 trace**：帧标识用 `RationalTime` 的 pts，**不是**裸 int64，更不是 double 秒。
  媒体管线可按「哪一帧 + 哪个环节」追溯
- 单测 25 项，0 失败（覆盖级别过滤、Sink 注入、帧标识类型、阶段名可读）

## CORE-004 `Alloc` — `core/include/cq/base/alloc.h` / `core/src/base/alloc.cpp`

- `LinearArena`：bump 分配 + Reset（帧级临时数据的典型用法）
- `FixedPool`：定长块借出/回收
- **`TextureBudget` 纹理预算记账**：GPU 纹理是移动端最稀缺资源，可查询当前用量/上限，
  超预算返回 `Status::kResourceExhausted`(5000)。**只做"账本"，不定义任何 GFX 接口**（GFX-001 的事）
- 线程安全用 `<atomic>`/`<mutex>`（未实现 CORE-005 的并发原语）
-   单测 158 项，0 失败；含 8 线程 × 10 张 1MiB 并发登记 → UsedCount=80、UsedBytes=83,886,080 (80.00 MiB)

## CORE-005 `concurrency` — `core/include/cq/base/concurrency.h` / `core/src/base/concurrency.cpp`（2026-09-25）

> 写集（边界内，未碰 CORE-001~004 头文件、未碰 pal/）：
> `core/include/cq/base/concurrency.h`、`core/src/base/concurrency.cpp`、`tests/unit/test_concurrency.cpp`
> `core/CMakeLists.txt`（加 `concurrency.cpp`）、`tests/CMakeLists.txt`（注册 ctest `core_concurrency`）

并发原语提供「必要的最小集合」——**只** CancelToken（协作取消）+ BoundedQueue（背压）。
不造线程池 / 读写锁 / future 封装（那属于 CORE-008 线程模型骨架）；`std::mutex`/`std::atomic`
直接沿用（CORE-004 已定此先例），不封装。

### CancelToken（本任务重点）
- 共享状态：`shared_ptr<State>` 持有 `std::atomic<bool>`，使 token 可**值拷贝**并分发给多个
  worker 线程，共享同一取消标志（一个 source 请求，多方感知）。
- 协作式：长任务在 pass 边界 / 解码边界轮询 `IsCancelled()`；不传取消原因、不加回调/监听
  （避免额外加锁 —— 与「音频线程禁锁」红线冲突，且属过度设计）。若未来需区分取消原因，
  在 State 增 reason 字段即可（本期不动）。
- **语义闭合**：`Cancelled()` / 便捷函数 `CancelledStatus()` 返回 `Status{kCancelled}`；
  其 `IsError()` 为 false（CORE-002 已定，`static_assert` 在头文件与单测双重固化：
  kCancelled==6000 且 `!IsError()`）。调用方据此区分「用户取消 → 清理退出」vs「文件损坏 → 失败」。

### BoundedQueue<T>（背压，ARCH-001 §6 铁律）
- 队列满的三种行为（验收要求）映射到 API：
  | 需求 | API | 行为 |
  |---|---|---|
  | 阻塞 | `Push(v, token)` | 满则阻塞直到有空间或被取消（可被取消唤醒） |
  | 丢弃 | `TryPush(v)` 返回 false | 调用方直接丢弃新帧（推理/预览丢帧） |
  | 返回 Status | `Push(v, token)` 被取消 → `kCancelled` | 非错误停止信号；若不允许阻塞，用 `TryPush` 的 false 自行映射本域 Status |
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

### 与 CORE-004 `TextureBudget` 的关系（未改动，说明理由）
- **不动 `alloc.*`**。TextureBudget 是「预算账本」（计数），无阻塞等待 / 队列 / 取消需求；
  其超预算返回 `kResourceExhausted(5000)` 与队列满（背压，应暂停而非失败）语义正交、职责不同。
  改用本任务原语既无必要也引入无关改动，故保持独立。

### 单测（`tests/unit/test_concurrency.cpp`，ctest `core_concurrency`）
- **32 项检查，0 失败**。覆盖：CancelToken 基础 / 共享状态 / 语义闭合（static_assert + 运行期）；
  取消及时性（阻塞 Pop 被取消 0.061ms 返回）；正常路径不受影响；队列满（容量 3、第 4 次 TryPush
  返回 false）；满队列取消中断（返回 kCancelled 且非错误）；并发一致性（4 生产者×1000 / 4 消费者，
  produced=consumed=4000，sum=7998000 与期望一致，无丢失/重复/卡死）。

## 约束遵守（重要，勿回退）

- `-Werror` 零警告：警告集合含 `-Wconversion`，时间/分配代码里的 int64/int32 混用
  **一律 `static_cast` 修掉，禁止 `-Wno-*` 逃逸**（INFRA-002 红线）
- 头文件零平台类型；不抛异常；不含任何 Apple/Android/鸿蒙 API
- 单测落地 `tests/unit/test_{time,status,log,alloc}.cpp`，由 `tests/CMakeLists.txt` 注册为 ctest

## 下一步

- ~~CORE-005~~：并发原语 / 有界队列 / `CancelToken`（已完成，2026-09-25）
- **CORE-006**：PAL 接口冻结（GFX/Media/Audio/Inference/FS/Clock/Log/Capabilities），依赖 CORE-001~005
  —— **base 层前置已全部就绪，现在可以冻结全部平台接口**
