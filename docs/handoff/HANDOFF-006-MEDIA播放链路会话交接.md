# HANDOFF-006 — 播放/取帧链路会话交接（MEDIA-027 之后）

> 上一个会话：2026-10-06，MEDIA-027「播放 5 秒后永久冻结 + 内存 3.4GB 被 jetsam」。
> 新会话接手先看：本文件 §1 当前形态 → §2 未清的债 → §3 改动落点 → §4 复现手法。

## 1. 当前形态（已验证状态）

真机 iPhone 17 Pro（DEBUG 包、相册 4K60 HDR MOV）：**播放可跑满 122 秒**，
`pump_rendered/s` 151~168，`footprint` 134~184MB，`pump_nonok/s=0`。
本机门禁 PASS=9/FAIL=0（core Debug 42/42、Release 42/42、Swift 绑定 + SharedUI + golden 全过）。

装配形状（取帧链路，从 UI 到解码）：

```
EditorViewModel.tickPlayback (Timer 60Hz, 主线程)
  → PreviewPump.request(pts)                    [core, 泵线程]
    → PreviewRenderer::RenderFrame
      ├─ 快照 → FindClipAt → src_time
      ├─ 区间内复用（MEDIA-024）：命中则跳过 acquire+import，直接重画
      └─ FrameProvider::AcquireFrame (kExact)
           → SystemFrameProvider: TrySequentialAcquire（快路径）或 Seek + AcquireExact
             → AppleDemuxer::ReadPacket → VideoToolboxDecoder::Feed
             → VideoToolboxDecoder::PopFrame（重排 + 队列上界 + 缺口处置）
```

关键不变量（改代码前先读）：

- **`output_queue_` 有硬上界 `kMaxQueuedFrames=12`**：超过即跳过重排判据强制交付。
  这是内存闸门，**不要删**；觉得不够用就调数值（理由写进头文件注释）。
- **缺口判定用「连续次数」`kMaxMismatchStreak=8`，不是单次**：B 帧重排下
  「无在途帧且队列最小 pts ≠ 期望」是**常态**。改成 1 会跳过 B 帧
  （实测 `media_sequential_real` 立刻挂：fast=128000 / slow=116000，提前 3 帧）。
- **`OutputCallback` 必须先入队、后 `MarkDecoded`**：反序会让「pending 空」不蕴含
  「帧已入队」，旧 GOP 帧漏进新序列。
- **`Flush()` 不得用 VTWait**（P72）：每次 Seek 都走它，无上界阻塞 = 慢路径永久卡死。
- **`AcquireExact` 有追帧上界 `kMaxChasePops=600`**：防单次调用独占泵线程数秒。

## 2. 未清的债（按优先级，都可独立立卡）

| # | 债 | 证据 | 建议 |
|---|---|---|---|
| 1 | **桌面 soak 吞吐疑似退化** | 同一 CFR 素材 3600 次请求：p95 158→401ms、wall 178→306s（内存反而持平了） | 单独 A/B 量一次；不要默认「没变」。嫌疑：autorelease pool 开销 / Enqueue-MarkDecoded 顺序让 PopFrame 多等 2ms 轮询 / 机器负载 |
| 2 | **`cq_media_probe_duration` 的「提速」是伪绿** | `CreateMediaDemuxer()` 内部走全量 `Open()`（含全文件 `ScanKeyframes`），之后才调 `OpenLight()` —— 全量 Open 成本一分没省 | 拆出真正的轻探测工厂（不建 reader、不扫关键帧），或让 `CreateMediaDemuxer` 支持 `OpenLight` 模式 |
| 3 | **`[PreviewRenderer] import pts=0/1 dur=0/1` 诊断恒为默认值** | 打印的是 `ReleaseFrame` **之后**的字段（lease 归约把 frame 重置了）；该陷阱第 4 次出现 | 改成打印 `ReleaseFrame` **前**捕获的副本 |
| 4 | **落在展示区间内的请求 = 全 seek + 全 GOP 重解码** | 桌面 soak 逐帧 500~4400ms 的尖刺就是这个（`t < last_end_` 时快路径主动放弃 → 慢路径） | 真机目前被渲染器「区间内复用」挡住（MEDIA-024），但那是渲染层的补丁；provider 层应能直接复用上一帧 |
| 5 | 两个上界参数只有单一素材实测 | 2 分钟内出现 5 次缺口 + 2 次队列超上界，均自恢复 | 补 4K120 / 深 B 帧 / 极端 VFR 素材的数据再定稿 |

## 3. 本次改动落点

| 文件 | 内容 |
|---|---|
| `pal/apple/media_decode.h` | `kMaxQueuedFrames`、`kMaxMismatchStreak`、`order_mismatch_streak_`、Debug 计数器 |
| `pal/apple/media_decode.mm` | 缺口处置、队列上界、`Flush()` 去 VTWait、回调顺序、Debug 日志、`Feed` 加 `@autoreleasepool` |
| `pal/apple/media_demux.mm` | `RebuildReader` / `ReadPacket` 加 `@autoreleasepool` |
| `core/include/cq/media/system_frame_provider.h` | `AcquireExact` 追帧上界 `kMaxChasePops=600` |
| `apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift` | DEBUG 剖面行加 `pump_nonok/s` 与 `footprint`（+ `memoryFootprintMB()`） |
| 文档 | `docs/tasks/TASK-MEDIA-027.md`、`.ai/memory/pitfalls.md` P75、`.ai/memory/baselines.md`、`.ai/modules/media.md`、`.workbuddy/memory/MEMORY.md`（新增「内存与异步等待纪律」段） |

## 4. 复现手法（真机）

```bash
# 1) 构建 + 安装（Source pod，core 随 App 走 Debug，仪器在）
xcodebuild -workspace apps/apple/ios/ChuanqiCut.xcworkspace -scheme ChuanqiCutApp \
  -configuration Debug -destination "platform=iOS,id=<UDID>" \
  -derivedDataPath /tmp/cq-dd-device build
xcrun devicectl device install app --device <UDID> \
  /tmp/cq-dd-device/Build/Products/Debug-iphoneos/ChuanqiCutApp.app
# 2) 跑并抓 stderr（stdout 全缓冲，profile 行走 stderr）
xcrun devicectl device process launch --device <UDID> --terminate-existing --console \
  com.chuanqi.cut
```

- 设备必须**已解锁**，否则 `FBSOpenApplicationErrorDomain error 7`。
- App 会自动导入相册最近素材并开播（`initialMediaURL`），无需 `CQ_DEMO_VIDEO`。
- 判读：`[perf] playback-perf:` 行看 `pump_rendered/s` 与 `footprint`；
  `显示序缺口` / `队列超上界` 是本次新增的可观测点（正常播放偶发、必须自恢复）。
- 桌面 headless soak（不依赖 UI）：见 `/tmp/soak/soak.cpp`（本次排障临时工具，未入库；
  若要长期保留应迁到 `tests/` 并登记 CTest）。

---

## 5. 追加：CORE-010 日志链路筛选（2026-10-06，门禁 PASS=9/FAIL=0）

MEDIA-027 之后传哲要求「把这些排查日志沉淀进项目，像腾讯视频播放器 SDK 那样
每个流程可以单独筛」。已完成，详见 [`docs/tasks/TASK-CORE-010.md`](../tasks/TASK-CORE-010.md)。

### 新会话要接 preview / decode 排障，先知道这几件事

1. **日志有第三维 `Workflow`**，与级别、环节正交。真机切换靠环境变量，
   **不用重编译**（Xcode Scheme → Run → Arguments → Environment Variables）：

   ```
   CQ_LOG_LEVEL=debug   CQ_LOG_WORKFLOW=decode,mem,perf   CQ_LOG_WF_LEVEL=decode=trace
   ```

   App 侧在 `EditorViewModel.init()` 里最早处调 `ChuanqiCut.configureLogFromEnvironment()`。

2. **抓取后按链路筛**：`grep '\[wf:decode\]'` / 只看告警再 `| grep WARN`。
   剖面行前缀已从 `[perf] playback-perf:` 改为 `[wf:perf] playback-perf:`，与 C++ 侧同一套。

3. **这几条 Warn 是 Release 也会出的**（旧版全在 `#ifndef NDEBUG` 里，真机 Release 一条不留）：

   | 日志 | 含义 |
   |---|---|
   | `[wf:decode] 显示序缺口` | 重排判据认定缺口并按缺口交付（MEDIA-027 的真身） |
   | `[wf:mem] 队列超上界` | 内存闸门触发，重排判据没能正常消化队列 |
   | `[wf:framecache] 追帧上界` | 这一帧没追上 |
   | `[wf:perf] 慢调用 xxx took Nms` | 单调用超 500ms |
   | `[wf:perf] RenderFrame 卡在 '<段>' 已 Nms` | 看门狗，指认卡点在哪个分段 |

4. **踩过的坑 P76**：把 `#ifndef NDEBUG` 解开后，它依赖的**成员/计数器**往往还留在
   NDEBUG 块里 → Debug 通过、Release 编译失败（本次踩到 3 次）。
   **改完必须双向编译验证。**

### 尚未做

- Release 下新增开销（逐帧两次 `steady_clock` + 每段一次 atomic store）**没有量化实测**，
  属估算 [E]，待 PERF-001 一并采。
- 桌面 soak 吞吐退化（MEDIA-027 遗留 P1，p95 158→401ms / wall 178→306s）仍未定位。
