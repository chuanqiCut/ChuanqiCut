# HANDOFF-004：编码阶段会话交接

> 建立：2026-10-04
> 覆盖：2026-10-03 ~ 2026-10-04
> 前置阅读：`.ai/source/AGENTS.root.md`（真源）→ 本文件
> 上一版：`docs/HANDOFF-003-*.md`（仍可作历史参考，但**状态以本文件为准**）

新会话**先读本文件 + 真源**，再动手。

---

## 1. 当前项目状态（对着 commit 与门禁核过，不是照抄上一版）

最近提交：

```
9d820ba UIA-010 子步骤 1~4：播放时钟 + 播放/暂停入口
1dfe708 UIA-005：片段拖拽/裁剪交互 + undo/redo C ABI
15e6e0b UIA-009 子步骤 3：素材导入 UI（任务整体收口）
744ef1a UIA-009 子步骤 2：预览收口（Session 成为模型唯一真源）
```

| 环节 | 任务 | 状态 |
|---|---|---|
| 内核 | CORE-001~009 / MODEL-001 / MODEL-002 | ✅ |
| 渲染 | GFX-002 `IGfxDevice` 直连 PAL | ✅ |
| 预览 | BIND-003（素材表 / 取帧 / 渲染器 / C ABI / Swift 绑定） | ✅ |
| UI | UIA-003 预览嵌入、UIA-004 时间线自绘、UIA-005 拖拽裁剪 | ✅ |
| UI | UIA-009 素材导入（三个子步骤全完成） | ✅ |
| 播放 | UIA-010 子步骤 1~5 全部完成（时钟 + 播放入口 + 取帧泵） | ✅（2026-10-04） |
| 取帧 | **MEDIA-021 顺序取帧快路径 ✅**（P38 修复 + P39/P40/P41 正确性修复；acquire 93.3ms → 4.45ms Release，14.8x；ADR-0014） | ✅（2026-10-04） |
| 相机链路 | BACKLOG 中**不存在**；由传哲本人在另一台设备并行开发 | ➖ 不在本机写集 |

**并行开发的写集边界（已与传哲确认）**：
相机侧只动 `pal/*`、`docs/tasks/TASK-CAP-*`、`docs/specs/`；
避开 `core/preview/*`、`core/include/cq/cq_sdk.h`、SharedUI 的时间线/预览、`bindings/swift`。

---

## 2. UIA-010 子步骤 5（本轮工作）：取帧搬到泵线程

**决策：`docs/decisions/ADR-0013-预览取帧的线程归属与共享命令队列.md`**

装配形状：

```
主线程                            泵线程（PreviewPump，内核拥有）
────────────────────────────────  ──────────────────────────────────────
Timer 60Hz → player.tick()
  → pump.request(pts) ──────────►  取 pts → PreviewRenderer::RenderFrame
  → playhead 发布（30Hz）            （seek + 解码 + 导入 + 离屏绘制）
MTKView.draw(in:)
  → pump.Lock() → LatestLocked().texture
  → PreviewFrameRenderer.blit       ← 必须用内核共享队列（commit 顺序）
  → present → pump.Unlock()
```

**硬约束（已写进头文件，不是口头约定）**：

1. 挂泵后 `cq_preview_render_frame` / `cq_preview_resize` **只由泵线程调用**。
2. 改尺寸只能走 `cq_preview_pump_request_resize`（RT 只能由持有它的线程销毁）。
3. 消费端持锁期间**不要**调 `Request`（同一把锁 → 死锁，P36 实踩），也不要
   `waitUntilCompleted`（会把泵一起堵住）。
4. UI 侧 blit 必须用 `cq_preview_shared_queue()` 那条队列（P37）。

新增文件：

| 文件 | 作用 |
|---|---|
| `core/include/cq/preview/preview_frame_source.h` | `IPreviewFrameSource`：渲染一帧的接缝（可注入假实现） |
| `core/include/cq/preview/preview_pump.h` + `src/preview/preview_pump.cpp` | 取帧泵 |
| `bindings/swift/Sources/ChuanqiCut/PreviewPump.swift` | Swift 投影 |
| `tests/unit/test_preview_pump.cpp` | 41 断言（假帧源，只链 `cq_core`） |

改动的既有文件：`preview_renderer.{h,cpp}`（+Timings 埋点、实现帧源接口）、
`gfx_device.{h,cpp}`（队列复用 + `SharedQueueHandle`）、`pal/gfx.h` +
`pal/apple/gfx_metal.mm`（`ICommandQueue::NativeHandle`）、`cq_sdk.h` +
`cq_sdk_preview.cpp`（8 个 pump ABI + shared_queue + last_timings）、
SharedUI 的 `MetalPreviewView` / `PreviewFrameRenderer` / `PreviewZone` /
`EditorView` / `AppEntry`。

---

## 3. 实测数字（本轮最大产出）

完整表在 `.ai/memory/baselines.md`。要点：

| 项 | 数字 |
|---|---:|
| 连续递进请求单帧 total（128x128，Release） | 99.3 ms（取帧 93.3 ms = **94%**） |
| 同上 Debug | 96.3 ms |
| App 侧 1s 播放（1280x720） | 请求 59 / 渲染 **14** / 合并 43（Release XCFramework；Debug 为 3） |
| `Request` 是否阻塞 | 否（单帧 50ms 时 10 次 Request 耗时 0 ms） |

**帧率没有因本子步骤提高** —— 瓶颈是取帧策略：顺序播放每帧都 `kExact` seek，
等于每帧重解一个 GOP（P38）。已开 `docs/tasks/TASK-MEDIA-021.md`。

⚠️ 为什么**故意**不在这次改：它动的是「精确取帧」这个编辑器核心不变量的语义边界，
必须有逐帧 pts 断言的专门用例（静态彩条素材看不出差一帧）。混在"挪线程"里会让它
逃过针对性审查。

---

## 3.5 MEDIA-021：顺序取帧快路径（本轮第二轮工作，2026-10-04）

**决策：`docs/decisions/ADR-0014-顺序取帧快路径与解码器显示序重排.md`**

- `SystemFrameProvider` 新增顺序快路径（`TrySequentialAcquire` + 自适应阈值
  `proven_span_`，无固定常量）+ `consumed_` 语义修复（同目标重复请求重新 seek）。
- 解码接缝三个 `Acquire*` 循环改「**先喂后弹**」（P39：B 帧未喂入时任何重排
  判据无信息可用）。
- `VideoToolboxDecoder` 按「显示序连续性」重排弹出（P40：VT 回调按完成序）；
  首帧时长兜底改 dts 差（P40 同族）；Flush 先等在途帧落地再清队（P41）。
- 新增测试：`tests/unit/test_media_sequential_acquire.cpp`（mock，46 断言，
  含混合序列 vs 参照实现逐帧一致）、`tests/unit/test_media_sequential_real_apple.cpp`
  （真实硬解 + 快/慢对照 + 性能断言）。
- 门禁：Debug 42/42、Release 42/42、swift 23/23、SharedUI 20/20。
  **核心数字**：顺序取帧 acquire 93.3ms → 4.45ms（Release），14.8x；
  逐帧 pts 严格递增/区间归属/快慢一致 120/120 全过。完整表见 baselines「MEDIA-021」段。

---

## 4. 门禁

```bash
./tools/build/build_core.sh --platform=apple --config=Debug --test     # 40/40
./tools/build/build_core.sh --platform=apple --config=Release --test   # 40/40
ctest --test-dir build -R core_preview_pump    # 41 断言
ctest --test-dir build -R c_abi_preview        # 71 断言
ctest --test-dir build -R preview_renderer     # 38 断言
cd bindings/swift && swift test --disable-sandbox                      # 23/23
cd apps/apple/packages/SharedUI && swift test --disable-sandbox        # 20/20
# macOS App：先 bundle exec pod install（P34），再 xcodebuild → BUILD SUCCEEDED
./tools/build/build_core_apple.sh --config=Release && cd bindings/swift && ./prepare.sh
```

⚠️ 每次改了 `core/` 之后，Swift 侧要**重新构建 XCFramework + `prepare.sh`**，
否则 `swift test` 会报 `symbol(s) not found`（SPM 用的是复制件，不是符号链接）。

---

## 5. 下一步（按优先级）

1. ~~TASK-MEDIA-021~~ **✅ 已完成（2026-10-04）**：顺序取帧快路径落地
   （ADR-0014）。acquire 93.3ms → 4.45ms（Release，GOP60/B帧3 素材），
   与旧语义逐帧 pts 一致；顺带修复 P39/P40/P41 三个 B 帧正确性 bug
   （修复前 kExact 在 B 帧素材上系统性差帧）。数字见 `.ai/memory/baselines.md`
   「MEDIA-021」段；**预览端到端帧率 App 侧数字待真机**。
2. **iOS 编译与真机验证**（传哲本人做，iPhone 17 Pro）：本机无 iOS 运行时，
   自 2026-10-03 起 iOS 侧改动**只有 macOS 路径被编译过**。本轮取帧提速后，
   真机重点验证：顺序播放实际帧率、回退 seek（时间线反向拖动）正确性。
3. **P33 定位 → 已修复（2026-10-04，两轮会话收口）**：根因**两层**——
   ① 内核：`loadValuesAsynchronouslyForKeys` 的 completion 只 signal 不查终态
   （Failed 也触发）→ invalid duration 被 ToRational 转成 {0,1} 骗过检查 →
   probe 带 0 成功返回；顺带发现并修复**更危险的挂死隐患**（重建 asset 的
   completion 可能永不触发，`DISPATCH_TIME_FOREVER` = Open 挂死）。
   ② Swift：`importMedia` 等 addTrack 的判据是「版本号推进」，但 registerAsset
   也推版本（RegisterAsset 会 Publish）→ 等待提前通过 → 查不到视频轨 →
   假失败 7000（上一轮「内核修复后 ×3 全绿」**不可复现**，复跑 6/3/0 失败实证）。
   修复 = 轮询目标效果（`queryTracks` 出现视频轨）。两层修复后 SharedUI 全量
   ×3 **20/20**（套件时长 14.8s→4.2s，失败用例不再烧 5s 超时）。详见 pitfalls P33。
4. ~~letterbox/fit~~ **✅ 已完成（2026-10-04，UIA-011 / ADR-0015）**：
   `FitMode` stretch/contain/cover，实现接缝 = 编码器视口原语（GFX/PAL additive，
   不动 IBlitPass 与 MSL）。门禁：Debug 42/42、Release 42/42、
   preview_renderer 51、c_abi_preview 78、gfx_device 30（含视口像素断言）、
   swift 23/23、SharedUI ×3 20/20。产品装配 = AppEntry 显式 contain。
   剩余：UIA-006 属性面板（需先定 MODEL-003）、多轨合成（等 RENDER-001）、
   素材库整理（拷入沙箱，D3）。
5. （低优）取帧流水线优化：`WaitForAsynchronousFrames` 等全部在途帧，
   可改 per-frame 同步进一步提高吞吐（ADR-0014 §后果 4）。

---

## 6. 本轮新增的坑（详见 `.ai/memory/pitfalls.md`）

- **P36** 消费端持锁期间调 `Request` → 死锁（第一版单测直接挂死）。
- **P37** 跨 `MTLCommandQueue` 访问同一纹理没有顺序保证 → 共享队列是刚需。
- **P38** 顺序播放每帧 seek = 每帧重解 GOP。→ **已修（MEDIA-021）**。
- **P39** VT 回调按完成序非显示序，B 帧必错帧 → 重排判据（ADR-0014 D4）。
- **P40** 首帧时长兜底用 pts 差 → B 帧素材区间报宽 4 倍 → 改 dts 差。
- **P41** decoder Flush 后旧在途回调帧污染新序列首弹 → Flush 先等在途落地。
- 附：CocoaPods 的 Pods target 是显式 `-fno-exceptions`，**连 `try` 都编译不过**
  （`cannot use 'try' with exceptions disabled`）。内核里不要写 try/catch，
  与 `TaskRunner` 同策略。
- 附（MEDIA-021 实测教训）：**测试请求网格必须整数 ticks 构造**——浮点
  `ms*120` 截断出 3999/4000 交替步长，大量请求落回同一帧区间，污染"严格
  递增"断言与性能均值（首版 120 请求仅 31 个不同 pts，即此因）。
