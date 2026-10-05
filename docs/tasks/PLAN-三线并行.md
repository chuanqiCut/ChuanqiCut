# PLAN — 三线并行开工方案（CODE-001 配套，2026-10-05）

> 背景与授权：传哲 2026-10-05 拍板——项目后期**三条线同时开工**；本设备（主力机）
> 作为**集成机**，定期检查其他设备合并过来的代码；其他设备性能差、很多门禁不过，
> **整体门禁口径以集成机为准**。
> 前置：全库风格巡检已完成（`docs/reviews/REVIEW-2026-10-05-全库风格巡检.md`），
> 风格标准 = `docs/CODESTYLE.md`，审查流程 = `.agents/skills/cq-code-review`。

## 1. 三条线定义（写集互不相交）

| 线 | 任务前缀 | 域 | 写集（可改） | 禁改（热点，见 §3） |
|---|---|---|---|---|
| **A 编辑器/UI 线** | `UIA-*`、`MODEL-*` | 时间线交互、属性面板、素材库、导出 UI | `apps/apple/packages/SharedUI/**`（除相机契约层）、`bindings/swift/**`、`core/src/preview/**`、`core/include/cq/preview/**` | `core/include/cq/cq_sdk.h`、各 `CMakeLists.txt`、`Package.swift`、`ChuanqiCut.podspec`、`manifest.toml` |
| **B 相机/特效线** | `CAM-*`、`CAP-*` | 相机采集、检测、美颜美型、贴纸 | `apps/apple/ios/iOSApp/Camera/**`、SharedUI 的 `Camera*` 契约层文件、`pal/apple/**`（相机/检测相关）、`docs/specs/`（相机域） | 同上热点；SharedUI 非相机文件；`bindings/swift` |
| **C 内核/媒体/渲染线** | `CORE-*`、`MEDIA-*`、`RENDER-*`、`AUDIO-*`、`GFX-*`、`EXPORT-*` | 解码/编码、渲染图、音频、shader、导出 | `core/src/{media,render,gfx,audio,command}/**`、`core/include/cq/{media,render,gfx,audio,command}/**`、`shaders/**`、`tests/golden/**`、`tools/shaders/**` | 同上热点；`bindings/swift`（ABI 变更走集成机）；SharedUI |

约定：

- 每线内部仍按 AGENTS.md 走：Spec（cq-spec-authoring）→ Task 卡（cq-task-planning）
  → 编码 → 门禁（cq-build-test）→ 上下文同步 8 项。
- 跨线需求（比如相机特效要新增内核能力）→ 拆成两张卡，各线一张，接缝写成
  ADR 或接口提案提交集成机，**不跨写集直改**。
- SharedUI 内部，线 A 与线 B 的交界 =「相机契约层」（`Camera*` 参数结构 + 注入点，
  ADR-0014 §3）。新增契约文件归线 B，修改既有契约需双方在任务卡里互相登记。

## 2. 号段与取号协议（防撞号，撞号案底：UIA-011/ADR-0013-0015/P36-39）

1. **集成机是唯一发号器**：任务 ID（TASK-BACKLOG 登记）、ADR 编号、pitfalls P 编号，
   一律向集成机申请；每线一次领 **5 个号**的号段，用完再领。
2. 领号记录写进 TASK-BACKLOG 对应行 + 当日工作日志；**登记即占号**。
3. 兜底：来不及申请时，`git fetch` 后核对远端 BACKLOG/ADR/pitfalls 的已用号，
   改动面小的一侧让位（沿用 2026-10-04 编号纪律）。
4. 当前号段状态（2026-10-05 第二次更新，含 AIEDIT 撞号处置后）：

| 线 | 任务号段 | 已预占 | ADR 现状 | pitfalls 现状 |
|---|---|---|---|---|
| A 编辑器/UI | UIA-015~018、MODEL-003~005（**UIA-019 已被 AIEDIT 线占用**） | 空 | ADR 已用至 0021（0019=智能成片让位改号、0020 缺口留补录），**新号从 0022 起向集成机申请** | P51 已用（撞号处置），新号从 P52 起 |
| B 相机/特效 | CAM-015~019、CAP-* | CAM-015~019 | 同上 | 同上 |
| C 内核/媒体/渲染 | MEDIA-022~024、RENDER-004~005、AUDIO-005~009 | 空 | 同上 | 同上 |
| AIEDIT 智能成片（2026-10-04 立项，视作第 4 条线或并入 A，传哲拍板） | AIEDIT-012~015（000~011 已占） | AIEDIT-000~011 | 同上 | 同上 |
| 集成机 | STYLE-001~005、INFRA-010~012（已登记 ✅） | 已占 | — | — |

⚠️ 2026-10-05 实锤：两个并行会话在同一天各自取了 ADR-0016（预览取帧 vs 智能成片），
事后只能按"改动面小的一侧让位"返工（P51）。**结论：fetch 核号防不住同日并行
取号，只有集成机发号器能防住——各线开工前先领号段。**

## 3. 高冲突文件（任何线都禁改，归集成机）

- `core/include/cq/cq_sdk.h` —— 唯一对外 ABI。各线需要新 ABI 时提交「接口提案」
  （任务卡 §接口变更 一节写清：C 签名 + 语义 + 错误码 + 三端投影），由集成机
  统一落地并跑三端绑定验证。
- 一切 `CMakeLists.txt`、`Package.swift`、`ChuanqiCut.podspec`、`manifest.toml`、
  `.ai/source/AGENTS.root.md`（真源）、`.github/workflows/`。
- 依赖变更必须走 cq-dependency-governance skill + 集成机。

## 4. 合并与守门节奏（整体口径以集成机为准）

1. **提交**：各线在自己机器上 `git push` 到 `origin/main`（小步、一任务一 commit
   或分支合并，沿用现行实践）；commit message 带 Task ID。
2. **守门（核心）**：集成机定期（建议每日 + 每次开工前）`git fetch && git pull`
   → 跑 `cq-code-review` skill **流程 A（合并守门）**：
   - `tools/ci/run_gate.sh` 全量重跑（远端"已验证"一律按未验证处理）；
   - 写集越界检查（diff vs 任务卡声明）；
   - 远端薄弱点专项：Swift 相机文件 `iphonesimulator -typecheck`（P46/P48 案底）、
     Swift 6 发送域、重复声明、`-Werror` 真伪。
3. **分级处置**：P0（编译不过/测试红/越界改热点文件）→ 修复前该线停止合并新代码；
   P1 → 集成机顺手修并记录；P2 → 登记任务卡。
4. **基线纪律**：性能数字引用必须带机器环境（baselines.md 记录双机差异）；
   跨机性能对比仅在集成机数字之间进行。

## 5. 本机（集成机）角色清单

- 发号器 + 高冲突文件守门 + ADR 归口。
- `run_gate.sh` 全量门禁是唯一验收口径；门禁数字（如 `Debug 42/42、Release 42/42、
  swift 23/23、SharedUI 54/54`）必须出自本机日志。
- iOS 真机验证仍由传哲本人做（iPhone 17 Pro，本机无 iOS 运行时）。
- 定期风格巡检（cq-code-review 流程 C）：建议每周一次，或某线连续合入 >10 commit 时。

## 6. 会话起手式（每线每会话）

1. 读 `.ai/source/AGENTS.root.md` → `docs/HANDOFF-004`（或最新）→ 本文件。
2. 读自己线的任务卡；**取号先看 §2 号段表，号段用完先向集成机申请**。
3. 收工跑 cq-build-test + 上下文同步 8 项；推送后在自己线的日志里登记
   「推了什么、Task ID、自查门禁数字（仅供参考，验收以集成机为准）」。
