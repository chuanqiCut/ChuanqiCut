# TASK-CORE-010 — 日志按「链路（workflow）」筛选 + 排障日志沉淀进受控设施

- 状态：**进行中**（core-dbg / core-rel 全量单测已过；本机门禁待跑完最终一轮）
- 日期：2026-10-06
- 来源：传哲「这些排查日志可以沉淀到项目中，加入 workflow 的标记，像腾讯视频的
  播放器 SDK 那样，每个流程的日志都可以单独筛选出来」
- 编号：CORE-010（取号前核对 `docs/tasks/` 水位：CORE-009 为最高，MEDIA-027 为本期下一号）
- 关联：[MEDIA-027 复盘](../reviews/REVIEW-2026-10-06-MEDIA027-播放5秒冻结与jetsam复盘.md)

## 1. 为什么要做

MEDIA-027（播放 5 秒冻结 + 3.4GB jetsam）的定位过程暴露了三件事：

1. **日志没有「我在排查哪条链路」这一维**。级别回答「多详细」、环节回答「帧走到
   哪一步」，但都回答不了「只要 decode 链路，其余闭嘴」。真机上日志洪水会淹掉
   唯一有用的几行。
2. **排查时临时加的 32 处 `fprintf(stderr, ...)` 是不受控的**：不分级、不限流、
   不能开关。其中 9 处在 Release 也会编译（详下）。
3. **赖以取胜的两个工具在 Release 包里根本不存在**：
   - `SlowCallAlarm`（4 个文件各抄一份，全是 `#ifndef NDEBUG`）
   - `Watchdog`（报出「RenderFrame 卡在 'provider+acquire' 8226ms」的那个）

   也就是说：下次用 Release 包遇到问题，什么都不会留下。

第 3 条是这次最值钱的收获 —— **Debug 才能复现的诊断设施，只对能复现的人有用。**

## 2. 精确盘点（改动前）

用脚本逐行走条件编译栈，判定每处 `fprintf(stderr` 在 Release 是否会被编译：

| 文件 | 处数 | Release 会编译 |
|---|---|---|
| `pal/apple/media_decode.mm` | 18 | **8** |
| `pal/apple/media_demux.mm` | 3 | 0 |
| `core/src/preview/preview_pump.cpp` | 4 | 0 |
| `core/src/preview/preview_renderer.cpp` | 2 | 0 |
| `core/include/cq/media/system_frame_provider.h` | 4 | 0 |
| `core/src/base/perf.cpp` | 1 | 1 |
| **合计** | **32** | **9** |

> 修正一处早先判断：一开始据 grep 认为「32 处全部无条件」。实际按条件编译栈
> 精确判定只有 9 处会进 Release。**结论依然是问题，但不是"全部裸奔"。**

## 3. 设计：三维正交

| 维度 | 答什么 | 取值 |
|---|---|---|
| **级别** Level | 多详细 | trace / debug / info / warn / error |
| **环节** Stage | 帧走到哪一步 | demux / decode / render / encode（只用于带 pts 的帧级 trace） |
| **链路** Workflow | **我在排查哪条链路** | core / model / import / demux / decode / framecache / preview / render / export / camera / gfx / perf / mem / ai |

输出格式（`[wf:xxx]` 既是给人看的，也是 grep 的锚点）：

```
WARN [wf:decode] [media_decode.mm:747] 显示序缺口 #1：连续 8 次未等到期望=420000/120000，...
```

筛一条链路：`grep '\[wf:decode\]'`
只看该链路告警：`grep '\[wf:decode\]' | grep WARN`

### 3.1 为什么不改 `ILogSink` 接口传 workflow 字段

可以让 `Emit` 多收一个 `Workflow` 参数（结构化，平台 sink 能做 os_log category）。
**没这么做**是因为那样会 break 所有已有 sink 实现（含测试里的两个抓手和将来的
os_log backend）。当前把 `[wf:xxx]` 拼进 message，向后兼容且 grep 友好。
将来真要结构化再叠加一个 `EmitEx`，不是现在这个任务的成本。

### 3.2 语义（重要）

- **mask = 白名单**，默认全开。
- 一条日志通过 = ①workflow 在 mask 里 ②level >= 该 workflow 的**生效最低级别**。
- **生效最低级别**：该 workflow 单独提过级就用它的值，否则回落到全局。
  即 **per-workflow 覆盖优先，全局兜底**。这样能把一条链路提到 Trace 排查，
  其余保持 Info，避免日志洪水。

### 3.3 级别选用约定（迁移与新增时照此分级）

| 级别 | 用在哪 |
|---|---|
| Trace | 逐帧 / 每包 / 每次进出的高频细节。Release **编译期剔除** |
| Debug | 阶段切换、Open/Close、一次性配置结果 |
| Info | 生命周期里用户可感知的节点（默认级别，默认可见） |
| **Warn** | **降级发生过**：缺硬解→软解、命中队列/追帧上界、显示序缺口重锚、慢调用、看门狗。必须留到 Release |
| Error | 失败但流程可继续 |

**关键判断**：遍布框架的 Payload 不一定重要，但「系统正在偏离正轨」的信号必须
能在 Release 听到。所以这一版把 MEDIA-027 的几个关键证据（显示序缺口、队列超
上界、追帧上界）和慢调用/看门狗全部提到 **Warn + Release 可见**。

## 4. 改动（write_set）

| 文件 | 改动 |
|---|---|
| `core/include/cq/base/log.h` | 新增 `Workflow` 枚举 + `WorkflowBit/mask` + `WorkflowName` + `WorkflowForStage`；筛选与提级 API；`ConfigureLogFromEnv`；`CQ_LOG_*_WF` 宏族。**补 `#include <cstdio>`**（原头文件用了 `FILE`/`stderr` 却指望调用方替它 include） |
| `core/src/base/log.cpp` | 实现上述；Logger 增 `wf_mask_` 与 per-workflow 级别表（-1 = 回落全局）；**过滤放在格式化之前**；env 解析（大小写不敏感、容忍空格引号、非法值忽略） |
| `core/include/cq/base/perf.h` + `.cpp` | 新增 `SlowCallAlarm`（带 workflow，默认阈值 500ms，**Release 可用**）与 `CQ_SLOW_CALL_WF` |
| `core/include/cq/cq_sdk.h` + `core/src/cq_sdk.cpp` | 新增 C ABI：`cq_log_configure_from_env()` / `cq_log_set_level(int32_t)` |
| `pal/apple/media_decode.{h,mm}` | 迁 18 处 → WF 宏；删自抄 SlowCallAlarm；**4 个 MEDIA-027 关键计数器提到 Release** |
| `pal/apple/media_demux.mm` | 删自抄 SlowCallAlarm；迁 3 处；`@autoreleasepool` 保持 |
| `core/src/preview/preview_pump.cpp` | 删自抄 SlowCallAlarm（阈值原本 1000ms，与其它文件 500ms 不一致）；迁 4 处；**看门狗提到 Release** |
| `core/src/preview/preview_renderer.cpp` | 6 个 `DebugStageGuard` 解开 NDEBUG；迁 2 处；**修正 MEDIA-027 发现的伪绿诊断行**（原打印 ReleaseFrame 之后的 `frame.video.*`，改打已记录的 `last_import_*`） |
| `core/include/cq/preview/preview_renderer.h` | 阶段跟踪（`DebugStage`/`DebugStageSinceNanos`/`DebugStageGuard`）+ 2 个限流计数器提到 Release |
| `core/include/cq/preview/preview_pump.h` / `preview_frame_source.h` | 看门狗与 StageTimings 接口解开 NDEBUG（逐帧采样的 `stage_samples_` 保留 Debug-only） |
| `core/include/cq/media/system_frame_provider.h` | 迁 4 处；Seek 走统一 SlowCallAlarm；**追帧上界提到 Warn + Release**；2 个计数器提到 Release |
| `apps/apple/.../AppEntry.swift` | `init()` 里调 `ChuanqiCut.configureLogFromEnvironment()`；剖面行前缀统一为 `[wf:perf]` |
| `bindings/swift/.../ChuanqiCut.swift` | 新增 `LogWorkflow` / `LogLevel` / `configureLogFromEnvironment()` / `setLogLevel(_:)` |
| `tests/unit/test_log_workflow.cpp` + `tests/CMakeLists.txt` | **新建**；10 组用例（掩码/提级/env/非法值/Release 剔除/帧 trace 继承/慢调用），注册 `core_log_workflow` |

## 5. 怎么用（真机）

Xcode Scheme → Run → Arguments → Environment Variables：

```
CQ_LOG_LEVEL    = debug
CQ_LOG_WORKFLOW = preview,decode,mem
CQ_LOG_WF_LEVEL = decode=trace
```

**不需要改代码、不需要重编译。** 这在真机排查现场很重要 —— 重编 + 重签的成本
往往付不起。

## 6. 验证

| 项 | 结果 |
|---|---|
| `core-dbg`（含新单测） | **43/43 通过** |
| `core-rel` | 待最终一轮门禁 |
| 单独 Debug/Release 双向编译（core + PAL） | 通过（`-Wall -Wextra -Werror -fno-exceptions`） |
| `core_log_workflow` | 见门禁摘要 |

## 7. 剩余风险

- **Release 下多出来的开销未经实测**：翙逐帧路径每帧多两次 `steady_clock::now()`
  （慢调用告警）+ 每段一次 relaxed atomic store（看门狗阶段记账）。相对各段本身
  毫秒级耗时属可忽略量级，但**没有量化数字**。属 P2，需 PERF-001 一并采。
- `fflush(stderr)` 去掉了（旧代码每打一条 flush 一次）。stderr 本身无缓冲，
  落 FILE* 时 `FileLogSink` 已有 flush 逻辑 —— **行为等价，但未在真机实测**。
- 环境变量名（`CQ_LOG_*`）未经 App Review / 隐私审查。SDK 分发场景下需确认
  是否可以读写进程环境变量（目前只在 App 内使用）。
- `log.h` 的 `#include <cstdio>` 是本次补的 —— 说明此前任何先 include perf.h
  再 include log.h 的顺序都可能炸，现已自洽。
