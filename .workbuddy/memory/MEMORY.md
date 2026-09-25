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

## 悬而未决（需传哲拍板，AI 不得代决）
1. **FFmpeg LGPL v2.1+ 的链接处置**（目标文件归档 / 商业授权 / 动态链接）—— 阻塞 DEPS-010~012 的定型与打包架构，需 + 法务。
2. 性能基线尚未建立（PERF-001 未做），文档中所有性能数字仍是估算。
