# TASK-MEDIA-027 — 播放 5 秒后永久冻结 + 内存 3.4GB 被 jetsam（真因与修复）

- 状态：**已修复并真机复验通过**（本机 ctest 42/42；真机播放跑满 122s，footprint 稳定 134~184MB）
- 日期：2026-10-06
- 来源：用户报告「导入两分钟视频，播放五秒就歇菜；是不是有内存问题」
- 编号：MEDIA-027（取号前已核对 `docs/tasks/` 水位 = MEDIA-026，远端同 HEAD）
- 坑号：P75（P72 已被 MEDIA-026 与 CAM-017 二修各占一次，本卡不复用）
- 复盘：[REVIEW-2026-10-06-MEDIA027-播放5秒冻结与jetsam复盘](../reviews/REVIEW-2026-10-06-MEDIA027-播放5秒冻结与jetsam复盘.md)（方法与人因，本卡只记做法与代码）

## 1. 症状与实测证据

真机 iPhone 17 Pro（DEBUG 包，`devicectl device process launch --console`，
素材 = 相册导入的 4K60 HDR MOV，解码输出 1080x1920 BGRA）：

| 观测 | 值 |
|---|---|
| 前 4 秒泵吞吐 | `pump_rendered/s=131 → 116`（正常） |
| 第 5 秒起 | `pump_rendered/s=0`，**再也不恢复** |
| Watchdog | `RenderFrame 卡在 'provider+acquire'`，1174ms → 8226ms 单调增长 |
| 进程内存足迹 | `footprint=3375.0MB`（t=11.98s 时） |
| 结局 | `App terminated due to signal 9`（jetsam，非崩溃） |

两次独立运行**逐字节级复现**（ReadPacket/PopFrame 计数、t=11.98s、signal 9 全部一致），
不是 flaky。

## 2. 根因（三层，一层压一层）

### 根因 1（直接死因）：解码输出队列「只进不出」→ 内存无界 → jetsam

`VideoToolboxDecoder::PopFrame` 的显示序连续性判据：

```
期望 = 上一弹出帧 pts + 上一帧 duration
若 队列最小 pts == 期望 → 弹出
若 不等 且 有在途帧 → 等（2ms 轮询 + 1s 丢帧超时）
若 不等 且 无在途帧 → 【原实现】原样返回 kIoNotFound，**不弹出**
```

最后一条分支是死路：期望值与队列最小帧**都不变**，下一次 PopFrame 做出完全相同的
判定 → 无限重复。而调用方 `SystemFrameProvider::AcquireExact` 收到 kIoNotFound 就
继续 Feed → VT 继续解码入队 → 队列单调增长。1080x1920 BGRA ≈ 8.3MB/帧，累积约
400~500 帧即 3.4GB → 与实测 footprint 完全吻合。

触发该分支的两类素材：
- **VFR**（iPhone 实拍常见）：`期望` 由「上一帧 duration」外推，帧长一变就永远对不上；
- **VT 静默丢帧**：被丢的那帧永不入队，期望值永远等不到。

### 根因 2（放大）：`Flush()` 仍在用无界阻塞的 VTWait

`Flush()` 里 `VTDecompressionSessionWaitForAsynchronousFrames()` **未被 MEDIA-026 一并
替换**（原注释「暂保留」）。Flush 在**每次 Seek** 上都调用，慢路径每帧一次 Seek ——
等于给慢路径留了一个永久阻塞入口。已改为「等在途帧落地 + 1s 超时」。

### 根因 3（顺序竞态）：回调里先登记完成、后入队

`OutputCallback` 原顺序 `MarkDecoded(dts)` → `Enqueue(...)`。等待方以
「pending 集合空」为全部完成的判据，而 pending 被清空时该帧**还没进队列** ——
等待方据此清队/放行，随后该帧才入队，上一区间的旧帧漏进新序列
（MEDIA-021 实测的「Seek 后首弹弹出旧 GOP 的 128000」即此形态）。
改为**先入队、后登记**，「pending 空」才真正蕴含「已产出的帧都已在队列里」。

### 附带确认的两个伪绿

1. **MEDIA-026 的「导入提速」在本代码路径上不成立**：
   `cq_media_probe_duration` 先调 `CreateMediaDemuxer()` → 内部 `AppleDemuxer::Open()`
   （含全文件 `ScanKeyframes`），之后才调 `OpenLight()`。全量 Open 的成本一分没省。
   （真机实测 `[import] probe 401ms`，未能证伪也未证实提速效果，代码路径上不成立。）
2. **「复用命中」诊断打印的是 ReleaseFrame 之后的字段**（`import pts=0/1 dur=0/1`），
   恒为默认值 —— 该陷阱第 4 次出现，诊断行不可用。

## 3. 修复（write_set）

| 文件 | 改动 |
|---|---|
| `pal/apple/media_decode.h` | 新增 `kMaxQueuedFrames=12`、`kMaxMismatchStreak=8`、`order_mismatch_streak_` 与两个 Debug 计数器 |
| `pal/apple/media_decode.mm` | ①无在途帧且不匹配时改为「连续 8 次仍等不到即按缺口交付并重锚」；②队列超 12 帧跳过重排判据强制交付；③`Flush()` 的 VTWait 换为轮询 + 1s 超时；④`OutputCallback` 改为先入队后登记；⑤Debug 队列深度/缺口/超上界日志 |
| `pal/apple/media_demux.mm` | `RebuildReader` / `ReadPacket` 加 `@autoreleasepool`（泵线程是纯 C++ `std::thread`，**没有** autorelease pool） |
| `core/include/cq/media/system_frame_provider.h` | `AcquireExact` 加追帧上界 `kMaxChasePops=600`（单次调用解码帧数上限，防单帧独占泵线程 8 秒） |
| `apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift` | DEBUG 剖面行增加 `pump_nonok/s` 与 `footprint=` （真机判断 jetsam 的唯一可观测点） |

**为什么「缺口放行」要等 8 次而不是立刻放行**：B 帧重排下「无在途帧且不匹配」是
**常态**（参考 P 先到，其 B 帧在其后才喂入）。首版修复立刻放行 → 跳过 B 帧 →
`media_sequential_real` 挂掉（快路径比慢路径提前 3 帧，fast=128000 / slow=116000）。
8 次 = 常见 B 帧深度（≤4）的一倍余量。

## 4. 验证

| 项 | 命令 | 结果 |
|---|---|---|
| **本机总门禁** | `tools/ci/run_gate.sh` | **PASS=9 / FAIL=0 / SKIP=0**（core-dbg 42/42、core-rel 42/42、Swift 绑定 + SharedUI + golden 全过） |
| 全量单测（Release） | `ctest --test-dir build` | **42/42 通过** |
| 关键回归 | `ctest -R media_sequential_real` | 通过（17.0s；修复前基线 17.3s，无性能退化） |
| 桌面 soak（720p30 CFR，60s×60Hz） | `/tmp/soak/soak` | 内存由「+13.8MB 单调增长」变为「+0.5MB 基本持平」（footprint 4.6→4.9MB） |
| **真机复验**（同一素材、同一 DEBUG 包） | `devicectl device process launch --console` | **通过**，见下 |

### 真机复验（iPhone 17 Pro，同一相册 4K60 HDR MOV，DEBUG 包）

修复前 vs 修复后，同一台设备、同一素材：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 播放可持续时间 | ~5s 后 `rendered/s` 归零，再不恢复；t=11.98s 被 signal 9 | **跑满 t=121.99s**（素材播完） |
| `pump_rendered/s` | 131 → 116 → **0**（永久） | **151~168 全程稳定** |
| `footprint` | **3375.0MB**（单调涨到死） | **134~184MB 平稳波动** |
| `pump_nonok/s` | — | **0**（无一次取帧失败） |
| 结局 | `App terminated due to signal 9` | 正常播完，无告警 |

根因被直接观测到（新加的 Debug 日志）：

```
[VideoToolboxDecoder] 显示序缺口 #1：连续 8 次未等到期望=420000/120000，
                     按缺口交付 pts=420200/120000（q=8）
```

期望 420000 与实际 420200 差 200/120000 ≈ 1.67ms —— **素材是 VFR**（帧长不是恒定的
4000），「上一帧 duration 外推」的期望值永远对不上，正是预判的触发源。全程共 5 次
缺口（自动放行）+ 2 次队列超上界（闸门），每一次都自恢复，播放未中断。

## 5. 剩余风险

- **两个上界参数只有本素材的实测**：`显示序缺口` 5 次 / `队列超上界` 2 次均在
  2 分钟素材内出现并自恢复，说明取值可用；但没有 4K120 / 深 B 帧 / 极端 VFR 素材的
  数据。若某素材上「队列超上界」日志刷屏，应先调 `kMaxQueuedFrames` 而不是关闸门。
- 桌面 soak 的 p95 从 158ms 变成 401ms、wall 从 178s 变成 306s（同一 CFR 素材）。
  内存已持平，但**吞吐有退化嫌疑**，未定位是 autorelease pool 开销、机器负载差异，
  还是修复引入的额外解码。属 P1，需要单独立卡量一次（不要在本次结论里当"没变"）。
- `kMaxQueuedFrames=12` / `kMaxMismatchStreak=8` 是**上界参数**，取值依据已写进头文件
  注释，但缺少多素材（VFR / 深 B 帧 / 4K120）实测；若发现正常播放频繁触发
  「队列超上界」日志，应先调这两个数而不是关掉闸门。
- 桌面 soak 显示仍有约 3.8KB/请求 的缓慢增长（60s 内容 +13.8MB），已加 autorelease
  pool 但**未复测**（soak 在修前版本测的）。属 P2，需单独量一次。
- `cq_media_probe_duration` 的伪提速未在本卡改（改动面在探测/工厂接口，另立卡）。
