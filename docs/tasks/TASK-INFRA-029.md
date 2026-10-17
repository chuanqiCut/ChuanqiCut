# TASK-INFRA-029：edit_plan golden 夹具出树（59 个入库文件 → tests/golden/edit_plan/）

```yaml
id:          TASK-INFRA-029
layer:       基建
goal:        把 59 个 edit_plan golden JSON 从内核源码树里搬出，tests/golden/ 重新成为唯一测试数据归口，
             同时清掉 tests/golden 里 4 处机器绝对路径
input:       [RESEARCH-018 §2 C 项（复发）, tests/CMakeLists.txt:661]
output:      [tests/golden/edit_plan/**(59), tests/CMakeLists.txt 常量, tests/golden/generate.py 默认值, 删除 engine/core/cq/ai/plan/edit_plan_golden/]
write_set:   engine/core/cq/ai/plan/edit_plan_golden/**（迁出即删）, tests/golden/**,
             tests/CMakeLists.txt, engine/core/cq/ai/**（仅当 C++ 侧有硬编码相对路径读取）
read_set:    tests/unit/test_edit_plan_validator.cpp, docs/tasks/TASK-AIEDIT-001 相关契约
deps:        [TASK-INFRA-026]
acceptance:
  - `git ls-files tests/golden/edit_plan | wc -l` = 59，且
    `git ls-files engine/core/cq/ai/plan/edit_plan_golden | wc -l` = 0
  - `ctest --test-dir build -R edit_plan` 通过，用例名与迁移前完全一致（不新增、不改名）
  - `python3 tests/golden/verify.py --json` 退出码 0（基线 `built_ok=21 built_fail=0 unbuilt=0 total_bytes=901784`，
    2026-10-16 本机 gate python 3.13.12 实跑）。⚠️ **verify.py 不覆盖 edit_plan**——它只读 `manifest.toml` + `frames/`；
    夹具覆盖面唯一由 `ai_edit_plan` 用例保证（manifest.txt 逐行读 JSON，缺文件即 FAIL）。
    ⚠️ 系统 `python3` 无 `tomllib`（< 3.11），必须用 `run_gate.sh` 的 `${PY}`，否则 ModuleNotFoundError 会被误读成搬家失败。
  - `grep -rn "/Users/zhuning" tests/golden` 零命中（4 处：generate.py×2、verify.py×1、manifest.toml 注释×1，
    统一改为「环境变量 > `PATH` > `~/.workbuddy/binaries/ffmpeg/bin`」）
verification:
  - tools/ci/run_gate.sh（core-dbg + core-rel 两段都要看到 `out of 52`，`ai_edit_plan` 不得 FAILED）
  - "${PY}" tests/golden/verify.py --json | tail -2   # PY = gate 用的 python 3.13.12
  - git ls-files tests/golden/edit_plan | wc -l   # 期望 59
  - git ls-files engine/core/cq/ai/plan/edit_plan_golden | wc -l   # 期望 0
risk:        夹具是 golden 基准（AGENTS 提交节明确**必须入库**），移动时若漏文件就是静默丢基准；
             必须用"迁移前后 `git mv` 计数相等 + `ai_edit_plan` 用例通过"双向取证，不能只看目录非空
             （verify.py 帮不上：它只管 frames，见 acceptance 第 3 条）。
             ⚠️ **搬家不得与门禁并发**：本卡首跑实测踩到 —— `git mv` 时 Release 段 ctest 正在跑，
             旧目录被清空 → `ai_edit_plan` 报 `FAIL: manifest 非空 / 总 0`，属假失败（P145）。
parallel:    true（与 030 串行：同写 tests/CMakeLists.txt；与 031/035 写集不相交可并行）
```

## 背景

RESEARCH-011 §3 的 C 项（数据混进源码树）在 10-11 P2 执行后**复发**：
`engine/core/cq/ai/plan/edit_plan_golden/` 现在有 59 个入库 JSON，`tests/CMakeLists.txt:661` 用
`CQ_EDIT_PLAN_GOLDEN_DIR="${CMAKE_SOURCE_DIR}/engine/core/cq/ai/plan/edit_plan_golden"` 指向它。
内核树里放数据集，直接后果是 `check_platform_headers.py` 之类的按目录扫描要额外排除，
以及新人无法一眼区分"这是实现还是数据"。

## 实现要点

- 落点 `tests/golden/edit_plan/`（传哲 2026-10-16 指定"整体"迁此）。
- `git mv` 保留历史，让 59 个文件（58 JSON + `manifest.txt`）的 blame 不断链。
- 代码侧引用面实测**只有一处**：`tests/CMakeLists.txt:661` 的 `CQ_EDIT_PLAN_GOLDEN_DIR`；
  C++ 侧无硬编码相对路径（`test_edit_plan_validator.cpp:18-19` 有 `#ifndef` 兜底）。
  其余 `edit_plan_golden` 命中全在 append-only 历史文件（TASK-AIEDIT-001、HANDOFF-016/017、
  workbuddy 日志、TODO-POOL），按 P103 **不改**；活文档只改 `.ai/modules/ai.md`。
- 机器绝对路径 4 处统一改成「`CQ_FFMPEG_BIN`/`CQ_FFPROBE_BIN` > `shutil.which()` >
  `~/.workbuddy/binaries/ffmpeg/bin`」三档回退（本机 ffprobe **不在 PATH**，实测 `command -v ffprobe` 空，
  所以不能只留 PATH 查找，否则 verify.py 当场失效）。

## 验收

见 yaml；报告 `verify.py --json` 的条目数与 ctest 通过数字（具体值，不写"绿"）。

**实测（2026-10-16，本卡执行完毕）**：

- `git ls-files tests/golden/edit_plan | wc -l` = **59**；`git ls-files engine/core/cq/ai/plan/edit_plan_golden` = **0**；
  `engine/core/cq/ai/plan/` 只剩 `chq_edit_plan_validator.{h,cpp}`（私有头与实现共置，未受影响）
- `git ls-files | wc -l` = **857**（搬家前后相同，无误删/漏加）；
  59 个入库文件 = **58 个 `.json`** + **1 个 `manifest.txt`**，而 `manifest.txt` 的
  非注释非空行正好 **58** 条 → 清单与夹具一一对应，无孤儿样例
- 用例名不变：`ctest -N` 迁移前后各 **52** 条、排序 diff 为空；`ai_edit_plan` 单独跑 **Passed 0.67s**
- `"${PY}" tests/golden/verify.py --json` → `built_ok=21 built_fail=0 unbuilt=0 total_bytes=901784`，**exit 0**
  （⚠️ 系统 `python3` 无 `tomllib` 会 `ModuleNotFoundError`，看着像搬家坏了，实为解释器口径）
- 全量门禁收尾跑：**PASS=15 / FAIL=0 / SKIP=0**，Debug **52/52** 133.05s、Release **52/52** 226.96s
- 途中踩到 **P145**（`print_summary` 拿 10-12 的旧日志给没跑过的段背书）与
  **搬家与门禁并发**造成的 `ai_edit_plan` 假失败（`FAIL: manifest 非空 / 总 0`），两条都已固化为卡内条款

## 回写

- 若 golden 目录结构变化影响 `tests/golden/manifest.toml` 约定 → 该文件属高冲突，改后在
  `.ai/modules/core.md` 模块册登记
- 日志 → `.workbuddy/memory/2026-10-16.md`
