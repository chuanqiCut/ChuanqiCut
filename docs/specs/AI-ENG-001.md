[//√](../../../../../..)# AI-ENG-001：ChuanqiCut AI 原生软件工程工作流

> 状态：提案（Implementation-ready baseline）  
> 日期：2026-08-12  
> 适用项目：ChuanqiCut（SwiftUI / Metal / VideoToolbox / AVFoundation / FFmpeg / CoreML）

## 1. 目标

建立一套能支持单人、多人和本地多任务并行的 AI 软件工程工作流。目标不是让 Agent“自由写代码”，而是让每个任务都具备：

```text
明确目标 → 有界上下文 → 可追踪任务 → 隔离执行 → 自动验证 → 人工决策 → 可回溯记忆
```

第一版采用“Codex 作为主要执行入口 + Git/CI 作为事实边界 + 仓库内知识库作为共享记忆”的组合，不自研 Orchestrator，也不把模型绑定到业务代码中。

## 2. 非目标

- 不一次性建设 10～20 个长期运行的自治 Agent。
- 不用聊天记录替代 Spec、ADR、Issue、测试和 PR。
- 不让多个 Agent 同时修改同一组文件。
- 不让本地记忆成为团队规范的唯一来源。
- 不在没有评估基线的情况下自动合并核心渲染、媒体管线或发布变更。

## 3. 设计原则

1. **Specification-first**：需求先转为目标、约束、验收标准，再进入实现。
2. **Context isolation**：主线程保留决策；探索、日志、测试等噪声下沉到子 Agent。
3. **DAG over swarm**：只有无强依赖的任务才并行，强顺序依赖保持串行。
4. **One writer per file set**：每个任务声明唯一写入边界；共享文件由 Integrator 处理。
5. **Evaluation is the completion signal**：Agent 的自述不算完成，Build/Test/Eval/Review 才算。
6. **Human governance**：生产、发布、权限、数据删除和核心媒体链路保留人工批准。
7. **Repository is canonical**：团队共享知识入库；本地记忆只用于个人召回。

## 4. 推荐总体架构

```text
Human
  ↓ 目标 / 约束 / 风险偏好
Planner
  ↓ Spec + Task DAG
Context Builder
  ↓ Global Rules + Module Context + Task Context
Agent Runner
  ├─ Researcher（只读）
  ├─ Architect（只读/文档）
  ├─ Coder（限定写集）
  ├─ Tester（测试与验证）
  ├─ Reviewer（只读审查）
  └─ Debugger（失败后限定修复）
  ↓
Worktree / Branch → Build/Test/Eval → Review → PR → Merge
  ↓
ADR / Module Docs / Pitfalls / Metrics
```

Codex 当前支持分层 `AGENTS.md`、Skills、MCP、Subagents 和 Git worktree；这些能力分别解决规则、工作流、工具、并行推理和代码隔离问题，不能互相替代。

## 5. 仓库目录基线

```text
ChuanqiCut/
├── AGENTS.md                         # 根级硬规则，建议 < 200 行
├── .agents/
│   └── skills/                       # 项目技能，随仓库版本化
│       ├── spec-authoring/SKILL.md
│       ├── task-planning/SKILL.md
│       ├── ios-build-test/SKILL.md
│       ├── media-pipeline-review/SKILL.md
│       ├── metal-performance/SKILL.md
│       ├── code-review/SKILL.md
│       └── incident-memory/SKILL.md
├── .codex/
│   ├── config.toml                   # 项目级 MCP/Agent 配置（仅可信仓库）
│   └── rules/                        # 可选的命令权限规则；不存业务规范
├── .ai/
│   ├── context/                      # 可生成的模块上下文摘要
│   ├── modules/                      # 模块边界、入口、依赖、验证方式
│   ├── tasks/                        # TASK-*.md，任务事实源
│   ├── decisions/                    # ADR-*.md
│   ├── memory/                       # known-issues / pitfalls / patterns
│   └── runs/                         # 可选：任务执行摘要和评估结果
├── docs/specs/                       # 经确认的技术规格
├── scripts/ai/                       # 可重复的索引、验证、报告脚本
└── .github/ 或 CI 配置                # 强制性验证和 PR 门禁
```

`.ai/context` 和 `.ai/runs` 可以由脚本生成；`AGENTS.md`、模块文档、任务、ADR 和 CI 规则必须经过 Review 后才视为事实。

## 6. Rule、Skill、MCP、Memory 的分工

### 6.1 Rule：不可违反的运行约束

放在 `AGENTS.md`、CI、代码审查规则中：

- 项目如何构建、测试和格式化。
- 哪些目录属于哪个模块。
- 哪些 API/协议/线程模型不能破坏。
- 哪些操作必须批准。
- 完成任务必须返回哪些证据。

不要把详细流程、长篇技术知识和一次性任务放入根 `AGENTS.md`，否则会污染所有任务上下文。模块细则放到更深层 `AGENTS.md` 或 Skill 中。Codex 会从全局到项目根再到当前目录按层合并，越近的文件优先；默认项目文档上限为 32 KiB，因此根规则应短小。

### 6.2 Skill：可复用的过程模板

第一批只配置 7 个项目技能：

| Skill | 触发条件 | 必须产出 |
|---|---|---|
| `spec-authoring` | 新需求、范围不清 | Spec、非目标、验收标准、开放问题 |
| `task-planning` | Spec 已确认 | Task DAG、依赖、写集、并行批次 |
| `ios-build-test` | Swift/ObjC/Xcode 改动 | 构建命令、测试矩阵、日志摘要 |
| `media-pipeline-review` | 解码、渲染、编码、音频改动 | 线程/时序/内存/取消分析 |
| `metal-performance` | Shader、纹理、帧率改动 | GPU/内存/设备矩阵证据 |
| `code-review` | PR 或合并前 | 风险、回归、测试缺口、结论 |
| `incident-memory` | 失败、回滚、性能回归 | 根因、修复、避免再次发生的规则 |

Skill 只描述“如何做一类工作”，不保存容易过期的项目事实；事实应链接到 `.ai/modules` 或 ADR。大技能应采用渐进披露：`SKILL.md` 只放触发条件、流程和入口，详细脚本/参考资料放到 `scripts/` 和 `references/`。

### 6.3 MCP：受控工具和外部上下文

建议按“最少可用集合”启用，不要把所有 MCP 都挂上：

| 优先级 | MCP/工具 | 用途 | 权限 |
|---|---|---|---|
| P0 | Git/GitHub 或 Gerrit | Issue、PR、变更、评论、状态 | 读；写 PR 需批准 |
| P0 | XcodeBuildMCP 或等价 Xcode 工具 | build、test、simulator、日志、截图 | 本地受限写 |
| P0 | Context7/官方文档检索 | 查询 SDK 和第三方库文档 | 只读 |
| P1 | Browser/Playwright | Web 控制台、文档、端到端检查 | 默认只读 |
| P1 | Issue/项目管理（Linear/Jira） | 任务状态同步 | 读；状态写需批准 |
| P2 | 内部知识库/监控 | 线上反馈和历史故障 | 只读起步 |

Shell、`rg`、Git、Xcode 命令等本地能力优先通过受限命令和脚本提供，不要为了“看起来像 Agent 平台”重复包装成 MCP。MCP 服务应在 `instructions` 中声明跨工具约束、速率限制和写操作边界。

### 6.4 Memory：四层记忆，不混淆事实与召回

```text
L1 当前任务记忆：Spec / Task / 工具输出 / 验收结果
L2 仓库事实记忆：AGENTS.md / .ai/modules / ADR / CI
L3 经验记忆：.ai/memory/known-issues、pitfalls、patterns
L4 个人召回记忆：Codex 本地 memories/（不可作为团队规范）
```

写入规则：

- 结论、约束、接口变化 → ADR 或模块文档。
- 可复用故障和排障步骤 → `pitfalls.md` 或 `incident-memory` 产物。
- 一次性任务状态 → Task/PR，不写入长期记忆。
- 个人偏好、近期工作上下文 → 本地 Codex memory。
- 每条经验必须有日期、来源、适用范围和验证状态；未经验证的推测标注 `hypothesis`。

## 7. AGENTS.md 建议内容

根文件只保留以下骨架：

```md
# ChuanqiCut Agent Guide

## Mission
- Maintain the native iOS/macOS video editor without breaking media-pipeline contracts.

## Before editing
- Read the relevant `.ai/modules/*`, active task, and linked ADRs.
- State the files you will change and the verification commands.

## Boundaries
- Do not change public APIs, timeline serialization, render timing, or FFmpeg/VideoToolbox ownership without an ADR.
- One task owns one declared write set. Do not edit another task's files.
- Never commit secrets, generated media, signing credentials, or user data.

## Validation
- Run the narrowest relevant test first, then the project gate.
- Report commands, pass/fail, skipped checks, and remaining risks.

## Delegation
- Delegate read-heavy exploration, test analysis, log triage, and independent review lanes.
- Do not parallelize edits to the same files or strongly ordered architecture changes.

## Handoff
- End with summary, changed files, evidence, risks, and follow-up task IDs.
```

## 8. 需求拆分方法

### 8.1 先分类，再拆 DAG

每个需求先回答：

1. 用户价值和成功行为是什么？
2. 哪些模块受影响？
3. 哪些约束不可违反？
4. 如何观察成功或失败？
5. 哪些工作可并行，哪些必须等待前置产物？

然后拆成五类节点：

```text
R（Research）→ A（Architecture）→ I（Implementation）
                         ↘ T（Test/Eval）
I + T → V（Review/Integration）
```

一个合格任务节点包含：`id / owner / input / output / read_set / write_set / dependencies / acceptance / verification / risk`。

### 8.2 例：视频导出优化

```text
EXPORT-001 现状与瓶颈调查（只读）
EXPORT-002 导出接口与取消语义设计（依赖 001）
EXPORT-003 性能基线与测试样本（可与 002 并行）
EXPORT-004 实现导出状态机（依赖 002，唯一写入 Engine/Export）
EXPORT-005 UI 状态映射（依赖 002，唯一写入 UI/Export）
EXPORT-006 集成与端到端验证（依赖 004、005、003）
EXPORT-007 Reviewer/安全/回归审查（依赖 006）
```

`EXPORT-001` 和 `EXPORT-003` 可以并行；`EXPORT-004` 与 `EXPORT-005` 只有在接口契约确定后才并行；`EXPORT-006` 必须串行汇合。

## 9. 子 Agent 分配

### 9.1 推荐拓扑

```text
Lead/Planner
  ├─ Explorer：代码、调用链、历史决策（只读）
  ├─ Architect：接口、数据流、风险（文档）
  ├─ Test Designer：测试矩阵、基线、样本（只读/测试）
  ├─ Coder：一个明确写集（单写者）
  ├─ Reviewer：独立审查（只读）
  └─ Debugger：只处理已记录失败（限定写集）
```

### 9.2 何时并行

适合并行：仓库探索、API/文档调查、测试设计、日志分析、独立安全审查、互不重叠的模块实现。

不适合并行：架构决策、共享接口设计、同一文件改写、同一 Xcode 工程文件变更、需要共同模拟器/设备状态的 E2E 测试。

子 Agent 每个只返回摘要、证据路径、结论和待决策项，不把完整日志倒灌到主线程。并行 Agent 会增加 token 消耗；只有能减少墙钟时间或提高独立验证质量时才使用。

### 9.3 模型分层

- Lead/Architect/Debugger：高推理配置，处理跨模块因果和取舍。
- Explorer/Tester/Reviewer：中等推理配置，可并行。
- 简单检索、格式化、状态汇总：快速/低成本配置。

模型名称和推理档位应放在 Agent 配置层，不写死到仓库业务规则；以当前工作区可用模型为准。

## 10. 多人开发与本地并行

### 10.1 团队协作模型

```text
main/develop
   ↓
Spec/ADR（人审）
   ↓
Task DAG（锁定写集）
   ├─ person-a/agent-export
   ├─ person-b/agent-timeline
   └─ person-c/agent-render
   ↓
Integrator branch
   ↓
CI + Review + Merge
```

规则：

- 分支以 `codex/<task-id>-<slug>` 或 `<person>/<task-id>` 命名。
- 一个任务一个分支、一个 PR、一个主负责人；Agent 是执行者，不是代码所有者。
- 共享接口先单独落一个契约 PR，再让下游任务基于该提交开发。
- `.pbxproj`、公共模型、序列化格式和根级配置设为高冲突文件，默认串行修改。
- 合并前 Integrator 负责 rebase、冲突解决、全量门禁和变更说明。

### 10.2 本地多个任务

```bash
git fetch origin
git worktree add ../cq-export -b codex/export-023 origin/main
git worktree add ../cq-timeline -b codex/timeline-014 origin/main
git worktree add ../cq-render -b codex/render-031 origin/main
```

每个 worktree 必须拥有独立的：

- `DerivedData` 路径（避免 Xcode 并发写入）。
- 临时输出目录和日志目录。
- Simulator/设备标识（E2E 任务尽量串行）。
- 端口、缓存和生成文件路径（如有工具服务）。

Codex Desktop 可以直接以 Worktree 启动并行聊天；CLI/IDE 则用 Git worktree 或独立 checkout。Worktree 只解决文件隔离，不自动解决 API 冲突、Xcode 工程冲突或测试资源竞争。

### 10.3 适合的三人分工

| 人 | 长期责任 | 可管理 Agent |
|---|---|---|
| Lead | Spec、ADR、集成、风险批准 | Planner / Architect / Integrator |
| Media | 解码、渲染、导出、音频性能 | Coder / Debugger / Perf Reviewer |
| Product | SwiftUI、交互、状态与验收 | Coder / UI Tester / Reviewer |

责任是按模块和决策域分，不是按“谁有更多 Agent”分。每个人可以同时运行多个只读 Agent，但写 Agent 受写集限制。

## 11. Evaluation 门禁

任务完成必须附证据：

```text
Compile → Unit → Integration → Regression → Performance/Memory → Review
```

ChuanqiCut 第一版建议：

- 所有 Swift/ObjC/Metal 变更：编译 + 相关单测。
- Timeline/序列化：兼容性、往返序列化和 Undo/Redo 测试。
- 媒体管线：取消、seek、VFR、音画同步、错误码和内存峰值。
- Metal：至少一台基线设备的帧时间、纹理分配和 GPU 报告。
- Export：1080p/4K、短片/长片、失败恢复和临时文件清理。
- 发布/权限/签名：人工审批，不自动放行。

## 12. 分阶段落地

### Phase 0：本周

1. 建根 `AGENTS.md` 和 `.ai/modules`。
2. 选一个低冲突试点（建议设置页或导出状态 UI，不建议一开始改核心渲染）。
3. 固化 `build/test/lint` 脚本和 PR 模板。
4. 只启用 Git、Xcode 构建测试、文档检索三个 P0 工具。

### Phase 1：形成闭环

1. 用 `spec-authoring` → `task-planning` 生成一个真实任务。
2. 用一个 Coder + 一个 Reviewer + 一个 Tester 完成一条 PR。
3. 将失败原因写回 `.ai/memory/pitfalls.md`。

### Phase 2：本地并行

1. 为两个不重叠任务创建 worktree。
2. 并行做读任务和实现任务；共享接口先冻结。
3. 增加 Integrator 和合并门禁。

### Phase 3：团队化

1. 将 `.ai/`、Skills、AGENTS 和 CI 纳入版本控制。
2. 给每个模块设 owner、写集和验收矩阵。
3. 接入 PR/Issue/CI MCP，并记录 Agent 运行摘要。

### Phase 4：自动化扩展

只有在失败样本和门禁稳定后，才增加 Debugger Repair Loop、主动缺陷发现、动态测试和云端后台任务。

## 13. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 上下文过长、主线程失真 | 子 Agent 下沉噪声；按模块/任务检索 |
| 多 Agent 改同一文件 | Task 写集；单写者；Integrator 汇合 |
| 记忆污染或过期 | 团队事实必须入库并 Review；经验带来源和状态 |
| MCP 权限过大 | P0 只读起步；写操作逐项批准；规则和 CI 双门禁 |
| Xcode 并行测试互相影响 | 独立 DerivedData、模拟器和输出；共享 E2E 串行 |
| Agent 生成大量低价值代码 | 小任务、验收先行、测试门禁、PR 小步提交 |
| 模型/工具变更导致流程漂移 | 用脚本和 CI 固化行为；定期回归 Skill |

## 14. 验收标准

该工作流达到第一版可用的条件：

- 新需求可生成包含约束、写集、验收和验证命令的 Task。
- 两个不重叠任务可在本地 worktree 同时运行且不污染主 checkout。
- Agent 能读取模块上下文而无需扫描整个仓库。
- 每个 PR 可追踪到 Spec/Task，并包含机器验证证据和人工 Review。
- 团队规则不依赖某一个人的聊天记忆。
- 至少一次失败能通过记录的日志和 Debugger 任务复现、修复并回归。

## 15. 开放问题

- 代码托管最终使用 GitHub 还是 Gerrit？
- XcodeBuildMCP 是否可在团队所有机器上稳定安装和授权？
- 第一条试点任务选择设置页、导出状态、Timeline 还是渲染？
- CI 是否有可用的 macOS runner、设备矩阵和性能基线？
- 团队是否需要自建远程共享知识库，还是先以 Git 版本库为唯一事实源？

## 16. 独立实施任务切片

以下切片按依赖顺序执行；每个切片声明独立写入范围，避免并行 Agent 争抢文件。

| ID | 负责人 | 依赖 | 写入范围 | 交付与验收 |
|---|---|---|---|---|
| AI-001 | Lead | 无 | `AGENTS.md`、`.ai/modules/` | 根规则、模块地图、验证入口通过 Review |
| AI-002 | Process | AI-001 | `.ai/templates/`、`docs/specs/` | Spec/Task/ADR/PR 模板可生成完整任务 |
| AI-003 | iOS | AI-001 | `scripts/ai/`、CI 配置 | build/test/lint/perf 命令可重复执行 |
| AI-004 | Tooling | AI-001 | `.codex/config.toml`、`.codex/rules/` | P0 MCP 可连接；写操作仍需批准 |
| AI-005 | Skills | AI-002、AI-003 | `.agents/skills/` | 7 个技能有触发条件、流程、输出和验证 |
| AI-006 | Pilot | AI-001～AI-005 | 由试点 Task 单独声明 | 完成一条真实 PR，包含证据和记忆回写 |
| AI-007 | Parallel | AI-006 | `.ai/tasks/`、worktree 脚本 | 两个不重叠任务可并行，Integrator 可汇合 |

AI-001～AI-005 不应由多个 Agent 同时修改同一文件；AI-006 之后才允许按任务写集并行。每个实施任务另建 `TASK-*.md`，不得直接把本规格当作代码修改授权。

## 17. 参考官方文档

- [AGENTS.md 分层配置](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [Skills](https://learn.chatgpt.com/docs/build-skills)
- [MCP](https://learn.chatgpt.com/docs/extend/mcp)
- [Git Worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees)
- [Memories](https://learn.chatgpt.com/docs/customization/memories)
- [Rules](https://learn.chatgpt.com/docs/agent-configuration/rules)
