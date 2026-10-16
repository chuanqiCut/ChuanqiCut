# HANDOFF-024：#21 旋转收尾 + P142 scrub 快速 seek 批交接

- 日期：2026-10-16
- 交接人：WorkBuddy（模型）
- 拍板人：传哲
- 关联：#21（竖屏/旋转源朝向）、P142（scrub 廉价关键帧 seek）、P141、P134~P140（既有编号）
- 关联 ADR：ADR-0043（本次新增）、ADR-0042（TimelineKit，在途 WIP）
- 本机前提：集成机，macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / **Intel x86_64** / 无 Homebrew

---

## 一、本轮做了什么（两件独立的活）

### 活 1：#21 竖屏/旋转源朝向（GPU blit UV 旋转）— 已装机待真机复核

- 根因回顾：解码阶段曾用 Core Image 旋转像素 → 对无标签 BGRA 缓冲做 sRGB 色彩转换 → **色偏**。
  返工为 **GPU blit 层 UV 旋转**（color-safe 直通，不动色彩空间）。
- 编译期抓到并修 **两个真实 bug**：
  1. `DeriveRotationDeg` 定义在文件末尾匿名命名空间，调用点无前向声明 → 已在 `namespace cq` 顶部补声明。
  2. **旋转角全程 `uint8_t` 截断**：270 > 255 → `static_cast<uint8_t>(270)=14`，静默丢失 270° 源（iPad 竖屏）。
     整条链路（8 个存储点 + 形参 + evaluator 局部）改 `uint16_t`。
- **真机首轮反馈「画面倒立」→ 已修正**：blit 把显示旋转角 R 直接传给 `RotateUv`，但 UV 层须施加 **R 的逆**
  （`uv_s = Rot^{-1}(uv_d)` 才还原 `display = Rot · encoded`）。修 `blit_pass.mm` `Encode`：传 `(360-R)%360`。
- iOS + macOS 双壳均 BUILD SUCCEEDED。已装机，**待传哲复核朝向不再倒立 + 色彩无偏**。

### 活 2：P142 轨道 scrub 卡顿修复 — 已装机待真机复核

- 传哲定的口径：「滑动时快速 seek + 控制 seek 频率 + seek 在子线程 + 有新帧再刷帧 + 结束走一次精准 seek」。
- 根因：scrub 每 delta 走 `kExact` 精确 seek → **每次从最近关键帧重解整个 GOP**；长 GOP 解码占满泵线程单核、
  与滚动主线程抢核 → 卡顿；逆向（向后）要找更早关键帧再正向解，**更贵**。
- 关键发现：core `ChqSystemFrameProvider` **早已实现** `kKeyframeBefore`/`kNearest`，被「Platform 接缝不携带 policy」挡死。
- 落地（详见 ADR-0043）：
  - **滑动中**：`kKeyframeBefore` 廉价关键帧 + **限频 24Hz**（`scrubSeekInterval`）；播放头本身仍 40Hz 跟手，只压解码请求。
  - **松手**：新增 `onScrubEnded` → 补一次 `kExact` 精确帧（终值画面精确，不是近似帧）。
  - **seek 在子线程 + 有新帧再刷帧**：沿用既有 `PreviewPump`（seek/解码在泵线程，主线程只 blit）+ 自驱重绘按 seq 收敛，本轮不改语义只接策略。
- **跨层契约**（`ChqSeekPolicy` 用中立 `int32_t` 穿接缝，因 `chq_frame_provider.h` 已 include `chq_media.h`，反向 include 会成环 = P142）：
  `ChqIFrameProvider::Seek/AcquireFrame` 加默认参数 → `ChqPlatformFrameProvider` 删拒绝改为透传 →
  Apple `CqFrameProvider` 转回 `ChqSeekPolicy` → `RenderFrame`(末位默认参数) → `ChqPreviewPump::Request`(暂存+Loop 透传) →
  渲染器存成员 `seek_policy_`（同帧恒定+同线程，不沿 RenderGraph 逐层传）→ C ABI `cq_preview_pump_request_ex`（原函数保留等价传 0）→
  Swift `PreviewPump.SeekPolicy` + `request(pts:policy:)`。
- 验证：iOS 壳 BUILD SUCCEEDED（0 错）；`build_core.sh --platform=apple` 通过；
  `ctest -R "preview_pump|preview_renderer|system_frame_provider|c_abi_preview|sequential"` **6/6 PASS**（含真素材 69s）；
  新增断言：预览泵第 9 组验证 0/1/2 策略原样到达渲染器。

### 附带：DEBUG 浮层尺寸整改（传哲反馈）

`DebugOverlayView.expandedPanel` 宽 300→`min(屏宽-16,380)`、高 `maxHeight 360`→`屏高×0.35`；宿主宽度上限 320→400。
竖排绿字 key:value 保持。**iOS 壳编译通过，已装机。**

---

## 二、本轮提交了什么（写集严格隔离）

- **提交 commit**：P142 内核+绑定+测试+ADR+pitfalls（14 文件，干净写集，见下）。
- **未提交、留在工作树**（**不属于本轮写集**，多为 TimelineKit 迁移 WIP + 前批遗留）：
  - `AppEntry.swift` / `MetalPreviewView.swift` / `DebugOverlayView.swift` / `EditorViewController.swift`：
    P142/DEBUG 的 UI 改动与 TimelineKit WIP 改动**混在同一文件**，无法干净切分（DebugOverlayView 130 行里大部分是 WIP 的竖排/拖动改造）。
  - `EditorTimelineKitView.swift` / `TimelineKitAdapter.swift` / `TimelineKitIntegrationPreview.swift`（未跟踪新文件）
  - `ADR-0042` / `TASK-UIA-044` / `TASK-UIA-045` / `QUESTIONNAIRE-UIA-044/045`（未跟踪）
  - `EditorTimelineUIView.swift`（已删除未提交）、`ChuanqiCutApp.swift` / `HomeView.swift` / `EditorChromePalette.swift` /
    `EditorLayout.swift` / `TrackInteraction.swift` / `chq_gfx.h` / `chq_frame_source.h` 等。
  - **⚠️ 纪律说明**：UI 层 P142 改动（含 `onScrubEnded` 接线、`isScrubbingTrack`、限频器）**依赖未跟踪的
    `EditorTimelineKitView.swift`**（`onScrubEnded` 出口定义在该 WIP 文件里）。因此**内核提交可独立编译通过，
    但完整 App 的 P142 功能要等 TimelineKit WIP 一起落地才生效**。交接给下一批时务必注意这条依赖。

---

## 三、待办 / 未决

1. **真机问卷未回收**（#21 + P142 + DEBUG 浮层三合一，问卷已发，待传哲填写）：
   - #21：竖屏朝向不再倒立 + 色彩无偏
   - P142：拖动跟手不卡（尤其逆向）、滑动中为关键帧近似、松手后精确帧
   - DEBUG 浮层：高度≈屏高 35%、更宽、竖排绿字
   - **问卷回收前不标记 #21 / P142 完成。**
2. **全量门禁未跑**：本批只跑了相关 6 个测试 + 双壳构建，**未跑 `run_gate.sh` 全量**（需传哲同意）。
3. **baselines 实测数字待回填**：真机复验后把「拖动帧率、seek 耗时 before/after」补进 `.ai/memory/baselines.md`。
4. **UI 层 P142 落地**：等 TimelineKit WIP（ADR-0042）收口时，把本轮留在工作树的 UI 改动一并提交。
5. **commit 拆分建议**：若要一个干净的完整提交，建议「内核 P142」+「UI（随 TimelineKit 批）」分两次；本轮已按写集隔离只提内核。

---

## 四、给下一批的关键提醒

- **写集纪律**：工作树当前 47 项变动里混了三批（#21 / P142 / TimelineKit WIP）。**不要 `git add .`** ——
  会把 WIP 卷进提交。本轮已逐文件核验只 add 干净写集。
- **P142 接缝约定**：`ChqIFrameProvider` 用中立 `int32_t` 携带 core `ChqSeekPolicy` 底层值（0/1/2）；
  新接平台若不支持非精确策略，**须显式拒绝**，不得静默当精确处理（否则 scrub 悄悄变回卡顿且无日志）。
- **P141 教训**：改函数前先 `Read` 真实签名行号（`AppEntry.setPlayhead` 的 doc 注释是孤立的，被 `#if DEBUG` 块隔开，
  按「注释+func」做锚点 Edit 会吞掉 `#if DEBUG` 并造重复函数）。
- 决策署名见 ADR-0043；坑见 P141/P142（`.ai/memory/pitfalls.md`）。