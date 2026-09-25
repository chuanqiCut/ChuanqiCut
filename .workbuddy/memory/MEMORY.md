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

## 依赖治理硬规则（ADR-0008）
- FFmpeg upstream 用 **GitHub 官方镜像** `https://github.com/FFmpeg/FFmpeg.git`（ffmpeg.org 登记为官方 mirror），本地 git 管理。
- **源码集成的 git 依赖一律 `pin="commit"` + 40 位 hash。禁止 `pin="tag"`。**
- 「定期拉最新」= **人工 bump `pin_ref` + 完整 CI**，绝不允许 CI 自动跟随任何分支/HEAD。理由：跟随变动引用会摧毁可复现构建，让 golden/PSNR 随机失败，且 LGPL 审计无法指认具体源码。
- **`version` 字段必须 `git ls-remote` 核对，不得凭印象写。** 已发生过 6 处编造版本号（ pitfalls E6）。

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
