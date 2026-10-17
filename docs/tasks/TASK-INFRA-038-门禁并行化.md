# TASK-INFRA-038：门禁 C++ 段并行化（`cmake --build` 补 `--parallel`）

> 传哲 2026-10-17 裁定「开工」+「推」。立项依据是**同脏集 A/B 实测 3.6×**，不是结构推断（P166）。

```yaml
id:          TASK-INFRA-038
layer:       基建
goal:        把内核编译从单线程改到按核数并行，砍掉全量门禁里唯一有数量级的一段（817s / 66%）；
             同时让 run_gate.sh 的摘要**自己记每步时长**，成本问题不再靠日志 mtime 反推
input:       [pitfalls P166（成本结构必须实测）, baselines「并行度 A/B」, 「18 步全量门禁实测」]
output:      [tools/build/build_core.sh, tools/build/build_core_apple.sh, tools/ci/check_ios_compile.sh,
              tools/ci/run_gate.sh（摘要加时长）, 本卡]
write_set:   tools/build/build_core.sh · tools/build/build_core_apple.sh · tools/ci/check_ios_compile.sh ·
             tools/ci/run_gate.sh
read_set:    CMakeLists.txt（只读，不改）· build/gate-logs/*.log
deps:        [TASK-INFRA-037]
acceptance:
  - 三个 `cmake --build` 调用点都带 `--parallel`，且核数可由 `CQ_JOBS` 环境变量下调（排障用）
  - 并行不改判定：`-Werror` 仍然生效，ctest 通过数与串行一致（Debug 52/52、Release 52/52）
  - run_gate.sh 摘要每行带该步秒数；`--fast` / `--skip-apple` 语义不变
  - 全量门禁 PASS=18 / FAIL=0 / SKIP=0，墙钟低于串行基线 **20m40s**
verification:
  - time tools/build/build_core.sh --platform=apple --config=Debug --test
  - tools/ci/check_ios_compile.sh --prime --config=Release
  - tools/ci/run_gate.sh          # 全量，摘要里每步时长即验收数字
risk:          并行后 make 的输出会交错，凡是靠"读构建日志相邻行"做判据的地方都可能被打破 ——
               本卡只动 `--parallel` 与摘要时长，**不动任何 digest 的正则**；若某步 digest 因交错失配，
               按"digest 失配 = 该步红"处理而不是放宽。ctest 保持串行（不加 `-j`）：
               设备/时序类用例并发下不可靠，且它只占零头。
parallel:      false   # 构建脚本 = 高冲突文件，串行归集成机
```

## 实测依据（本机 Intel x86_64，12 逻辑核）

同一棵 `build/`（Release），同一脏集 `touch engine/core/cq/base/chq_rational_time.h`（67 个直接 include）：

| 口径 | 结果 |
|---|---|
| `cmake --build build`（现状，Unix Makefiles 无 `--parallel` → 单线程） | **254s / 73 TU** |
| `cmake --build build --parallel 12` | **70s / 72 TU** |
| 加速比 | **3.6×**，两次 rc=0 |

串行基线（2026-10-17 全量 18 步）：`core-dbg` **379.0s** + `core-rel` **438.4s** = **817s**，全程 **20m40s**。

## 冷构建参照（本卡顺带补上的观测）

`tools/ci/check_ios_compile.sh:63` 原样写着「冷构建实测约 **8m20s**」——那是 `build_core_apple.sh`
**三切片串行**的成本。并行化后这个数应当显著下降；本卡收尾时用
`rm -rf build/apple && tools/build/build_core_apple.sh --config=Release` 量一次，替换该注释里的数字。

## 落地实测（2026-10-17 12:2x~12:4x，本机 = 集成机，`--parallel 12`）

改动落点（三个调用点全覆盖，核数一律 `CQ_JOBS` 可下调）：

| 文件 | 位置 | 改动 |
|---|---|---|
| `tools/build/build_core.sh` | L33 / L75 / L88 | `CQ_JOBS` 默认 `hw.ncpu`；横幅打印 `jobs:`；`--parallel "${CQ_JOBS}"` |
| `tools/build/build_core_apple.sh` | L55 / L180-181 | 同上；三切片循环内传 `--parallel` |
| `tools/ci/check_ios_compile.sh` | L36-37 / L75 | 同上；头部时长注释按新数重写（见 P167） |
| `tools/ci/run_gate.sh` | L56 / L59 / L109-139 / L207 | `DURATIONS[]` + `GATE_T0`；`run_step`/`run_step_dir`/内联 `layer-hygiene` 三处计时；摘要行末 `[Ns]`；末行「墙钟 Ns；已计时步骤合计 Ns（差 = 未计时步骤/记账开销）」 |

内核两兄弟步（同脏集：换 `--config` → 各一次全量重编，与串行基线同状态）：

| 步 | 串行基线 | 并行后 | 拆解 |
|---|---|---|---|
| `core-dbg` | 379.0s | **251s** rc=0 **52/52** | ctest real **195.5s** → 构建+配置 ≈ **55s**（差值推算） |
| `core-rel` | 438.4s | **208s** rc=0 **52/52** | ctest real **134.2s** → 构建+配置 ≈ **74s** |

- **本卡 12:0x 那条外推已作废**（"全程降到 ~10min"）：它假设 build 与 ctest 同比缩放。实测
  `--parallel` 只压构建段（构建段 3~5×），ctest 一点没动 → **步骤墙钟只降 1.78×**。
  加速比必须说明是**哪一段**的。详见 `baselines.md`「并行化落地实测」。
- **新的主成本对象换成了一层**：`media_sequential_real` 单例 Debug **113.88s**（占该趟 ctest 58%）、
  Release **54.76s**（41%）。ctest 保持串行（本卡风险项写死的纪律），所以这一段**不在本卡射程**。
- Apple 三切片冷构建：串行 **8m20s** → 并行 **151s** rc=0（重编 150 TU = 全量），**3.3×**。
  `check_ios_compile.sh:19` 的注释已替换为新数并保留旧数出处。

## 全量门禁收口（12:44:30~12:53:58，本机实测）

**PASS=18 / FAIL=0 / SKIP=0，墙钟 568s = 9m28s**（串行基线 1240s / 20m40s → **2.18×**）。
逐步秒数与占比见 `baselines.md`「并行化后 18 步全量门禁」，此处只留结论：

- 验收四条**逐条达成**：三个调用点带 `--parallel` 且 `CQ_JOBS` 可下调；`-Werror` 仍生效、
  Debug/Release 各 **52/52**；摘要每行带 `[Ns]`（`--fast`/`--skip-apple` 语义未动，本趟未跑这两档）；
  全量 **PASS=18** 且墙钟远低于 20m40s。
- digest 没有因输出交错失配（六包用例数 **26/52/77/16/81** 与前几批逐字相等）
  → 本卡"digest 失配按红处理"的预案未触发，**没放宽任何正则**。
- 计时器自证：`run_gate.sh` 末行「墙钟 567s / 已计时合计 567s / 差 0s」。
- **本卡没做的事**（不扩写集）：ctest 仍串行；Debug/Release 共用一棵 `build/`；
  后两条各带一个数量级的候选，分别登记为池 **[25]**、**[26]**（⏳ 待传哲判）。

## 状态：✅ 完成（本机全量门禁 PASS=18，未 push 前不算远端口径）
