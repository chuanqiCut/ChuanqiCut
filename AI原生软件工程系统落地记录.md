# AI 原生软件工程系统落地记录

> 项目：ChuanqiCut（原生 iOS + Mac 视频编辑器）  
> 记录类型：架构与研发流程决策  
> 状态：方向确认，待按阶段实施  
> 日期：2026-08-12

## 1. 结论

本项目不把 AI 定位成“代码补全工具”，而把它定位成一套 **AI 原生软件工程系统（AI Software Engineering Operating System）**：

> 人负责目标、约束、取舍和验收；Agent 负责检索、规划、实现、测试、调试和交付；Harness 负责上下文、权限、编排、评估和反馈闭环。

核心对象从“Prompt + Code”转为：

```text
Intent → Specification → Context → Task DAG → Agent Execution
      → Build/Test/Eval → Review/Approval → Merge/Deploy
      → Telemetry/Memory → 下一轮任务
```

这是一条针对 ChuanqiCut 这类多语言、跨平台、媒体管线复杂项目的长期研发路线，不要求一次性建设完整平台。

## 2. 适用范围与边界

### 适用范围

- SwiftUI、Metal、VideoToolbox、AVFoundation、FFmpeg、CoreML/MediaPipe 等组成的 iOS/Mac 工程。
- Timeline、渲染、音频、导出、AI 效果等具有明确边界的模块开发。
- 需要多人和多个 Agent 并行推进、最终汇合到 Git/Gerrit/CI 的任务。

### 暂不承诺

- 不追求“完全无人值守”的 Level 5 自动研发。
- 不因 Multi-Agent 流行而强行拆分强顺序依赖的任务。
- 不把外部公司公开案例直接当作本项目的事实或可复制结果；案例只作为设计参考，具体能力需要在本项目中验证。

## 3. 参考模型：八层系统

```text
┌────────────────────────────────────────────┐
│ Human：目标、决策、批准、风险承担            │
├────────────────────────────────────────────┤
│ Specification：PRD / Tech Spec / ADR / 验收  │
├────────────────────────────────────────────┤
│ Context：代码库、架构、模块知识、历史记忆     │
├────────────────────────────────────────────┤
│ Orchestration：Planner / Router / Task DAG   │
├────────────────────────────────────────────┤
│ Agents：Researcher / Architect / Coder / ... │
├────────────────────────────────────────────┤
│ Tools：Git / Shell / Build / Test / MCP / CI  │
├────────────────────────────────────────────┤
│ Evaluation：测试、静态检查、性能、行为评估     │
├────────────────────────────────────────────┤
│ Feedback：日志、失败样本、指标、知识回写       │
└────────────────────────────────────────────┘
```

其中：

- **MCP 是工具连接协议**，不等于完整 Harness。
- **Harness 是运行系统**，负责任务、上下文、工具权限、执行环境、评估、重试和人工审批。
- **Context Engineering 是关键能力**：Agent 需要的是与当前任务相关的全局上下文、模块上下文和历史上下文，而不是整个仓库的无差别内容。

## 4. 研发主流程

### 4.1 从需求到交付

```text
Human Requirement
        ↓
Specification + Constraints + Acceptance Criteria
        ↓
Context Retrieval / Context Pre-computation
        ↓
Task DAG（定义依赖、输入、输出、验收）
        ↓
Research / Architecture / Coding / Test（可并行部分并行）
        ↓
Build + Unit + Integration + Performance + Security Eval
        ↓
Repair Loop（失败时定位根因并重新验证）
        ↓
Review + Human Approval
        ↓
PR → CI → Merge → Deploy
        ↓
Telemetry + Lessons Learned + Knowledge Base 更新
```

### 4.2 任务规范

每个任务必须至少包含：

```yaml
task:
  id: EXPORT-023
  goal: 支持当前 Timeline 的 4K 视频导出
  input:
    - export specification
    - timeline architecture
    - existing export pipeline
  output:
    - code changes
    - tests
    - documentation/decision updates
  constraints:
    - no API breaking change
    - no main-thread blocking
    - cancellation must be recoverable
  acceptance:
    - 1080p and 4K export pass
    - cancellation updates UI correctly
    - failure returns a stable error code
    - memory/performance thresholds are met
  verification:
    - unit
    - integration
    - performance
```

没有验收标准的任务只能停留在研究或讨论阶段，不能直接进入自动实现。

## 5. Agent 角色与编排原则

建议使用职责清晰的 Agent，而不是一个“什么都做”的超级 Agent：

| 角色 | 主要职责 | 输出 |
|---|---|---|
| Planner | 理解需求、拆分任务、建立依赖 | Spec、Task DAG |
| Researcher | 查找现有实现、约束和历史决策 | 事实与引用、风险 |
| Architect | 设计边界、接口和迁移方案 | Tech Spec、ADR |
| Coder | 在明确边界内修改代码和测试 | Commit/工作区变更 |
| Tester | 生成/执行测试、回归和性能验证 | 测试结果、失败样本 |
| Reviewer | 检查正确性、架构、边界和安全 | Review 结论 |
| Debugger | 根据失败日志定位根因并修复 | 修复提交、复验结果 |
| Integrator | 汇总并行分支，解决冲突，运行集成验证 | 集成分支/PR |

编排采用 **Task DAG**：

- API 分析、UI 分析、测试设计、安全分析等可独立任务可以并行。
- 架构 → 接口 → 核心实现 → 集成这类强顺序依赖必须串行。
- 每个 Agent 使用隔离上下文和独立工作区；共享内容通过 Spec、Artifacts、测试结果和决策记录传递。

## 6. 项目知识库设计

建议逐步建立以下目录，不要求一次性填满：

```text
.ai/
├── architecture/
│   ├── overview.md
│   ├── module-map.md
│   ├── dependency.md
│   └── data-flow.md
├── rules/
│   ├── coding.md
│   ├── ios.md
│   ├── architecture.md
│   └── testing.md
├── modules/
│   ├── timeline.md
│   ├── renderer-metal.md
│   ├── media-pipeline.md
│   ├── audio.md
│   └── export.md
├── decisions/
│   └── ADR-*.md
├── tasks/
│   └── TASK-*.md
└── memory/
    ├── known-issues.md
    ├── pitfalls.md
    └── patterns.md
```

仓库根部的 `AGENTS.md` 负责全局规则；模块目录可以有更细的 `AGENTS.md` 或 Skill。知识库的目标是让 Agent 快速得到“为什么这样设计、改动会影响什么、应该如何验证”，而不是复制所有源码。

## 7. Harness 的最小职责

第一版 Harness 不需要自研复杂平台，至少应能统一管理：

1. 任务状态、依赖和工作区。
2. 上下文检索范围与最大输入边界。
3. Agent 可使用的工具和写权限。
4. 构建、单测、集成测试、静态检查和性能检查命令。
5. 失败日志、重试次数、修复链路和人工批准点。
6. 每次任务的输入、输出、验证结果和变更摘要。

建议按风险设置自动化等级：

| 等级 | 行为 | 适用范围 |
|---|---|---|
| L0 | AI 建议，人工执行 | 架构决策、生产操作 |
| L1 | AI 改码，人工 Review | 核心渲染、媒体管线 |
| L2 | AI 测试后提 PR，人工 Merge | 常规模块开发 |
| L3 | CI 通过后自动合并 | 低风险、覆盖充分的模块 |
| L4 | 自动部署到 Canary，人工批准 | 受控测试环境 |

默认从 L1/L2 开始；涉及数据删除、发布、权限、核心媒体管线的操作必须保留人工批准。

## 8. Evaluation 与反馈闭环

Agent 任务的“完成”不由模型自述决定，而由可重复的评估决定：

```text
Build
  → Unit Test
  → Integration Test
  → Static Analysis
  → Regression
  → Performance / Memory
  → Security / Permission
  → Human Review
```

对于高频变更模块，可以进一步探索按变更动态生成测试（Just-in-Time Tests），但必须先建立稳定的基线测试和失败样本库。

每次任务结束后至少回写：

- 新增的架构事实或约束。
- 失败原因和可复用的排障步骤。
- 哪些上下文有效、哪些上下文造成噪声。
- 测试覆盖缺口和后续任务。

## 9. 分阶段落地路线

### Phase 0：规范化（现在即可做）

- 建立根级 `AGENTS.md`。
- 统一 Spec、Task、ADR、PR 模板。
- 先维护 `module-map`、关键数据流和已知坑。
- 把现有技术方案决策书作为架构事实来源之一。

### Phase 1：单 Agent 可验证闭环

- 为一个低风险模块建立“任务 → 修改 → 测试 → Review → PR”模板。
- 固化构建、测试、静态检查命令。
- 记录执行日志和验收结果。

### Phase 2：受控并行

- 用独立 worktree 承载并行任务。
- 引入 Planner、Coder、Reviewer、Tester 四类职责。
- 通过 Task DAG 和共享 Artifacts 汇合，不用群聊传递隐式上下文。

### Phase 3：Harness 与自动修复

- 统一权限、工具、上下文检索和失败重试。
- 建立 Debugger/Repair Loop。
- 对导出、渲染、音频等关键链路加入性能与内存评估。

### Phase 4：组织级知识与主动发现

- 将高频人工排障经验沉淀成 Skills。
- 接入 Git、CI、Issue/缺陷系统和监控反馈。
- 在有足够评估数据后，再探索主动发现 Bug、回归和待办任务。

## 10. 当前决策与待确认问题

### 已确认

- 以 Specification、Context、Task DAG、Evaluation、Human Governance 为系统主轴。
- 采用职责分离的 Agent；是否并行由任务依赖决定。
- 先建设文档、规则和可验证闭环，再建设复杂 Harness。
- 核心媒体管线默认保守自动化，保留人工审批。

### 待确认

- 团队实际使用 Codex、Claude Code、Gemini CLI 还是混合方案。
- GitHub、Gerrit 或其他代码托管与 CI 的具体接入方式。
- `.ai/` 目录是否纳入主仓库，以及知识更新的 Review 责任人。
- ChuanqiCut 第一条试点闭环选择导出、Timeline、渲染还是设置页。
- 性能阈值、设备矩阵和可自动化的发布范围。

## 11. 参考资料（来自原始讨论，需单独核验）

以下链接用于记录讨论来源，不代表本项目已验证这些公开案例中的具体数字或结论：

- [OpenAI — Harness engineering](https://openai.com/index/harness-engineering/)
- [OpenAI — How OpenAI uses Codex](https://openai.com/business/guides-and-resources/how-openai-uses-codex/)
- [OpenAI — Running Codex safely](https://openai.com/index/running-codex-safely/)
- [Meta — Context pre-computation for large-scale data pipelines](https://engineering.fb.com/2026/04/06/developer-tools/how-meta-used-ai-to-map-tribal-knowledge-in-large-scale-data-pipelines/)
- [Google Research — Scaling agent systems](https://research.google/blog/towards-a-science-of-scaling-agent-systems-when-and-why-agent-systems-work/)
- [Google Research — Agentic coding needs proactivity](https://research.google/pubs/agentic-coding-needs-proactivity-not-just-autonomy/)
- [百度 Comate — Subagents](https://comate.baidu.com/docs/IDE%E5%8A%9F%E8%83%BD/%E6%99%BA%E8%83%BD%E4%BD%93/Subagents/)
- [TRAE — IDE / Agent](https://www.trae.ai/ide/)

## 12. 后续追问入口

后续可以直接围绕本记录继续细化：


- 先为 ChuanqiCut 选择一条可落地的试点任务，并写出完整 Spec/Task/验收标准。
- 生成 `.ai/`、`AGENTS.md`、Skills、MCP 和 Git 分支策略的实际模板。
- 设计三人团队与多个 Agent 的角色、权限、工作区和合并流程。
- 评估 Codex/Claude Code/Gemini CLI 的组合方式及其边界。
- 把 Harness 拆成可实现的最小工具链与迭代计划。

本次进一步落地规格见：[AI-ENG-001：ChuanqiCut AI 原生软件工程工作流](docs/specs/AI-ENG-001.md)。
