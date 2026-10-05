# TASK-DOC-001：文档体系统一分层与归档（ADR-0019 落地）

```yaml
id:          DOC-001
layer:       基建
goal:        统一 docs/ 六层结构，根目录调研文档归位，README 去状态化，编号纪律升格为 ADR
input:       [docs/research/RESEARCH-001 §1/§5, .workbuddy/memory/MEMORY.md 编号纪律, docs/HANDOFF-004-*]
output:      [目录迁移, docs/README.md 重写, ADR-0019, tasks/README.md 卡登记表, 本卡]
write_set:   docs/**, 仓库根 7 个内容文档, .ai/source/AGENTS.root.md, .ai/modules/project.md
read_set:    .ai/memory/*, .workbuddy/memory/*
deps:        []
acceptance:
  - 仓库根目录无内容文档（只剩 README 类入口与生成物）
  - 全仓 md 中不存在指向已迁移文件的旧路径引用（docs/HANDOFF-00 除外位置、根目录文件名裸链接）
  - docs/README.md 中所有相对链接可达；ADR 表与 decisions/ 目录逐一对应
  - tools/ai/sync_context.py --check 通过
verification:
  - python3 tools/ai/linkcheck_docs.py（本轮一次性脚本，见日志）
  - python3 tools/ai/sync_context.py && python3 tools/ai/sync_context.py --check
  - git status 复核移动全部为 R（rename）无内容丢失
risk:        双机协作期间另一台机器可能正引用旧路径 —— 合并时按 ADR-0019 §4 主题清扫
parallel:    true
```

## 背景

2026-10-05 文档盘点发现三处结构性混乱（详见 [ADR-0019](../decisions/ADR-0019-文档体系分层与归档规则.md) 背景）：
第一代调研堆在仓库根、HANDOFF 位置编号乱、README 状态快照腐烂。本任务只做文档迁移与规则固化，**零代码改动**。

## 实现要点

- 用 `git mv` 迁移（保留 rename 历史）；legacy 7 份文件头加状态横幅而非改内容。
- README 重写为"只放稳定内容"的文档地图：六层结构 + 生命周期 + 各层规则，状态一律外链。
- 两份 HANDOFF-004 保持文件名不动（双线并行、引用密集），在 README 与 ADR 中成文"同号双卡"规则。

## 验收

- 上述 acceptance 逐条可验证；门禁不涉及（无代码改动，build/test 不适用）。

## 回写

- `.ai/modules/project.md` 补"文档体系"段落
- 工作日志 `.workbuddy/memory/2026-10-05.md`
- 编号纪律已在 `.workbuddy/memory/MEMORY.md`，本轮升格入 ADR-0019（MEMORY 原文保留）
