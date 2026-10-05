# TASK-UIA-010：播放驱动（播放时钟 + 播放/暂停入口）

```yaml
id:          TASK-UIA-010
layer:       SDK + 绑定 + UI
goal:        时间线能真正播放：播放头由内核时钟推进，画面随之前进
input:       [docs/handoff/HANDOFF-003 §2「播放驱动」, docs/tasks/TASK-UIA-005.md, .ai/modules/{preview,ui-apple}.md]
output:      [PlayerClock（内核）+ C ABI + Swift 封装 + SharedUI 播放入口 + 测试
             + PreviewPump（取帧泵，把取帧/渲染搬离主线程）]
write_set:   core/include/cq/preview/player_clock.h（新）, core/src/preview/player_clock.cpp（新）,
             core/CMakeLists.txt, core/include/cq/cq_sdk.h, core/src/cq_sdk.cpp,
             tests/unit/test_player_clock.cpp（新）, tests/unit/test_c_abi_player.c（新）, tests/CMakeLists.txt,
             bindings/swift/Sources/ChuanqiCut/Player.swift（新）,
             bindings/swift/Tests/ChuanqiCutTests/PlayerTests.swift（新）,
             apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/TimelineZone.swift,
             apps/apple/packages/SharedUI/Tests/SharedUITests/PlaybackTests.swift（新）,
             core/include/cq/preview/preview_frame_source.h（新）,
             core/include/cq/preview/preview_pump.h（新）, core/src/preview/preview_pump.cpp（新）,
             core/include/cq/gfx/gfx_device.h, core/src/gfx/gfx_device.cpp,
             core/include/cq/pal/gfx.h, pal/apple/gfx_metal.mm,
             bindings/swift/Sources/ChuanqiCut/PreviewPump.swift（新）,
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/MetalPreviewView.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PreviewFrameRenderer.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PreviewZone.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/EditorView.swift
read_set:    core/include/cq/base/time.h, core/include/cq/preview/preview_renderer.h
deps:        [UIA-009 ✅（预览渲染）, MODEL-001 ✅（Timeline::Duration）]
acceptance:
  - 时刻是**墙钟的函数**：sleep 120ms → 推进 ≈120ms，不是"每帧 +33ms"的累加
  - 时刻恒为整帧（帧网格量化）
  - 播放边界由内核时间线算（cq_session_timeline_duration），UI 不自己累加片段
  - 暂停冻结、停止归 0、到末尾停止（或循环）
  - 新 ABI 有真正的 C TU 测试；只链 cq_core
verification:
  - ./tools/build/build_core.sh --platform=apple --config=Debug --test
  - ./tools/build/build_core.sh --platform=apple --config=Release --test
  - ctest --test-dir build -R 'player'
  - cd bindings/swift && swift test --disable-sandbox
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - macOS App xcodebuild build + 启动冒烟
risk:  **帧率未达标**：取帧策略导致顺序播放每帧重解一个 GOP（P38）。实测 1s
       播放只出 14 帧（Release；Debug 3 帧）（1280x720，Debug XCFramework）。已开 TASK-MEDIA-021，
       **不在本任务写集内**（它改的是精确取帧的语义边界）。
       MediaImportTests 偶发失败（flaky，P33），根因未定位。
       iOS 编译 / 真机验证仍未做（本机无 iOS 运行时）。
parallel:    false
```

## 关键决策

### D1：时刻 = 墙钟的函数，不是帧数累加

定时器回调间隔有抖动（负载、系统休眠、渲染超时）。每帧 `+1/30 秒` 的写法播
几分钟就偏帧。故 `t = anchor + (now - anchor_wall)`，误差不累积；且时刻量化到
帧网格（29.97fps = 1001/30000），全程整数（红线 #4）。

### D2：时钟不跑线程

`PlayerClock` 只算时间，由调用方按帧调 `Tick()` 推进边界。线程决策（用什么
驱动、渲染在哪发生）归上层 —— 内核不替 UI 决定线程模型。

### D3：停止态时刻恒 0（语义单一）

初始、`Stop()`、播完自然结束都回到 0。不提供"播完停在末帧" —— 两个语义混在
一个状态里就没法断言。

### D4：MVP 用主线程 Timer 驱动（已知不达标）

取帧 + 渲染仍在主线程（`Timer` → `setPlayhead` → MTKView 按需渲染）。好处是
复用已验证的渲染路径、无 Metal 跨线程风险；代价是帧率受解码耗时限制。
**下一步**（子步骤 3）把取帧/渲染挪到播放线程，主线程只做 blit + present。

## 子步骤

| # | 内容 | 状态 |
|---|---|---|
| 1 | 内核 `PlayerClock`（墙钟锚定 + 帧网格量化 + 状态机 + 边界/循环）+ C++ 单测 | ✅ 29/29 |
| 2 | C ABI：`cq_player_*`（9 个）+ `cq_session_timeline_duration` + C TU 测试 | ✅ 33/33 |
| 3 | Swift 绑定 `Player` + `Session.timelineDuration` + 绑定测试 | ✅ 21/21 |
| 4 | SharedUI：ViewModel 播放/暂停/停止 + Timer 驱动 + 播放按钮 + 测试 | ✅ 19/19 |
| 5 | 把取帧/渲染挪到播放线程（主线程只 blit） | ✅ 41+71+38 断言 + 23 绑定用例 + 20 SharedUI 用例 |


## 子步骤 5（2026-10-04 完成）：取帧搬到泵线程

**决策记录**：`docs/decisions/ADR-0016-预览取帧的线程归属与共享命令队列.md`

### 做了什么

| 位置 | 改动 |
|---|---|
| `core/preview/preview_frame_source.h`（新） | `IPreviewFrameSource`：渲染一帧的接缝，供泵注入假实现做确定性并发测试 |
| `core/preview/preview_pump.{h,cpp}`（新） | 取帧泵：自有线程 + 请求合并 + 消费端 Lock/Unlock 协议 + 统计 |
| `core/preview/preview_renderer.{h,cpp}` | 实现 `IPreviewFrameSource`；新增 `Timings`（acquire/import/draw/total 埋点） |
| `core/gfx/gfx_device.{h,cpp}` | 命令队列由「每帧新建」改为**按设备复用**；新增 `SharedQueueHandle()` |
| `core/pal/gfx.h` + `pal/apple/gfx_metal.mm` | 新增 `ICommandQueue::NativeHandle()`（中性句柄） |
| `core/cq_sdk.h` + `preview/cq_sdk_preview.cpp` | `cq_preview_pump_*`（8 个）+ `cq_preview_shared_queue` + `cq_preview_last_timings` |
| `bindings/swift` | `PreviewPump.swift`（新）；`Previewer.sharedQueueHandle` / `lastTimings` |
| SharedUI | `MetalPreviewView` 只 blit（连续/按需两种节奏）；`PreviewFrameRenderer` 用共享队列；`AppEntry` 建泵并驱动 |

### 实测（完整数字见 `.ai/memory/baselines.md`）

| 项 | 数字 |
|---|---:|
| 连续递进请求单帧 total（128x128，Release） | 99.3 ms（取帧 93.3 ms = **94%**） |
| 同上 Debug | 96.3 ms |
| App 侧 1s 播放（1280x720，Debug XCFramework） | 请求 59 / 渲染 **14** / 合并 43（Release XCFramework；Debug 为 3） |
| `Request` 是否阻塞 | 否（单帧成本 50ms 时 10 次 Request 耗时 0 ms） |

**结论：帧率没有提高**（帧率上限仍是 1/单帧取帧耗时），换来的是主线程不再被每帧堵住。
提帧率必须改取帧策略 → `docs/tasks/TASK-MEDIA-021.md`。

### 守卫

- `ctest -R core_preview_pump` 41 断言（假帧源，只链 `cq_core`）
- `ctest -R c_abi_preview` 71 断言；`ctest -R preview_renderer` 38 断言
- `ctest` 全量：Debug 40/40、Release 40/40
- `bindings/swift`：23/23；`SharedUI`：20/20
- macOS App `xcodebuild` + CocoaPods（P34：改绑定层后要重跑 `pod install`）

### 未做 / 剩余风险

1. **帧率**（TASK-MEDIA-021）
2. iOS 编译与真机验证（本机无 iOS 运行时）
3. P33（probe 返回 0 时长）仍 unverified
4. 共享队列的必要性是按 Metal 文档定论 + 功能测试通过，**未做"不共享会花屏"的对照实验**
