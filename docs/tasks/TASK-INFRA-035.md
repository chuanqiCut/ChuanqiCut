# TASK-INFRA-035：docs/handoff 归档（在位只留最近 5 份）

```yaml
id:          TASK-INFRA-035
layer:       基建
goal:        把过期交接文档移入 docs/archive/handoff/，让"接手该看哪份"不再靠猜
input:       [ADR-0019 六层结构与 legacy 只读规则, 传哲 2026-10-16 决策 12（重号补注不删）]
output:      [docs/archive/handoff/**（22 份）, docs/handoff/**（留 HANDOFF-020~024）, docs/archive/README.md（归档说明）]
write_set:   docs/handoff/** → docs/archive/handoff/**, docs/archive/README.md（新建）
read_set:    docs/README.md, ADR-0019
deps:        [TASK-INFRA-026]
acceptance:
  - `ls docs/handoff/*.md | wc -l` = 5，且为编号最新的 020/021/022/023/024
  - `git ls-files docs/archive/handoff | wc -l` = 22（27 - 5），总数不变：
    `git ls-files docs/handoff docs/archive/handoff | wc -l` = 27
  - **重号文档一份都没丢**：HANDOFF-004 两份、HANDOFF-006 三份全部随迁，
    文件名保持原样（补注靠 slug 区分，不改编号、不合并、不删）
  - `docs/archive/README.md` 写明：归档区只读、不得引用为当前状态、如何按编号找回
  - `docs/README.md` 的"接手第一步"命令指向在位最新那份。**执行时改判**：不等 INFRA-034 ——
    归档直接把 §六 交接表的 8 条链接打断，在批边界留一张坏地图比"越界改一个共享文件"更糟，
    故本卡只改 `docs/README.md` 的交接索引三处（§六表、:12 上手命令、§九"做到哪了"），
    034 的写集里已把该段划出（见卡 034 范围说明）
  - `python3 tools/ai/linkcheck_docs.py` 断链数**不得高于迁移前基线 9 处**（2026-10-16 实测：
    本卡结束时为 **6**，全部为历史遗留；轨迹 9 → 16（`docs/README` 索引指错）→ 8 → 6，见下「实测」）
    迁移的真实工作量：`docs/handoff/` 里有 **17 处 `](../` 相对链接分布在 7 份文件**，
    下潜一层后每条都要补一个 `../`，否则归档区内部链接全断
verification:
  - ls docs/handoff/*.md | wc -l && git ls-files docs/handoff docs/archive/handoff | wc -l
  - python3 tools/ai/linkcheck_docs.py 2>&1 | tail -20
risk:        HANDOFF 是 append-only 历史记录（ADR-0044 红线 5）：本卡**只移动位置，不改一字内容**；
             任何"顺手更新过期状态"都破坏历史记录的可信性 —— 状态纠偏应写进新的 HANDOFF 或模块册。
             相对路径链接（`../decisions/ADR-*.md`）在深一层目录里会全部失效，必须靠 linkcheck 取证。
parallel:    true（写集只含 docs/handoff 与 docs/archive，与 029/031 不相交）
```

## 背景

`docs/handoff/` 已积累 27 份交接文档（含两组重号：004 两份、006 三份），最新为 HANDOFF-024。
AGENTS.md「任务结束必须同步上下文」第 4 项要求交接文档"新会话照它能接手"，
但 27 份平铺时，接手者要先做考古才知道哪份有效 —— 正是本轮"可读性太差"命题的一部分（传哲决策 12）。

## 实现要点

- 归档线：按编号取最新 5 份在位，其余进 `docs/archive/handoff/`。
- 重号不合并、不改号（编号纪律归 ADR-0019；集成机是唯一发号器）。
- `git mv` 保留历史；归档区加 `docs/archive/README.md` 说明只读语义。
- ⚠️ `linkcheck_docs.py` **有断链也退 0**（实测打印"❌ 9 处断链"但 `exit=0`）——
  判据只能取它输出的**断链条数**，不能用退出码。
- 归档后每份文件里的 `](../` 链接补一层 `../`（17 处 / 7 份），内容其余一字不改（红线：只搬位置不改内容）。

## 验收

见 yaml；报告三个计数（在位 5 / 归档 22 / 合计 27）与 linkcheck 结论。

**实测（2026-10-16，本卡执行完毕）**：

- `ls docs/handoff/*.md | wc -l` = **5**（020/021/022/023/024，编号连续无缺）；
  `git ls-files docs/archive/handoff | wc -l` = **22**；合计 **27** ✅
- 重号全部随迁且未合并：HANDOFF-004 **2** 份（相机模块 / 编码阶段）、HANDOFF-006 **3** 份
  （MEDIA播放链路 / 播放器MVP / 音频线），靠 slug 区分，编号与文件名一字未改 ✅
- `git mv` 全部保留历史：`git status` 里 22 条为 `R`（重命名）而非"删+增" ✅
- 相对链接：7 份文件共 **17** 条 `](../` → `](../../`，其余内容零改动 ✅
- `python3 tools/ai/linkcheck_docs.py` 断链：迁移前基线 **9** → 归档后一度升到 **16**（`docs/README.md`
  的交接索引 8 条指向已迁走的那份）→ 重写索引段后 **8** → 修两条 append-only 波及后 **6**，
  即**低于迁移前基线**，本批零新增死链 ✅
  - 归档波及的 2 条按「只改路径、不改一字内容」处置：
    `docs/reviews/REVIEW-2026-10-06-MEDIA027-…:286` 与
    `docs/tasks/TODO-2026-10-07-撞号归一轮收尾待接手.md:9`，两者只把
    `docs/handoff/` 换成 `docs/archive/handoff/`
  - 剩余 6 条全是存量：`docs/specs/PAL-接口契约.md`（已改名 `PLATFORM-…`）3 条、
    `LEDGER-W42` 的 RESEARCH-011 全名 1 条 + ADR-0011 1 条、
    `HANDOFF-021` 指向从未存在的 `TASK-EDIT-007/008.md` 1 条 → 交 INFRA-034 分类处置
- `docs/archive/README.md` 新建：只读语义、不得作为当前状态引用、append-only 旧路径不回填、
  重号说明、在位窗口 = 最新 5 份的规则 ✅

## 回写

- 日志 → `.workbuddy/memory/2026-10-16.md`
- ~~`docs/README.md` 索引行（由 INFRA-034 落）~~ → **本卡已改**：§六交接表整段重写（含"下一份 = 025"）、
  :12 上手命令指向 `HANDOFF-024-*`、§九"项目现在做到哪了"改为先 `git log` + 模块册且明确"别看 archive/"。
  **INFRA-034 不要再动 `docs/README.md` 的交接索引段**，避免覆盖；其余索引行仍归 034。
- `docs/tasks/TASK-BACKLOG.md` §15 状态位已回填具体数字（非"全绿"）
