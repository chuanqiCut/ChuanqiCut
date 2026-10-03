# TASK-UIA-010：播放驱动（播放时钟 + 播放/暂停入口）

```yaml
id:          TASK-UIA-010
layer:       SDK + 绑定 + UI
goal:        时间线能真正播放：播放头由内核时钟推进，画面随之前进
input:       [docs/HANDOFF-003 §2「播放驱动」, docs/tasks/TASK-UIA-005.md, .ai/modules/{preview,ui-apple}.md]
output:      [PlayerClock（内核）+ C ABI + Swift 封装 + SharedUI 播放入口 + 测试]
write_set:   core/include/cq/preview/player_clock.h（新）, core/src/preview/player_clock.cpp（新）,
             core/CMakeLists.txt, core/include/cq/cq_sdk.h, core/src/cq_sdk.cpp,
             tests/unit/test_player_clock.cpp（新）, tests/unit/test_c_abi_player.c（新）, tests/CMakeLists.txt,
             bindings/swift/Sources/ChuanqiCut/Player.swift（新）,
             bindings/swift/Tests/ChuanqiCutTests/PlayerTests.swift（新）,
             apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/TimelineZone.swift,
             apps/apple/packages/SharedUI/Tests/SharedUITests/PlaybackTests.swift（新）
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
risk:  MVP 的取帧与渲染仍在**主线程**（Timer 推 playhead → MTKView 按需渲染），
       帧率受单帧解码耗时限制、未实测 —— 真正解耦是子步骤 3；
       MediaImportTests 偶发失败（flaky，P33），根因未定位。
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
| 5 | 把取帧/渲染挪到播放线程（主线程只 blit） | ⏭️ **下一步**（未完成） |
