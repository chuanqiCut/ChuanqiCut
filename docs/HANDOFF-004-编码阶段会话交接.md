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
| 播放 | **UIA-010 子步骤 1~5 全部完成**（时钟 + 播放入口 + 取帧泵） | ✅（2026-10-04） |
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

1. **TASK-MEDIA-021**（顺序取帧不必每帧 seek）—— 预览能不能看的**唯一**阻塞项。
2. **iOS 编译与真机验证**（传哲本人做，iPhone 17 Pro）：本机无 iOS 运行时，
   自 2026-10-03 起 iOS 侧改动**只有 macOS 路径被编译过**。
3. **P33 定位**：`MediaImportTests` 偶发失败（probe 成功但时长 0），根因未证 ——
   真机"导入无反应"会是同一症状，别拖。
4. UIA-006 属性面板（需先定 MODEL-003）、letterbox/fit、多轨合成（等 RENDER-001）、
   素材库整理（拷入沙箱，D3）。

---

## 6. 本轮新增的坑（详见 `.ai/memory/pitfalls.md`）

- **P36** 消费端持锁期间调 `Request` → 死锁（第一版单测直接挂死）。
- **P37** 跨 `MTLCommandQueue` 访问同一纹理没有顺序保证 → 共享队列是刚需。
- **P38** 顺序播放每帧 seek = 每帧重解 GOP。
- 附：CocoaPods 的 Pods target 是显式 `-fno-exceptions`，**连 `try` 都编译不过**
  （`cannot use 'try' with exceptions disabled`）。内核里不要写 try/catch，
  与 `TaskRunner` 同策略。
