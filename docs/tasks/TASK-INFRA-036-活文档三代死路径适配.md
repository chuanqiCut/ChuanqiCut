# TASK-INFRA-036：活文档三代死路径适配与判据扩射程

> 收口 `docs/tasks/TODO-POOL-门禁真机待办池.md` 池 [22]。**基建**线（集成机）。

```yaml
id:          TASK-INFRA-036
layer:       基建
goal:        把 ADR-0033 / INFRA-022 / INFRA-026~033 三代布局留下的死路径引用从"活文档"里清干净，
             并把这三代前缀纳入 check_repo_hygiene.sh 的旧路径判据 —— 让"没人判"变成"判得住"
input:       [池 [22], ADR-0033（头与实现共置）, ADR-0044（布局搬家）, pitfalls P156/P163]
output:      [.ai/modules/*.md 路径修正, docs/specs + docs/{BUILD,COCOAPODS,CODESTYLE}.md 修正,
              源码注释修正, tools/ci/check_repo_hygiene.sh PAT 扩三条前缀]
write_set:   .ai/modules/*.md · docs/specs/*.md · docs/{BUILD,COCOAPODS,CODESTYLE}.md ·
             api/swift/Sources/**（仅注释）· engine/{core/cq,platform/apple}/**（仅注释）·
             tests/unit/**（仅注释与 static_assert 文本）· ui/ChuanqiCut*/**（仅注释）·
             tools/ci/check_repo_hygiene.sh
read_set:    磁盘路径存在性（test -e）· git ls-files
deps:        [TASK-INFRA-034]
acceptance:
  - 判据 PAT 含 `core/include/cq|core/src/|engine/core/include` 三条死根，hygiene 步 5/5 PASS
  - 非豁免命中 = 0 行（含迁移标记的历史行按 MARKER 豁免，不计数）
  - 每条改写都能落到磁盘上真实存在的路径（逐条 `test -e`，不是字符串替换）
  - 追加判据 5 scratch-dirs：反证跑法（apps/build/ + 一个非忽略文件）必须把它判红
verification:
  - tools/ci/check_repo_hygiene.sh
  - mkdir -p apps/build/junk && echo hi > apps/build/junk/x.txt; tools/ci/check_repo_hygiene.sh; rm -rf apps/build
  - tools/build/build_core.sh --platform=apple --config=Debug --test   # 注释改动也过 -Werror
risk:        批量替换会把"原 xxx"历史说明反向改写（P156）→ 本卡禁止 sed，逐条人核；
             判据扩射程后若某代路径仍在 append-only 域出现，属预期豁免，不得为此加白名单
parallel:    false   # 高冲突：tools/ci/*、.ai/modules/*.md 全局册单写者
```

## 背景

池 [22] 量的原始事实：`core/include/cq` 在 90 个 tracked 文件里出现，而这一层目录**早在 ADR-0033
就不存在了**。INFRA-034 建的卫生门禁当时只覆盖**本批搬过的**前缀，所以它绿不是因为干净，
是因为**没人判**。本卡做两件事：把债清掉，再把判据射程补上——顺序不能反，先补判据只会逼出 `|| true`。

## 实现要点

1. **三代死根**：`core/include/cq/**`（CORE 骨架期）、`core/src/**`（同代实现根）、
   `engine/core/include/**`（中间态，共置前）。真源一律 `engine/core/cq/<module>/`。
2. **文件名也漂过**：`base/time.h`→`chq_rational_time.h`、`base/chq_log.h`→`chq_logging.h`、
   `net.h`→`chq_net.h`、`capabilities.cpp`→`chq_capabilities.cpp`。只改路径不改文件名同样是死引用。
3. **三种处置**，逐条判断不是一刀切：
   - 描述当前状态 → 改成磁盘真路径；
   - 历史叙述（"当时怎么写集"）→ **保留原文 + 加旧路径标注**，让 MARKER 豁免接住；
   - 设计期文件名（`docs/specs/UIA-01x/032` 里"将要新建"的文件）→ **不动**：它是意图不是磁盘承诺，
     改成别的路径等于伪造当时的 Spec。这一类共 17 处，明确登记为**已接受的判据外噪声**。
4. **不进门禁的东西**：裸文件名（`media_demux.mm`）、`Camera/…`、`Editor/…` 这类当时的逻辑分组前缀，
   人读得懂就不强行展平；改成仓库根相对路径时优先带 `（现 …）` 双写。

## 验收（实测）

| 判据 | 结果 |
|---|---|
| `tools/ci/check_repo_hygiene.sh` | **5/5 PASS**（legacy-paths 豁免行数 33 → **64**，即新纳入的 31 行历史标注） |
| 三代死根非豁免命中 | 改写前 1 行（`tests/unit/gfx/gfx_headers_compile.cpp:44` 的 static_assert 文本）→ **0 行** |
| 判据 5 反证 | `apps/build/` 内放**未被忽略**的文件 → `FAIL [scratch-dirs] 源码树里有未忽略的产物目录 1 个`；空目录/全被忽略内容**不报**（已登记为已知盲区） |
| 改动规模 | 50 文件 / +217 −158 行 |

## 回写

- `.ai/modules/core.md` 模块册行、`.ai/memory/pitfalls.md` P164、`.ai/memory/baselines.md` 提交后基线、
  `docs/tasks/TODO-POOL-…md` 池 [22] 关闭回填。
