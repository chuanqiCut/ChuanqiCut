# AI-COLLAB-001：上下文工程与 Skill 体系

> 版本：v1.0（待 Review）
> 日期：2026-09-23
> 目标：**任何人拿到仓库，用任何 AI 工具，都能立即投入研发。**
> 上游：`docs/specs/AI-ENG-001.md`（AI 原生软件工程工作流）

---

## 1. 核心问题

团队会用不同的 AI 工具（Codex / Claude Code / Cursor / Copilot / 其他）。如果每个工具各自维护一份规则文件，它们必然漂移，最终没有一份是真的。

## 2. 解决方案：单一真源 + 生成同步

```
   单一真源（人维护，需 Review）
   ┌──────────────────────────────────────┐
   │ .ai/source/AGENTS.root.md            │  根规则（< 200 行）
   │ .ai/modules/*.md                     │  模块上下文
   │ .ai/rules/*.md                       │  编码/架构/测试规则
   │ .agents/skills/*/SKILL.md            │  项目技能
   └───────────────┬──────────────────────┘
                   │  tools/ai/sync_context.py（CI 校验一致性）
        ┌──────────┼──────────┬─────────────┬──────────────┐
        ▼          ▼          ▼             ▼              ▼
   AGENTS.md   CLAUDE.md  .cursorrules  copilot-      .windsurfrules
   (Codex/     (Claude)   (Cursor)      instructions  (Windsurf)
    通用)                                .md (Copilot)
```

**规则**：
1. 各工具入口文件**一律生成，禁止手改**（文件头有 `<!-- GENERATED -->` 标记）。
2. 入口文件只做两件事：声明项目身份 + 指向 `.ai/` 真源。内容越短越好（< 60 行）。
3. CI 校验：运行 `tools/ai/sync_context.py --check`，入口文件与真源不一致即失败。
4. 工具特有配置（如 `.codex/config.toml`、MCP 列表）**单独维护**，不混入通用规则 —— 因为那是个人环境差异，不是团队规范。

---

## 3. 上下文分层（渐进加载）

| 层 | 位置 | 何时加载 | 体量限制 |
|---|---|---|---|
| **L0 根规则** | `AGENTS.md` | 每次会话自动 | **< 200 行**（硬限制，超过就拆） |
| **L1 模块上下文** | `.ai/modules/<module>.md` | 进入该模块时 | 每份 < 150 行 |
| **L2 任务上下文** | `docs/tasks/TASK-<ID>.md` | 执行该任务时 | 单任务一页 |
| **L3 决策记录** | `docs/decisions/ADR-*.md` | 涉及该决策时 | — |
| **L4 经验记忆** | `.ai/memory/pitfalls.md`、`baselines.md` | 排查/评估时 | 按需检索，不全量加载 |

**为什么根规则必须短**：AI 工具的默认上下文预算有限，根规则每多 100 行，所有任务都在付税。详细内容一律下沉。

---

## 4. 目录结构

```
.ai/
├── source/
│   └── AGENTS.root.md          # 真源根规则
├── modules/                    # 模块上下文（边界、入口、依赖、验证方式）
│   ├── core.md                 # 内核基础：时间/状态/并发/内存
│   ├── model.md                # 时间线模型与命令
│   ├── gfx.md                  # GPU 抽象与后端
│   ├── shader.md               # Shader 工具链
│   ├── render.md               # RenderGraph 与效果
│   ├── media.md                # 媒体管线
│   ├── audio.md                # 音频
│   ├── ai.md                   # 推理与 AI 效果
│   ├── project.md              # 项目文件与序列化
│   ├── export.md               # 导出
│   ├── pal-apple.md            # Apple PAL
│   ├── pal-android.md          # Android PAL
│   ├── ui-apple.md             # SwiftUI
│   ├── ui-android.md           # Compose
│   └── deps.md                 # 依赖治理
├── rules/
│   ├── coding.md               # 编码规范（C++/Swift/Kotlin/GLSL）
│   ├── architecture.md         # 架构红线
│   ├── testing.md              # 测试与验收
│   └── review.md               # 评审清单
├── memory/
│   ├── pitfalls.md             # 已知坑与排障步骤
│   ├── baselines.md            # 实测性能/体积基线（替换估算数字）
│   └── device-matrix.md        # 设备矩阵与降级清单
└── templates/
    ├── spec.md                 # 需求规格模板
    ├── task.md                 # 任务模板
    ├── adr.md                  # 决策记录模板
    └── pr.md                   # PR 描述模板

.agents/skills/
├── cq-spec-authoring/SKILL.md
├── cq-task-planning/SKILL.md
├── cq-media-pipeline/SKILL.md
├── cq-shader-portability/SKILL.md
├── cq-dependency-governance/SKILL.md
├── cq-build-test/SKILL.md
├── cq-perf-baseline/SKILL.md
└── cq-incident-memory/SKILL.md
```

---

## 5. 项目 Skills

| Skill | 触发条件 | 必须产出 |
|---|---|---|
| `cq-spec-authoring` | 新需求、范围不清 | Spec：目标、非目标、约束、验收、开放问题 |
| `cq-task-planning` | Spec 已确认 | Task DAG：依赖、写集、验收、验证命令、并行批次 |
| `cq-media-pipeline` | 涉及解码/渲染/编码/音频/seek | 线程、时序、内存、取消、错误码分析 + 测试点 |
| `cq-shader-portability` | 新增或修改 shader | 三端生成产物 + 一致性测试证据 + 禁用特性检查 |
| `cq-dependency-governance` | 新增/升级第三方依赖 | manifest 条目、协议判定、体积/符号影响、SBOM |
| `cq-build-test` | 任何代码改动 | 精确构建与测试命令 + 日志摘要 + 门禁结果 |
| `cq-perf-baseline` | 性能相关改动或定期 | 实测数据、与基线对比、是否触发门禁 |
| `cq-incident-memory` | 失败、回滚、性能回归 | 根因、修复、可复用排障步骤、防复发规则 |

**Skill 编写原则**：
- SKILL.md 只放触发条件、流程、检查清单与入口；长脚本/参考放 `scripts/` 与 `references/`（渐进披露）。
- Skill 不保存易过期的项目事实，事实一律链接到 `.ai/modules/` 或 ADR。
- 技能是"怎么做一类工作"，不是"这个项目现在是什么样"。

---

## 6. 记忆回写规则（强制性）

任务结束必须回写，否则上下文不会积累：

| 内容类型 | 回写到 |
|---|---|
| 新增架构事实 / 接口变更 / 约束 | `.ai/modules/*.md` 或新增 ADR |
| 可复用故障与排障步骤 | `.ai/memory/pitfalls.md`（含日期、来源、验证状态） |
| 实测性能/体积数据 | `.ai/memory/baselines.md`（替换估算数字） |
| 设备问题与降级决策 | `.ai/memory/device-matrix.md` |
| 一次性任务状态 | Issue/PR，**不写长期记忆** |
| 个人偏好与近期上下文 | 个人本地工具记忆，**不得作为团队规范** |

每条经验必须有：**日期、来源、适用范围、验证状态**。未验证的推测标注 `hypothesis`。

---

## 7. 多人协作规则

1. **分支命名**：`<person>/<task-id>-<slug>` 或 `codex/<task-id>-<slug>`。
2. **一个任务 = 一个分支 = 一个 PR = 一个负责人**。Agent 是执行者，不是代码所有者。
3. **写集隔离**：Task DAG 声明 write_set，写集相交的任务不得并行。
4. **共享接口先落契约 PR**：`CORE-006`(PAL)、`BIND-001`(C ABI)、`GFX-001` 这类接口必须先冻结再让下游开工。
5. **高冲突文件串行**：`CMakeLists.txt`、`cq_sdk.h`、`*.pbxproj`、`build.gradle.kts`、`manifest.toml`。
6. **本地并行用 git worktree**，每个 worktree 独立 DerivedData / 输出目录 / 日志目录，避免 Xcode 并发写冲突。
7. **不用群聊传递隐式上下文**：结论进 Spec / ADR / Issue / PR。

---

## 8. 新人 / 新 Agent 的上手路径（3 步）

```bash
# 1. 读根规则（自动，因为 AGENTS.md 在仓库根）
# 2. 读当前模块上下文
cat .ai/modules/<你负责的模块>.md
# 3. 读你的任务
cat docs/tasks/TASK-<ID>.md
```

之后才允许改代码。改之前必须声明：**要改哪些文件、用什么命令验证**。

---

## 9. 与 AI-ENG-001 的关系

`docs/specs/AI-ENG-001.md` 提出的是工作流模型（Planner / Researcher / Coder / Tester / Reviewer / Integrator 的角色编排、四层记忆、自动化等级）。本文件是其**仓库内的落地实现**：把"四层记忆"落到具体目录，把"7 个技能"落到 `.agents/skills/`。

差异点（本文件的补充）：
- AI-ENG-001 假定以 Codex 为主入口；本文件改为**工具无关**（多人会用不同工具）。
- AI-ENG-001 的 `.agents/skills/` 7 个技能中，`metal-performance` 调整为 `cq-perf-baseline`（覆盖三端而非仅 Metal），并新增 `cq-shader-portability` 与 `cq-dependency-governance`（本项目特有高风险领域）。
