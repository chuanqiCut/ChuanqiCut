# TASK-INFRA-046：全库 clang-format 重排（收存量违规 113 → 0）

> 模板口径见 `.ai/templates/task.md`。背景 = INFRA-034 立 `.clang-format` 时**故意留下的存量**
> （engine 79/115、tests 34/45），当时的理由是「cosmetic diff 会淹没真实改动」。本批没有并行的功能改动，
> 所以把它做掉 —— 这是唯一能做的时间窗。

```yaml
id:          TASK-INFRA-046
layer:       基建
goal:        把全库 C/C++/ObjC++ 的 clang-format 存量违规清到 0，让 hygiene 的计数从"可解释存量"变成"新代码信号"
input:       [.clang-format（INFRA-034 立的基线）, 违规清单 /tmp/cf-bad-all.txt（114 条，含 1 个符号链接）]
output:      [113 个重排后的源文件, .clang-format 头部现状改写, tools/ci/check_repo_hygiene.sh 的 INFO 文案,
              tools/ci/gate_scope.sh 的 R12 规则]
write_set:   engine/**、tests/** 的 .h/.c/.cpp/.mm（仅空白与换行，无逻辑改动）、.clang-format、
             tools/ci/check_repo_hygiene.sh、tools/ci/gate_scope.sh、本卡、TASK-BACKLOG.md、TODO-POOL、.ai/modules/core.md、.ai/memory/*.md
read_set:    [engine/vendor/**（只读，确认不入库）]
deps:        [INFRA-034, INFRA-043]
acceptance:
  - `clang-format --dry-run --Werror` 对**全部入库** C/C++/mm（排除 vendor）命中 **0**
  - `check_repo_hygiene.sh` 五项判据仍 5/5，INFO 计数为 0
  - Debug 全树重编 + `-Werror` + ctest（`--skip-label=heavy`）不掉例
  - `gen_api_reference.py --check` 一致（重排不得改动符号与注释内容）
  - `git diff --summary` **不含 mode change**（符号链接必须还是符号链接）
  - `gate_scope.sh` 对 `.clang-format` 不再报"未归类"，且 `--files` 边界六条全对（见「追加」段）
verification:
  - 见「实测」段的四条命令与结果
risk:        ① 113 文件的 cosmetic diff 一旦与功能改动同批，评审会失去信噪比 —— 所以单独成 commit，
              且不与任何功能卡混提；② `clang-format -i` **破坏符号链接**（实测发生，见 P176）；
              ③ `--dry-run` 不带 `--Werror` 时**违规也返回 0**，统计口径写错就是假绿（见 P175）；
              ④ 判据本身仍"只报不判"：不做成红闸（红闸只会逼出 `|| true`）。
```

## 背景

INFRA-034（2026-10-16）立 `.clang-format` 时只描述现状、不重排，留下 engine **79/115** + tests **34/45**
的存量，并把它写进 `.clang-format` 头部作为"已知基线"。基线非零的代价是：hygiene 的 INFO 计数**永远可读**，
新写的代码不合规也混在存量里看不见。清到 0 之后，这个计数才第一次有意义。

风格口径没变（`BasedOnStyle: Google` + 五条覆盖），所以本卡不产生新的格式决定，只是将既有决定施加到全库。

## 实测

| 项 | 结果 |
|---|---|
| 重排前范围 | 违规清单 **114** 条 = engine/core 65 + tests/unit 34 + engine/platform 14 + `api/swift/…/include/cq_sdk.h` 1 |
| 入库文件基数 | `git ls-files` 排除 vendor 的 `.h/.c/.cpp/.mm` = **168** |
| 实际重排 | **113 files changed, +1684 / −1211**（第 114 条是符号链接，见下） |
| 重排后 | **违规 0/168**；hygiene **5/5**，INFO「违规 0」 |
| 编译 | Debug 全树重编 **92 TU**，`-Werror` 无警告 |
| 单测 | `build_core.sh --config=Debug --test --skip-label=heavy` → **ctest 38/38**（40.07s） |
| 文档一致性 | `gen_api_reference.py --check` ✅、`sync_context.py --check` ✅ |
| **门禁计数口径订正**（本卡收尾才做，属同一件事） | `check_repo_hygiene.sh` 原先只扫 `engine/**` = **115** 个，而重排文件里 **34 个在 `tests/**`** → 那 34 个进门禁根本不在射程内，"违规非零即新代码"当场是假话。改为五根 pathspec + `grep -v '^engine/vendor/'`，基数 **168**（与本卡口径同一行字）。**负向反证打在完整路径上**（P175）：向 `tests/unit/abi/test_c_abi_edit.c` 注入一处违规 → INFO **1/168**；用 `/tmp` 备份还原并 `cmp` 确认 → **0/168**，`git diff --shortstat -- tests` 仍 **34 files / +457 −241** 未变 |
| **符号链接事故** | `git diff --summary` 出现 `mode change 120000 => 100644 api/swift/Sources/ChuanqiCutCore/include/cq_sdk.h`：`-i` 把符号链接换成了 38624 字节的**普通副本**（内容与 `engine/core/cq/cq_sdk.h` 逐字节相同，所以编译与测试都没报错）。已 `ln -s` 恢复，该路径现与 HEAD 一致。**这类事故不会让任何门禁变红**，只有 `git diff --summary` 看得见（P176） |

复测命令（口径固定，别再自创）：

```bash
CF=/Library/Developer/CommandLineTools/usr/bin/clang-format
git ls-files -z 'engine/*.h' 'engine/*.c' 'engine/*.cpp' 'engine/*.mm' \
                'tests/*.h' 'tests/*.c' 'tests/*.cpp' 'tests/*.mm' \
                'api/*.h' 'api/*.c' 'api/*.cpp' 'api/*.mm' \
                'ui/*.h' 'ui/*.c' 'ui/*.cpp' 'ui/*.mm' \
                'apps/*.h' 'apps/*.c' 'apps/*.cpp' 'apps/*.mm' \
  | tr '\0' '\n' | grep -v '^engine/vendor/' > /tmp/cf-files.txt
: > /tmp/cf-bad.txt
while IFS= read -r f; do "$CF" --dry-run --Werror "$f" >/dev/null 2>&1 \
    || printf '%s\n' "$f" >> /tmp/cf-bad.txt; done < /tmp/cf-files.txt
wc -l < /tmp/cf-bad.txt   # 并把前几个文件名打出来自证，见 P175
```

**"只是空白改动"的证法**（别只靠"看着像格式改动"）：把 HEAD 版与工作树版各自抽掉全部空白后比校验和，
113 个文件里 **112 个逐字符相同**；唯一不同的是 `engine/core/cq/base/chq_logging.h`，
再用字符频次对撞 —— 差别**只有反斜杠 18 → 32**（clang-format 把 `do { … } while (0)` 宏体按续行拆开），
没有任何其它字符计数变化 ⇒ 逻辑 token 未动，与编译结果（92 TU + `-Werror` + ctest 38/38）互为佐证。

```bash
# 单文件版：a/b 相同 ⇒ 该文件的改动纯属空白
f=engine/core/cq/base/chq_logging.h
a=$(git show "HEAD:$f" | tr -d '[:space:]' | cksum | awk '{print $1}')
b=$(tr -d '[:space:]' < "$f" | cksum | awk '{print $1}')
[ "$a" = "$b" ] || diff <(git show "HEAD:$f" | tr -d '[:space:]' | fold -w1 | sort | uniq -c) \
                        <(tr -d '[:space:]' < "$f" | fold -w1 | sort | uniq -c)   # 列出到底是哪些字符变了
```

## 追加：把 `.clang-format` 归类进路由（脚本自己要求的一条）

`gate_scope.sh` 原本把根目录 `.clang-format` 判成"未归类 → 升档"，并在结尾要求
**"把该路径加进本脚本的规则里（出现新形状不回填 = 路由开始说谎）"**。本批补 **R12**：
`.clang-format` / `.editorconfig` → `check_repo_hygiene.sh` + 全量，并显式 `NEED_FULL=1`
（**升档不降级**：改风格基线的射程是全库 C/C++，没有任何模块窄检能覆盖它 —— 本卡一趟就改了 113 个文件）。

R12 落地当场抓到自己（→ **P178**）：`UNCLASSIFIED` 第一次为空 →
① `bash 3.2 + set -u` 下 `"${UNCLASSIFIED[@]}"` **直接报 unbound variable**；
② 末段无条件打印"未归类的改动 / 请把路径加进规则里"，而 R12 是**主动**要求全量 ——
即脚本刚把一件事归类好，还在叫读者去修那个已经正确的路由。改成两个位
（`NEED_FULL` = 要不要全量 / `UNCLASSIFIED_FULL` = 为什么）后文案分两路，档位标题也跟着分。

路由实测（`--files` 造边界，六条都跑）：

| 输入 | 期望 | 实测 |
|---|---|---|
| 当前工作树（131 文件，含 `.clang-format`） | 归类，不报未归类 | 命中 `R1 R2 R3 R8 R9 R12`，标题 `L3 全量（规则主动要求）`，**无** unbound 报错 |
| `--files weird/foo.txt` | 真未归类 | `L3 全量（判不准升档）` + "加进规则里"提示 |
| `--files docs/README.md` | 纯文档窄检 | `R11` / `L1/L2 窄检` |
| `--files .clang-format` | 单文件也升档 | `R12` / `L3 全量（规则主动要求）` |
| `--files docs/README.md .clang-format` | **R11 不能被 R12 挤掉** | 命中 `R11 R12`，清单里仍有 `linkcheck_docs.py` |
| `bash -n` | 语法 | rc=**0** |

第 5 条是**位置要求**：R12 必须写在 R11 **之后** —— R11 的前提是"没有任何其它规则命中"，
而 `linkcheck_docs.py` **不在 `run_gate.sh` 的 19 步里**（只在 CI workflow 第 102 行），
把它放前面会让"文档 + 风格配置"同批的 diff 丢掉链接判据。

## 回写

- 现状与符号链接警告 → [.clang-format](../../.clang-format) 头部（已改）
- 坑 → [.ai/memory/pitfalls.md](../../.ai/memory/pitfalls.md) P175（假绿统计）/ P176（`-i` 破坏符号链接）/ P178（新增归类规则把"零命中"分支第一次跑出来）
- 实测数字 → [.ai/memory/baselines.md](../../.ai/memory/baselines.md)
- 模块册行 → [.ai/modules/core.md](../../.ai/modules/core.md)
- 门禁步数 18→19 与真源"步数以脚本为准" → 属 [TASK-INFRA-045](TASK-INFRA-045-Draft包进门禁.md)，同批提交
- **共写声明**：`tools/ci/gate_scope.sh` 本批被两卡改（R4 build/test 判定归 045、R12 风格配置归 046），
  同一文件拆两个 commit 会得到一个"中间态脚本"，故**整文件随 045 的提交落库**，R12 的内容以本卡为归口。
  这是同机同批的自撞，不是跨机写集相交（ADR-0030 的相交判定看的是并行开发机）。
