# ChuanqiCut 项目长期约定

## 用户与协作偏好（传哲）
- 称呼：传哲。直接、少废话，不要「好的/很高兴为您」这类填充语。
- 要求**批判性审视**：不要附和他的方案，发现事实错误、未验证假设、矛盾点要直接指出并给出依据。
- 交付判定 = 门禁通过，**不接受「已完成」的自述**。必须给出执行了什么命令、通过/失败、剩余风险。
- 数字必须可追溯：估算标 `[E]`，推测标 `hypothesis`，实测才能作为验收阈值。
- 他不介意我推翻自己上一轮的结论——只要给出理由。已发生过两次（Shader 单层→双层、低端机降级→明确不支持）。

## 项目定性
- 跨平台视频编辑 SDK + 各端原生 App。`core/`=C++20 内核，`pal/`=平台适配，`apps/`=原生 UI。
- **iOS / macOS 是重点支持平台**（P0）→ Android(P1，必须给方案) → HarmonyOS(P2，仅预留)。
- 鸿蒙本期**不动**，只做 `pal/ohos/` 接口编译检查。

## 不可协商的基线
- 性能基线 = 高端满足、**中端可用**、**明确不适配低端机**（不为低端机写专用降级路径）。
- 保留的是「能力缺失降级」（无硬解→软解、无 compute→fragment），因为中端机也可能缺某项能力。
- Shader 双层：Portable（`shaders/src/`，禁平台扩展）+ Platform-Native（`pal/<platform>/shaders/`，可用满平台特性，但永远可选、收益 < 20% 不合并）。

## AI 协作机制
- 单一真源 `.ai/source/AGENTS.root.md` → `tools/ai/sync_context.py` 生成 AGENTS.md / CLAUDE.md / .cursorrules / .windsurfrules / copilot-instructions.md。**改规则改真源，再跑脚本**，禁止手改生成物。
- 编码阶段：**一个任务一个新会话**，会话开场读真源 + 模块文档 + 任务单卡。见 `docs/ai/HANDOFF-001`。
- 任务结束必须回写 `.ai/modules/`、`.ai/memory/pitfalls.md`、`.ai/memory/baselines.md`。

## 产物打包约定（2026-09-29 定）
- **分发的静态库一律不开 LTO**（`tools/build/build_core_apple.sh` 默认 `--lto=off`）。
  Release + LTO 产出 bitcode-only `.o`，`xcodebuild -create-xcframework` 直接拒绝；
  且带 LTO bitcode 的分发库会强制消费者 linker 版本匹配。Release 的 `-O3` 保留。
- 主构建（日常开发 / CI / 单测）**仍开 LTO**，项目开关是 `CQ_ENABLE_LTO_RELEASE`。
  不能直接 `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF` —— 那个变量是
  `set(... CACHE BOOL ... FORCE)` 写的，`FORCE` 会让命令行 `-D` **静默失效**。
- **打包后必须做消费者侧链接冒烟**（`tools/build/smoke_link.cpp`）。
  理由：`xcodebuild` 成功只说明是合法 Mach-O，"能被 App 链接并运行"是另一件事。
- `.gitignore` 的目录规则必须写成 `/dir/` 锚定根。裸 `build/` 曾把 `tools/build/`
  一并忽略，导致三个构建脚本建库以来从未入库，且 `git status` 完全看不出来。

- **交付给外部工具链的静态库一律命名 `lib<Name>.a`**（2026-09-30 定）。
  曾用名 `ChuanqiCut.a` 导致所有 `-lNAME` 失效（`-lNAME` 只匹配 `libNAME.a`），
  表现为 `ld: library 'ChuanqiCut' not found`，且 `swift build` 因只编译不链接而全绿，
  直到 `swift test` 链接可执行宿主才炸。
- Swift 绑定验收有两条路径：`swift test`（SPM 集成）与 `run_smoke.sh`（swiftc 直编）。
  后者不依赖 binaryTarget，SPM 出问题时仍能证明"Swift 能调内核"。

## 分层与链接硬规则（2026-10-02 定）

- **core 不调 PAL 工厂**（既有惯例，全库 grep 可核：调用只发生在 tests/ 与 pal/）。
  理由：cq_core 若引用 PAL 符号，没有 PAL 后端的平台（Android / ohos）会链接失败。
- **确需调时，必须隔离在独立 TU**。静态库按 archive member 粒度拉符号，
  独立 TU 才能保证「不用该能力的目标」不被牵出 PAL 依赖。
  现有两个：`core/src/media/pal_frame_provider.cpp`、`core/src/preview/cq_sdk_preview.cpp`。
  回归验证：`cq_tests_c_abi` 只链 `cq_core`、不链 `cq_pal_apple`，必须保持通过。
- **抽象放哪层，看实现必然落在哪**。只能用平台原生能力实现的（shader 源码 /
  平台 SDK），抽象放 PAL（如 `IBlitPass` 在 `pal/gfx.h`）；放上层会导致 PAL
  反向依赖上层。上层要用时走逃生口（`IGfxDevice::PalDevice()` /
  `IGfxEncoder::PalEncoder()`）。

## 跨层句柄与链接硬规则（2026-10-03 定，UIA-003）

- **凡契约里写了「reinterpret 为平台对象」的句柄，必须有跨层测试真的
  reinterpret 并消费它**（pitfalls P20）。`GetColorTexture` 曾返回 CqTexture*
  包装却承诺可 reinterpret 为 id<MTLTexture>，绑定测试只查非空是绿的，
  Swift 首用即崩。导出用（裸原生纹理）与 SetTexture 用（CqTexture* 包装）
  两种句柄语义已在 `pal/gfx.h` 写清，不得混用。
- **内核静态库的系统框架依赖清单单一真源 = `ChuanqiCut.podspec` 的
  ss.frameworks**；`bindings/swift/Package.swift` linkerSettings 与
  `run_smoke.sh` 链接清单必须与之同步（pitfalls P23）。静态库新拉入 TU
  （如预览/媒体）会引入新的系统框架依赖，三处清单一起改。
- 本机（Intel Mac + AMD GPU / macOS 15.4）`MTLTexture.getBytes` 读不到 GPU
  写入内容：读回一律 blit→Shared Buffer→contents（pitfalls P21）。

## 模型变更硬规则（2026-10-03 定，MODEL-002）

- **Timeline 只能经 CommandHistory 变更**（红线 #5 的执行点）。绕过直改会让
  历史里的 id 引用悬空，Undo/Redo 静默失效。
- **Add/Insert 类命令的 Redo 必须走 `RestoreTrack/RestoreClip` 恢复原 id**；
  重放 Add/Insert 会分配新 id（pitfalls 同类：「id 是单调查分配的，回放不能重分配」）。
- 编辑类命令只存增量（id + old/new），结构类命令只允许持有**单个实体**内容；
  模型级快照一律禁止。

- **新 ABI 的返回值语义必须单一**：错误码 XOR 数据，绝不混用（P26）。
  条数类结果一律走 out 参数；新函数统一「状态码 + out_count」。
- **mv/rm 源文件后立即 grep 文件名引用并重跑受影响脚本**（P27，E10 同族）。
- **测试里的 #filePath 上溯链不得手写**（P30）：一律用共享 helper
  （bindings→TestPaths.root、SharedUI→RepoPath.root）；新建 helper 时层数
  必须打印实际结果验证后写死并逐层注释。

## 依赖治理硬规则（ADR-0008）
- FFmpeg upstream 用 **GitHub 官方镜像** `https://github.com/FFmpeg/FFmpeg.git`（ffmpeg.org 登记为官方 mirror），本地 git 管理。
- **源码集成的 git 依赖一律 `pin="commit"` + 40 位 hash。禁止 `pin="tag"`。**
- 「定期拉最新」= **人工 bump `pin_ref` + 完整 CI**，绝不允许 CI 自动跟随任何分支/HEAD。理由：跟随变动引用会摧毁可复现构建，让 golden/PSNR 随机失败，且 LGPL 审计无法指认具体源码。
- **`version` 字段必须 `git ls-remote` 核对，不得凭印象写。** 已发生过 6 处编造版本号（ pitfalls E6）。

## 上下文同步（2026-10-02 传哲要求：每次搞完都同步）

**收工前必须逐项落盘**，清单在 `.ai/source/AGENTS.root.md`「任务结束必须同步上下文」
一节（真源，跑 `tools/ai/sync_context.py` 生成五份入口文件 —— 改规则改真源，别手改产物）。
8 项：`.ai/modules/` → ADR（**改了既有惯例就必须新增**）→ TASK 卡 → HANDOFF →
pitfalls → baselines → 当日日志 → MEMORY.md（新确立的硬规则写这里，不留在日志里）。

⚠️ 这条原本在真源里只有 4 行泛泛描述，导致连续两轮（BIND-003 子步骤 4/5）
都漏了 `.ai/modules/` 和 ADR —— **模糊的"要回写"等于没写**，故改成逐项清单。

## 已拍板的基线（2026-09-25，见 ADR-0010）

- **最低系统版本：iOS 16 / macOS 15.4**（此前未写进任何文档，已固化）
- **容器格式**：沿用常用子集档位（17 demuxer），专业格式（mxf/dnxhd/r3d）本期不支持
- **Android**：接受排 Phase 3；鸿蒙维持仅接口编译检查
- **团队**：当前**单人**开发，不做并行 write_set 划分；有新人后再拆分
- **真机**：参考 iPhone 17 Pro，等 iOS 能跑由传哲本人实测
  → **日志与埋点必须先行做扎实**（他明确要求），到时直接看结果，不临时补埋点

## FFmpeg 的授权档位（传哲 2026-09-25 明确）

**要求：不使用 GPL 相关代码，保持 LGPL。** 这与已构建产物完全一致，无需改动：
`license=LGPL-2.1-or-later`、`CONFIG_GPL=0`（无 GPL 代码）、`CONFIG_LGPLV3=0`、`profile=demux`。

⚠️ **LGPL ≠ 无义务**（别因为"只是 LGPL"就忽略）：
LGPL v2.1 对**静态链接**的核心要求是 **接收者能用修改过的库版本替换并重新链接**。
所以「技术能用」与「可以分发」是两件事：现在未接入构建 → 义务未触发；将来要分发 → 需选
relink 能力 / 目标文件归档 / 商业授权 / 动态链接 之一。

（2026-09-25 我一度把"不用 GPL、保持 LGPL"误读成"规避 LGPL"，已更正。传哲的判断无误。）

**当前不阻塞**：产物**未接入任何构建目标**（core/ 与根 CMakeLists.txt 均未引用 ffmpeg），
未链接未分发 → LGPL 附加义务暂未触发。

**因此产生的架构约束**：CORE-006 的 PAL Media 接口**不得依赖任何 FFmpeg 类型**
（禁止 `AVFormatContext` / `AVPacket` 等）。接口必须抽象，否则将来
「接入 FFmpeg（承担 LGPL）」与「走平台原生 AVFoundation/MediaExtractor（零 LGPL）」
之间的切换会变成跨层返工。

## 悬而未决（需传哲拍板，AI 不得代决）
1. **FFmpeg LGPL v2.1+ 的链接处置**（目标文件归档 / 商业授权 / 动态链接；或干脆不接入 FFmpeg
   改走平台原生）—— 需 + 法务。**已确认延后，不阻塞当前开发**（见上）。
2. 性能基线尚未建立（PERF-001 未做），文档中所有性能数字仍是估算。
   注意：本机 Intel Mac **无 ANE、无 ProRes 硬编**，性能数字不得取自本机。

## 交接（2026-09-28）：完整上下文已写入 docs/HANDOFF-002-编码阶段会话交接.md

新会话接手前**先读 HANDOFF-002 + `.ai/source/AGENTS.root.md`**。
其中包含：已完成清单（26 commit）、能力链路、未完成项（XCFramework 合并）、
iOS 平台差异五处修复、门禁命令、红线摘录、下一步优先级、本轮教训。

**传哲指示：bitcode 不要开** —— 不为打包便利开启 bitcode，也不用 `-fno-embed-bitcode`
之类选项绕过（该 Xcode 的 clang 不识别，已撤销）。XCFramework 合并这最后一步待新会话处理，
且接手时**先确认 .a 是否真的含 bitcode 段**——若未开 bitcode 却仍报 `Unknown header: 0xb17c0de`，
说明根因不是 bitcode，需重新定位，不要沿用旧推测。
