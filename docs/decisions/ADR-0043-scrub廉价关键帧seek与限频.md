# ADR-0043：轨道 scrub 用「廉价关键帧 seek + 限频 + 松手精确确认」替代逐帧精确 seek

- 状态：已采纳（2026-10-16）
- 决策者：传哲（模型：WorkBuddy）
- 关联：P142（Platform 接缝携带策略）、P141（孤立 doc 注释）、ADR-0017（每帧重解 GOP 是预览帧率真瓶颈）、ADR-0024（编辑页每帧驱动）
- 取代惯例：`ChqIFrameProvider`（Platform 接缝）此前**只承诺精确 seek**，非 `kExact` 一律拒绝

## 背景 / 问题

轨道 scrub（拖动播放头）时，每个手势 delta 都走
`onScrub → setPlayhead → PreviewPump.request → 预览渲染器 AcquireFrame → ChqSystemFrameProvider::Seek(kExact)`。
`kExact` 的契约是「返回 target 处真正的展示帧」，代价是**每次从最近关键帧重解整个 GOP**。

后果（传哲真机实测，iPhone 17 Pro / iOS 26.6.1 / Debug，2026-10-16）：
- 拖动明显卡顿，**逆向（向后）滑动更卡**（要找更早的关键帧再正向解码）；
- 长 GOP 解码占满泵线程所在单核 → 与滚动/手势处理的主线程**抢同一核**；
- 「播放后一滑动就暂停」是设计使然（`onScrub` 先 `pausePlayback`，否则播放循环会持续把
  刚拖到的位置覆盖掉），不是 bug。

关键发现：core 的 `ChqSystemFrameProvider` **早已完整实现** `kKeyframeBefore` / `kNearest`
（见 `chq_system_frame_provider.h`），能力是现成的，只是被「Platform 接缝不携带 policy」
这一层挡死 —— 预览渲染器硬编码 `kExact`、`ChqPlatformFrameProvider` 见非 `kExact` 就拒。

## 决策

传哲定的口径：「滑动的时候应该是快速 seek，而且要控制 seek 频率，seek 应该放在子线程完成，
有新帧之后再刷帧，滑动结束之后走一次精准 seek 然后刷一帧。」拆成四条可执行契约：

1. **滑动中 = 廉价 seek**：拖动期间取帧传 `kKeyframeBefore`（<= t 最近关键帧），
   不再逐帧精确重解 GOP。
2. **限频**：滑动中把**取帧 seek 频率**压到 ~24Hz（`EditorViewController.scrubSeekInterval`）。
   播放头本身仍按 40Hz 推（红条跟手），只是「发解码请求」限频 —— 否则高频 delta 即便用
   廉价帧也白烧 CPU 与泵吞吐（泵虽会合并，但已渲染的那帧仍是一次解码）。
3. **seek 在子线程 + 有新帧再刷帧**：沿用既有 `PreviewPump` 架构（seek/解码/导入在泵线程，
   主线程只 blit）。「有新帧再刷帧」= 既有的自驱重绘 + `PreviewSettleRule`（按 seq 收敛），
   本次不改语义，只把 seek 策略接进去。
4. **松手 = 一次精确**：新增 `onScrubEnded` 出口（`EditorTimelineKitView.endUserScrub` 触发），
   松手补一次 `kExact` 精确帧，保证用户看到的终值画面精确，不是近似帧。

## 怎么把策略送到解码器（跨层契约变更）

`ChqSeekPolicy` 定义在 core 的 `chq_frame_provider.h`，而该头**已经** include
`cq/platform/chq_media.h`。故 Platform 接缝**不能**反向 include core 头（成环，P142）。
约定：**Platform 接缝用中立 `int32_t seek_policy=0` 携带 core 枚举的底层值（0/1/2）**，
只在 core 层（已 include core 头的 `ChqSystemFrameProvider` / 预览渲染器）转回 `ChqSeekPolicy`。

各层改动（默认值保既有调用不变）：
- `ChqIFrameProvider::Seek/AcquireFrame`：末尾加默认参数 `int32_t seek_policy = 0`。
- `ChqPlatformFrameProvider`：删掉「非 kExact 一律拒绝」，改为透传。
- Apple `CqFrameProvider`：接收 policy，`static_cast<ChqSeekPolicy>` 转发给 core。
- `ChqIPreviewFrameSource::RenderFrame`：加末位默认参数 `int32_t seek_policy = 0`
  （放末位保住既有 3 参调用）。
- `ChqPreviewPump::Request(pts, seek_policy=0)` + 成员暂存，`Loop` 透传给 `RenderFrame`。
- 预览渲染器：`RenderFrame` 入口把 policy 存入成员 `seek_policy_`，`Acquire` 读它 ——
  **不沿 RenderGraph 逐层传参**（同帧内 policy 恒定 + 同在泵线程无竞争；且不改
  `ChqIFrameSource` 接口，少动一处跨模块契约）。
- C ABI：新增 `cq_preview_pump_request_ex(..., seek_policy)`；原 `cq_preview_pump_request`
  保留、语义等价于传 0（kExact），既有 ABI 不破。
- Swift：`PreviewPump.SeekPolicy`（exact/keyframeBefore/nearest）+ `request(pts:policy:)`。

## 影响面 / 边界

- **只影响预览取帧路径**。导出 / 播放 / 单帧 / golden 校验一律仍走 `kExact`（默认 0），
  编辑正确性不受影响。拖动结束的终值帧也是 `kExact`。
- Platform 接缝的既有平台实现（当前仅 Apple）签名带默认值，未实现新策略的平台
  若将来接入，仍可只实现 `kExact`（默认）而编译通过 —— 但**不得**静默把非精确策略
  当精确处理（那会让 scrub 悄悄变回卡顿路径且无日志），实现方须显式支持或显式拒绝。
- 本决策**不引入**读-ahead 预解码（那属另一件事，见 PreviewPump 文件头「它不提高帧率」）。

## 验证

- iOS 壳 `xcodebuild build`：**BUILD SUCCEEDED**（0 错）。
- `tools/build/build_core.sh --platform=apple`：通过。
- `ctest -R "preview_pump|preview_renderer|system_frame_provider|c_abi_preview|sequential"`：**6/6 PASS**
  （含 `media_sequential_real` 真素材 69s）。新增断言：预览泵第 9 组「seek 策略透传」
  验证 0/1/2 原样到达渲染器。
- **真机复验待回收**（传哲）：拖动跟手/不卡、滑动中预览为关键帧近似、松手后精确帧。

## 署名

- 模型：WorkBuddy｜时间：2026-10-16｜代码：见任务卡 TASK-P142
- 拍板：传哲「滑动快速 seek + 限频 + 子线程 + 结束精准 seek」
- 后续调整：待真机复验后回填实测数字（拖动帧率、seek 耗时 before/after）到 `.ai/memory/baselines.md`
