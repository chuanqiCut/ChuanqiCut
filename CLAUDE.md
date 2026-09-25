<!-- GENERATED from .ai/source/AGENTS.root.md — DO NOT EDIT -->
# ChuanqiCut — Claude Code

**本文件是入口，不是规则本身。** 完整规则在 [`.ai/source/AGENTS.root.md`](.ai/source/AGENTS.root.md)，请先读取。

快速摘要：

- C++20 内核 `core/` + 平台适配 `pal/` + 原生 UI `apps/`；**iOS/macOS 重点支持** → Android(P1) → HarmonyOS(P2 预留)。
- 性能基线：高端满足、中端可用、**明确不适配低端机**。
- Shader 双层：Portable（`shaders/src/`）+ Platform-Native（`pal/<platform>/shaders/`，可选加速）。
- 全部项目规则、架构红线、验证要求见 `.ai/source/AGENTS.root.md`。
- 模块上下文见 `.ai/modules/*.md`；任务见 `docs/tasks/`；决策见 `docs/decisions/`。
- 改动前必须声明 write_set 与验证命令。
- 完成判定 = 门禁通过（编译 + 单测 + golden），不是自述完成。

不要再读 `AGENTS.md` 的副本，两份内容同源。
