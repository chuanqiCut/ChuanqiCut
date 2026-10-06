# REVIEW — 播放 5 秒后永久冻结 + 内存 3.4GB 被 jetsam（MEDIA-027 复盘）

- 日期：2026-10-06
- 任务：[TASK-MEDIA-027](../tasks/TASK-MEDIA-027.md)
- 坑号：[P75](../.ai/memory/pitfalls.md)（P72 已被 MEDIA-026 与 CAM-017 各占一次，不复用）
- 实测数据：`.ai/memory/baselines.md` §「播放冻结 / 内存（MEDIA-027）」
- 性质：**复盘**（事后总结方法与人因），不是任务卡（做法与代码）、不是 ADR（架构约束）

---

## 0. TL;DR

真机播放「5 秒后永久冻结」的**真身不是卡住，是内存爆了被系统杀**。
解码输出队列里有一条分支**判定失败却不弹出任何帧**，期望值与队列最小帧都不变 →
下一次判定完全相同 → 无限循环；调用方收不到帧就继续喂数据 → 队列单调增长 →
1080×1920 BGRA 8.3MB/帧，涨到 3375MB → `signal 9`（jetsam）。

修完：同一台设备、同一素材，播放跑满 **121.99s**，footprint **134~184MB** 平稳，
`nonok/s=0`。

这条复盘最值得留下的不是「那个分支怎么写」，而是两件事：

1. **同名症状，两次不同根因**（MEDIA-026 修过一次「播放 ~5s 冻结」，真机复现说明没修完）——
   「我修过这个 bug」不等于「这个 bug 修好了」；
2. **判据正确性不可能零缺陷，所以任何「等判据成立」的循环都必须配一条不依赖该判据的内存上界闸门。**

---

## 1. 症状与时间线

### 1.1 用户报告

> 导入的两分钟视频，播放五秒就歇菜了；是不是有内存问题。

**用户自己就把方向猜对了。** 值得记一笔：报告里带了一句「是不是有内存问题」，
我在动手前把它当 hypothesis 而非结论处理，最后被证据证实——但**不要因为用户猜对
了就跳过取证**，也不要因为用户没猜就往别处找。

### 1.2 前情：MEDIA-026 已经「修过一次」

MEDIA-026 的标题就是「播放 ~5s 冻结」，根因是 `PopFrame` 里
`VTDecompressionSessionWaitForAsynchronousFrames()` **永久阻塞**（坑 P72）。
当时本机验证通过。真机一跑，还是 5 秒歇菜。

**这是本次最大的认知陷阱。** 两个同名症状，根因完全不同：

| | MEDIA-026（P72） | MEDIA-027（P75） |
|---|---|---|
| 表现 | 播放 ~5s 冻结 | 播放 ~5s 冻结 |
| 机制 | 线程**阻塞**（VTWait 不返回） | 线程**活着**但判定死循环，内存爆 |
| 卡在哪 | `PopFrame` 里等 VT | `PopFrame` 里等「显示序连续性」判据 |
| 结局 | 画面停住，进程还活着 | 进程被 jetsam（signal 9） |
| 本机能否复现 | 能 | 不能（素材依赖 VFR） |

**教训**：修完一个 bug 后，如果症状「看起来还是老样子」，第一反应必须是
「这是不是另一个 bug」，而不是「上次没修干净」。两者的观测手段完全不同——
这次是靠 `footprint` 才分开的。

### 1.3 本机复现失败（重要）

本机（Intel Mac + AMD GPU）**复现不出来**。原因是触发依赖 **VFR 素材**
（iPhone 实拍的 4K60 HDR MOV，帧长不恒定），本机测试素材全是 CFR。
这一点直接决定了后面的取证策略：**必须上真机，且必须让日志自带内存数字。**

---

## 2. 证据链：怎么确定「是内存」而不是「是慢」

### 2.1 决定性观测：给 DEBUG 剖面行加内存字段

之前每 2 秒打一行的 `[perf] playback-perf:` 只有帧率/耗时，**没有内存**。
在 `AppEntry.swift` 里加了两个字段后，一切就清楚了：

- `footprint=` — `task_vm_info.phys_footprint`（比 RSS 更贴近 jetsam 判定）
- `pump_nonok/s` — 取帧失败速率（区分「没画」和「画不出来」）

真机（`devicectl device process launch --console`，**stderr**）：

```
t=0~4s    pump_rendered/s = 131 → 116       正常
t=5s      pump_rendered/s = 0               再也不恢复
          Watchdog: RenderFrame 卡在 'provider+acquire' 1174ms → 8226ms（单调增长）
t=11.98s  footprint = 3375.0MB
          App terminated due to signal 9
```

两次独立运行**逐字节级复现**（ReadPacket / PopFrame 计数、t=11.98s、signal 9
全部一致）——不是 flaky，可以放心当硬证据用。

### 2.2 为什么「Watchdog 说卡在 provider+acquire」差点把我带偏

Watchdog 报「provider+acquire 耗时 8 秒」很容易被读成「解码慢」。
**但慢和死是两回事**：单调增长且不回归零 = 不是变慢，是**永远等不到**。
判断依据只有一个——它有没有回来过。

> 配套动作：`AcquireExact` 加了追帧上界 `kMaxChasePops=600`，防单帧独占泵线程。
> 这是**防御**，不是修复——加上界只是让「死循环」变成「一帧失败」，
> 真正的病在下游 `PopFrame`。

### 2.3 根因被直接观测到（不是推理出来的）

修复后新加的 Debug 日志把真因打印出来了：

```
[VideoToolboxDecoder] 显示序缺口 #1：连续 8 次未等到期望=420000/120000，
                     按缺口交付 pts=420200/120000（q=8）
```

期望 420000 vs 实际 420200，差 200/120000 ≈ **1.67ms**。
素材帧长不是恒定的 4000 → **VFR 实锤**，与预判的触发源一致。

---

## 3. 根因（三层，一层压一层）

### 根因 1（直接死因）：队列「只进不出」

`VideoToolboxDecoder::PopFrame` 的显示序连续性判据：

```
期望 = 上一弹出帧 pts + 上一帧 duration
若 队列最小 pts == 期望   → 弹出
若 不等 且 有在途帧       → 等（2ms 轮询 + 1s 丢帧超时）
若 不等 且 无在途帧       → 【原实现】返回 kIoNotFound，不弹出   ← 死路
```

最后一条分支是死路：**期望值和队列最小帧都不变**，下一次判定完全相同 →
无限重复。调用方 `AcquireExact` 收到 `kIoNotFound` 就继续 Feed → VT 继续解码
入队 → 队列单调增长 → 8.3MB/帧 × 约 400~500 帧 ≈ 3.4GB，与实测 footprint 吻合。

触发该分支的两类素材：**VFR**（duration 外推永远对不上）、**VT 静默丢帧**
（被丢的帧永不入队）。

### 根因 2（放大）：`Flush()` 里还留着无界阻塞

MEDIA-026 只换了 `PopFrame` 里的 VTWait，`Flush()` 里那处被注释标成「暂保留」。
**每次 Seek 都会走 Flush**，慢路径每帧一次 Seek —— 等于给慢路径留了一个永久
阻塞入口。已改为「等在途帧落地 + 1s 超时」。

> 这条是「改一半」的典型代价。修一类问题（阻塞等待）时，**必须 grep 全库
> 同类 API 的所有调用点**，不能只改当前报错的那一行。

### 根因 3（顺序竞态）：回调里先登记完成、后交付数据

`OutputCallback` 原顺序 `MarkDecoded(dts)` → `Enqueue(...)`。等待方以
「pending 集合空」为完成判据，但 pending 被清空时**该帧还没进队列**——
等待方据此放行，随后帧才入队，上一区间的旧帧漏进新序列。

**通用规则**：回调里「登记完成」必须在「交付数据」**之后**。反过来，
「完成」就不蕴含「数据可见」，等待方的判据是假的。
（MEDIA-021 实测过的「Seek 后首弹弹出旧 GOP」是同一个形态。）

### 附带：泵线程没有 autorelease pool

泵线程是纯 C++ `std::thread`，**没有** autorelease pool。PAL 侧被它逐帧调用的
`RebuildReader` / `ReadPacket` / `Feed` 必须自带 `@autoreleasepool`。
桌面 soak 实测：加池前 +13.8MB/60s，加池后 +0.5MB/60s。

---

## 4. 定位手段排行（下次照这个顺序来）

按「单位投入能换到的信息量」排序：

| 排名 | 手段 | 它解决了什么 |
|---|---|---|
| 1 | **周期剖面行里恒带 `footprint`** | 一句话区分「卡死」与「被杀」。没有它，这次会一直往「解码慢」方向查 |
| 2 | **成对 enter/exit 日志 + 耗时** | 定位「卡在哪个函数」；配合 SlowCallAlarm 覆盖「根本不返回」的情况（Watchdog 对永不返回是瞎的） |
| 3 | **给可疑分支加「分支名 + 内核原始状态码 + 计时」临时诊断** | 把「推理」变成「观测」。根因 1 是**打印出来的**，不是想出来的 |
| 4 | **真机 stderr 采集**（`devicectl ... --console`） | 本机复现不出来时唯一出路。注意：stdout 在全缓冲下丢日志，**必须走 stderr** |
| 5 | **逐字节级复现两次** | 排除 flaky，让结论能当验收阈值 |

一个反面经验：**修性能/卡死之前先分段埋点**。没加 `footprint` 之前我一度在
「解码慢 → 挪线程」的方向上打转（挪线程 ≠ 提帧率，这是踩过的老坑）。

---

## 5. 失败的首版修复（值得单独记）

第一版把「无在途帧且不匹配」改成**立刻放行**。结果 `media_sequential_real` 挂了：

```
fast=128000 / slow=116000   ← 快路径比慢路径提前 3 帧
```

原因：**B 帧重排下「无在途帧且不匹配」是常态**——参考帧 P 先到，它引用的 B 帧
在其后才喂入。立刻放行 = 跳过 B 帧。

改成 **连续 8 次**才放行（`kMaxMismatchStreak = 8`，常见 B 帧深度 ≤4 的一倍余量），
回归通过（修复前基线 17.33s，修复后 17.01~17.22s，无退化）。

> **可复用规则**：任何「判据失败就绕过去」的放行逻辑，阈值都要按**连续次数**给，
> 不能取 1。取 1 相当于宣称「这个判据一次都不能错」——而它恰恰经常对。

---

## 6. 顺手挖出的两个伪绿

1. **MEDIA-026 的「导入提速」在本代码路径上不成立**。
   `cq_media_probe_duration` 先调 `CreateMediaDemuxer()` → 内部
   `AppleDemuxer::Open()`（含全文件 `ScanKeyframes`），之后才调 `OpenLight()`。
   全量 Open 的成本一分没省。真机实测 `[import] probe 401ms`，未证伪也未证实提速。
   → 未在本卡改（改动面在探测/工厂接口），另立卡。

2. **「复用命中」诊断打印的是 `ReleaseFrame` 之后的字段**
   （`[PreviewRenderer] import pts=0/1 dur=0/1`），恒为默认值，诊断行不可用。
   → 这是**同一个陷阱第 4 次出现**。诊断打印必须打在被消费的时刻，
   不是打在对象已被释放之后。

---

## 7. 修复清单（write_set）

| 文件 | 改动 |
|---|---|
| `pal/apple/media_decode.h` | `kMaxQueuedFrames=12`、`kMaxMismatchStreak=8`、`order_mismatch_streak_` + Debug 计数器 |
| `pal/apple/media_decode.mm` | ①缺口连续 8 次即交付并重锚；②队列 >12 帧跳过重排判据强制交付；③`Flush()` 的 VTWait → 轮询 + 1s 超时；④`OutputCallback` 改为先入队后登记；⑤Debug 队列深度/缺口/超上界日志 |
| `pal/apple/media_demux.mm` | `RebuildReader` / `ReadPacket` 加 `@autoreleasepool` |
| `core/include/cq/media/system_frame_provider.h` | `AcquireExact` 加追帧上界 `kMaxChasePops=600` |
| `apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift` | DEBUG 剖面行增 `pump_nonok/s` 与 `footprint=` |

**关键设计**：`kMaxQueuedFrames` 是一条**不依赖重排判据**的内存上界闸门。
判据正确性不可能零缺陷，所以闸门不能省——哪怕判据写对了也要有。

---

## 8. 验证

| 项 | 命令 | 结果 |
|---|---|---|
| 本机总门禁 | `tools/ci/run_gate.sh` | **PASS=9 / FAIL=0 / SKIP=0**（core-dbg 42/42、core-rel 42/42、Swift 绑定 + SharedUI + golden 全过） |
| 关键回归 | `ctest -R media_sequential_real` | 通过，17.0s（基线 17.3s，无退化） |
| 桌面 soak（720p30 CFR，60s×60Hz） | `/tmp/soak/soak` | 内存由「+13.8MB 单调涨」变为「+0.5MB 持平」（footprint 4.6→4.9MB） |
| **真机复验**（iPhone 17 Pro，同一 4K60 HDR MOV，DEBUG 包） | `devicectl device process launch --console` | **通过** |

**真机修复前后（同设备、同素材）：**

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 可持续时间 | ~5s 后 `rendered/s` 归零，t=11.98s 被 signal 9 | **跑满 t=121.99s** |
| `pump_rendered/s` | 131 → 116 → **0**（永久） | **151~168 全程稳定** |
| `footprint` | **3375.0MB** 单调涨到死 | **134~184MB** 平稳波动 |
| `pump_nonok/s` | — | **0** |
| 结局 | `App terminated due to signal 9` | 正常播完 |

全程 5 次「显示序缺口」+ 2 次「队列超上界」，**每一次都自恢复**，播放未中断。

---

## 9. 剩余风险

- **两个上界参数只有单一素材的实测**。5 次缺口 / 2 次超上界都在 2 分钟 VFR
  素材内出现并自恢复，说明取值可用；但缺 4K120 / 深 B 帧 / 极端 VFR 的数据。
  若某素材上「队列超上界」刷屏，**应先调 `kMaxQueuedFrames` 而不是关闸门**。
- **桌面 soak 吞吐疑似退化**：p95 158ms → 401ms、wall 178s → 306s（同一 CFR 素材）。
  内存已持平，但吞吐没解释清楚——可能是 autorelease pool 开销、机器负载差异，
  或修复引入的额外解码。**未定位，属 P1，需单独立卡量一次**，不要在本次结论里
  当成「没变」。
- **桌面 soak 仍有约 3.8KB/请求 的缓慢增长**（+13.8MB/60s 是**修前**测的），
  加池后未复测。P2。
- `cq_media_probe_duration` 的伪提速未改，另立卡。

---

## 10. 沉淀为长期规则

已写进 `.workbuddy/memory/MEMORY.md` §「内存与异步等待纪律（MEDIA-027 血泪）」，
要点复述在此：

1. **任何「等某个判据成立」的重排/同步循环，都必须配一条不依赖该判据的内存上界闸门。**
2. **判据失败分支必须区分「还没来」与「永远不会来」**，且后者阈值按**连续次数**给，不能取 1。
3. **回调内「登记完成」必须在「交付数据」之后。**
4. **等异步回调一律禁止无上界阻塞**（VTWait 系），`PopFrame` 和 `Flush` 都要管。
5. **纯 C++ 线程里被逐帧调用的 PAL 函数必须自带 `@autoreleasepool`。**
6. **真机「卡死 + signal 9」必须能区分 jetsam 与解码追赶失败** → DEBUG 剖面行恒带 `footprint` 与 `nonok/s`。
7. **修一类问题时 grep 全库同类 API 的所有调用点**，不能只改报错那一行（根因 2 的代价）。

---

## 11. 关联文档

- 任务卡（做法与代码）：[TASK-MEDIA-027](../tasks/TASK-MEDIA-027.md)
- 坑（编号与验证状态）：`.ai/memory/pitfalls.md` → **P75**
- 实测数据：`.ai/memory/baselines.md` → §「播放冻结 / 内存（MEDIA-027）」
- 模块装配形状：`.ai/modules/media.md` → § MEDIA-027
- 会话交接：[HANDOFF-006](../handoff/HANDOFF-006-MEDIA播放链路会话交接.md)
- 前情（同名不同因）：MEDIA-026 / 坑 **P72**
