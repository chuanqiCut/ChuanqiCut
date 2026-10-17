# TASK-INFRA-026：仓库布局整改 · 契约冻结

```yaml
id:          TASK-INFRA-026
layer:       基建
goal:        冻结整改后的顶层布局契约（目录名、pod 根、门禁三处同步点），让 027~035 有唯一真源
input:       [RESEARCH-011 §3-§6, RESEARCH-018, 传哲 2026-10-16 拍板 14 项]
output:      [ADR-0044, RESEARCH-018, TASK-INFRA-027~035 任务卡, BACKLOG §15, docs/README 索引, ARCH-005 目录树, TODO-POOL 风险条目]
write_set:   docs/decisions/ADR-0044-*.md, docs/research/RESEARCH-018-*.md, docs/tasks/TASK-INFRA-0{26..35}.md,
             docs/tasks/README.md, docs/README.md, docs/tasks/TASK-BACKLOG.md §15,
             docs/specs/ARCH-005-*.md §工程结构, docs/tasks/TODO-POOL-*.md（append-only）
read_set:    apps/apple/{ios,mac}/Podfile, engine/*.podspec, tools/ci/run_gate.sh,
             tools/platform/check_platform_headers.py, tests/CMakeLists.txt, .gitignore
deps:        []
acceptance:
  - ADR-0044 存在且其目标布局六行与 031/032/033 卡内 write_set 的落点逐字一致
  - 027~035 每张卡十字段（id/layer/goal/input/output/write_set/read_set/deps/acceptance/verification/risk/parallel）齐全
  - 并行批次（029 ∥ 031 ∥ 035）三张卡的 write_set 逐行比对无相交路径；
    证据 = `grep -A1 "^write_set" docs/tasks/TASK-INFRA-0{29,31,35}.md` 输出贴进本卡
  - BACKLOG §15 含 DAG 表 + 并行批次 + 关键路径三块
verification:
  - ls docs/decisions/ADR-0044-*.md docs/research/RESEARCH-018-*.md docs/tasks/TASK-INFRA-0{27..35}.md
  - grep -c "^| INFRA-0" docs/tasks/TASK-BACKLOG.md   # §15 十条行存在
risk:        契约不冻结就搬家 = 每批各自解释布局，第二批起必然返工（RESEARCH-011 的 C 项复发即此因）
parallel:    false
```

## 背景

RESEARCH-011（2026-10-10）已给出 P0–P3 方案，P0/P1/P2 于 10-11 执行（ADR-0035 / HANDOFF-018），
P3 未开工。本轮复勘（RESEARCH-018）发现：**C 项（数据与测试混放）已复发**，F/G/H 三项从未动。
传哲 2026-10-16 把范围从"P3 收尾"扩到"全量一次做完"，并新拍 14 项决策，其中两条改变契约形状：
`packages` → 扁平顶层 `ui/`；`engine/bindings/swift` → 顶层 `api/swift/`（选 b：门面外提，`engine/` 回归纯 C++）。

## 实现要点

- 契约的硬约束不是"好看"，而是**目录名是门禁判定输入**：`check_platform_headers.py:241` 的
  `CONTRACT_DIR_NAMES`、podspec 的 `source_files` glob、`run_gate.sh:158-194` 的五个包路径。
  任何一次搬家必须同批改这三处，否则门禁静默扫到 0 个文件仍报绿。
- 高冲突登记文件（`TASK-BACKLOG.md`、两份 `README.md`、`AGENTS` 真源及其 5 个生成物）
  按 ADR-0030 归**集成机单写者**，各批串行更新，不视为写集相交。

## 验收

见 yaml。执行证据：本卡产出的文件列表 + BACKLOG §15 行数。

## 回写

- 布局事实 → `.ai/modules/ui-apple.md`、`.ai/modules/core.md`（随各执行批完成，不在本卡）
- 本卡自身即 ADR-0044 + RESEARCH-018 的回写载体
