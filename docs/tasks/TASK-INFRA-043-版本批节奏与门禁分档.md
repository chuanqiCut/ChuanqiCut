# TASK-INFRA-043：版本批节奏落地（VERSION 真源 + 门禁分档 + 窄检路由）

> 模板口径见 `.ai/templates/task.md`。Spec/决策 = [ADR-0046](../decisions/ADR-0046-版本批门禁节奏与单源版本.md)。

```yaml
id:          TASK-INFRA-043
layer:       基建
goal:        把 ADR-0030 §4 的"阶段批"纪律换成机器可判定的"版本批"节奏 —— 全量门禁一个版本号
             只跑一趟，单卡自查降到秒级~1min
input:       [ADR-0046, docs/reports/VERSIONS.md, .ai/memory/baselines.md「并行化后全量门禁第二趟」,
              传哲 2026-10-17 裁定（批次口径=显式小版本号；真机本轮不动）]
output:      [VERSION, docs/reports/VERSIONS.md, tools/ci/run_gate.sh（version 列 + --batch + 重复批提示）,
              tools/ci/gate_scope.sh（新）, tools/build/build_core.sh（--skip-label）,
              tests/CMakeLists.txt（14 例 LABELS heavy）, 根 CMakeLists.txt（版本从 VERSION 读）,
              .github/workflows/ci.yml（**改判**：Debug 保全 52 例，见实现要点 4）,
              .ai/source/AGENTS.root.md §验证/§双机分工 + 生成物重刷, docs/README 指针]
write_set:   VERSION、docs/reports/VERSIONS.md、docs/decisions/ADR-0046-*.md、tools/ci/run_gate.sh、
             tools/ci/gate_scope.sh、tools/build/build_core.sh、tests/CMakeLists.txt、
             根 CMakeLists.txt、.github/workflows/ci.yml、.ai/source/AGENTS.root.md、AGENTS.md 等 5 份生成物、
             docs/README.md、docs/tasks/TASK-BACKLOG.md、.ai/modules/core.md（基建卡归口，见下方订正）、.ai/memory/*.md
read_set:    .ai/memory/baselines.md（用例秒数）、docs/decisions/ADR-0029/0030/0037/0044、
             build/gate-logs/*（本轮实测日志）
deps:        []（与 UIA-046 / CORE-011 写集不相交，可并行）
acceptance:
  - `cat VERSION` 与 `run_gate.sh` 打印的 version 字段一致；`gate-history.tsv` 表头含 `version` 列
  - `ctest --test-dir build -N -L heavy | grep -c "Test #"` == **14**；`-LE heavy` 的计数 == **38**
  - Debug 档 `--skip-label heavy` 实跑 ctest 段 **< 30s**（基线 107.55s，本卡目标 ≈15s）
  - Release 档不带 flag 时**仍跑满 52 例**（`Passed` 计数 == 52）—— heavy 不许从验收档消失
  - `gate_scope.sh` 对四类样本 diff（core 头 / ui Swift 包 / podspec / shader）各给出**不同的**窄检命令，
    且 podspec 类必含双壳（P129/P150 案底）
  - `run_gate.sh` 同一 version 第二次跑全量时打印「本版本已有 N 趟全量」提示；`--batch` 显式给号可覆盖
  - `bash -n` 两份脚本 rc=0；`check_repo_hygiene.sh` **5/5 PASS**；`linkcheck_docs.py` 全绿；
    `sync_context.py --check` 一致；`gen_api_reference.py --check` 一致
  - **本卡自证不得跑全量 18 步**（吃自己的药）：验证只跑 core 两步 + `--fast`
verification:
  - ctest --test-dir build -N -L heavy | grep -cE 'Test *#'   # 14；-LE heavy 计数 38；总数 52
  - cmake -S . -B build（或任一趟 build_core.sh）后 grep CMAKE_PROJECT_VERSION build/CMakeCache.txt
  - tools/build/build_core.sh --platform=apple --config=Debug --test --skip-label heavy
  - tools/build/build_core.sh --platform=apple --config=Release --test
  - tools/ci/run_gate.sh --fast
  - tools/ci/gate_scope.sh --files engine/core/cq/media/chq_frame_provider.h
  tools/ci/gate_scope.sh --files ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/TrackInteraction.swift
  tools/ci/gate_scope.sh --files ui/ChuanqiCutDraft/ChuanqiCutDraft.podspec
  tools/ci/gate_scope.sh --files engine/shaders/portable/blit.vert
  tools/ci/gate_scope.sh --files docs/README.md          # 纯文档 → 不碰编译器
  tools/ci/gate_scope.sh --files weird/newfile.txt       # 兜底 → 必须判成升全量
  - tools/ci/check_repo_hygiene.sh && "${PYTHON_BIN:-python3}" tools/ai/linkcheck_docs.py
    && "${PYTHON_BIN:-python3}" tools/ai/sync_context.py --check
risk:        ① heavy 在 Debug 从此不跑 —— 判据是语义标不是秒标，标错=某例两档都不跑（缓解：core-rel 全跑，
              且 acceptance 第 4 条硬查 52）；② 路由漏判（缓解：不确定即升档）；③ 版本号手升忘升
              （缓解：每趟打印当前版本与已跑趟数）；④ 动 `tests/CMakeLists.txt` 与 `build_core.sh`
              = 高冲突文件，本卡由集成机独占
parallel:    true（与 UIA-046 / CORE-011 写集不相交；**不与任何其他 INFRA 卡并行**——CI/构建脚本/真源为热点）
```

## 背景

ADR-0030 §4 早就规定"开发期只做模块级自查、全量按阶段批"，但它是**纪律不是工具**：
"一个阶段"在机器上没有定义（版本号四处不一致且无真源）、"该跑什么"只在人脑里（所以保守的人全跑）、
贵的与便宜的挤在同一档。传哲 2026-10-17 直接提出这个问题，并选定**显式小版本号**作批次口径。

成本证据（2026-10-17 全量趟，逐个用例实测）：52 例里前 11 例占 Debug ctest 的 **94.6%**，
其中 `media_sequential_real` 一例 **58.23s = 54.1%**；其余 41 例合计 **3.32s**。
而 Debug 与 Release 跑的是**完全同一套 52 例（交集 52/52）**。详见 `baselines.md`。

## 实现要点

1. **本批单卡不拆两张**：两件事（节奏工具 / heavy 分档）共写 `tools/ci/run_gate.sh`，
   拆开会违反"写集不相交才可并行"。INFRA-044 **不发号**（留空，不烧号）。
2. **`VERSION` 放根目录**不违反 ADR-0019 §2 —— 那条禁的是"内容文档"，`VERSION` 与 `.clang-format`、
   `CMakeLists.txt` 同类是基建文件；批次账（内容文档）落 `docs/reports/VERSIONS.md`（append-only 域）。
3. **heavy 用 `LABELS`，不用名字清单**：秒数会随机器变（P171），语义不会。分档判据 =
   「需要真实素材文件或硬件 codec/Metal 链路」，不是「跑得慢」。14 例清单：
   `media_sequential_acquire`、`platform_apple_metal_render`、`platform_apple_demux`、`media_smoke_apple`、
   `media_bframe_real`、`platform_apple_native_image`、`preview_renderer`、`c_abi_preview`、
   `platform_apple_encode`、`platform_apple_muxer`、`platform_apple_muxer_audio`、
   `frame_provider_apple`、`media_sequential_real`、`platform_apple_decode`。
   ⚠️ **例外（不标 heavy）**：`media_ffmpeg_probe` —— 依赖第三方装配但 <1s，且它是 FFmpeg 链路的
   唯一功能证据，留在 Debug 让 CI 也能跑到。`core_audio_preview_mixer` / `core_preview_pump` 虽 5.4s/4.7s
   但**纯 CPU**（无线程/无素材），按语义规则**不标**。
4. **档间分工写死在 `run_gate.sh`**：core-dbg 带 `--skip-label=heavy`，core-rel 不带。
   ⚠️ **CI 落地时改判（声明式，不静默）**：原写"CI Debug 同口径"，实作为 **CI 保持全 52 例**。
   理由：分档省的是**本机墙钟**，CI 的墙钟不花传哲的时间，跟着跳过只是少验；CI 的 Debug 趟因此
   成为 heavy 用例在 Debug 档的**唯一覆盖点**，也就是 ADR-0046「代价 ①」的缓解措施本身。
   两边都打印名单（`ctest -N -L heavy`），沿用它现有 `-N | grep` 的写法，别新造格式。
5. **`gate_scope.sh` 只读**：不改任何状态、不跑构建、只打印建议命令 + 一句理由。
   规则表按"热点优先"匹配，命中多条时**取最贵的一条**（升档不降档）。
6. **不动 podspec / pbxproj / Info.plist**：本 ADR 要的是批次口径，不是发布流程（ADR-0046 §明确不做）。
7. **根 `CMakeLists.txt` 从 `VERSION` 读版本**（`file(STRINGS … LIMIT_COUNT 1)` + 正则守卫，
   格式不符 `FATAL_ERROR`）。这不是"补一个缺失的版本号"——它原本就写着 `VERSION 0.1.0`；
   改它是为了让「CMake 侧 == 真源」成为**结构上成立**的事实，而不靠人对表。
   ⚠️ 初稿把这里记成"CMake `project()` 不带版本"，是我只核了三处就外推第四处的错，已就地订正
   （见 ADR-0046 §背景 1 的订正块）。
8. **`if(TEST _t)` 是个陷阱**：必须写 `if(TEST ${_t})`。前者问的是"有没有一个叫 `_t` 的用例"，
   **恒假** → 一个标签都打不上，而 `-LE heavy` 照样"成功"跑完全部 52 例 —— 分档看起来生效、
   实际没生效。抓到它靠的是实现要点 4 里那句"跳过名单必须打印"（名单为空当场说破）。记 **P172**。

## 验收

对应 acceptance 逐条：1 用 `cat VERSION` + 跑一趟 `--fast` 看 tsv 表头；2/3/4 用 `ctest -N -L heavy`
计数与两档实跑的 `Passed` 计数；5 用四类样本 diff 各喂一次；6 看提示行与 `--batch` 覆盖；
7 跑三条检查命令；8 = 本卡全程不出现 18 步全量（日志目录 `gate-summary.md` 档位列可核）。

## 实测（2026-10-17 编码趟，本机 Intel x86_64，验收档未跑全量）

| 验收条 | 命令 | 结果 |
|---|---|---|
| 1 版本一致 | `cat VERSION` / `cmake -S . -B build` + grep cache | `0.1.0`；`CMAKE_PROJECT_VERSION:STATIC=0.1.0`；tsv 表头末列 `version`/`batch` ✅ |
| 1b 守卫反证 | `cmake -S` 配 `VERSION=0.1`（非 x.y.z） | configure **rc=1**，打印 `VERSION 文件内容非法（期望 x.y.z）：'0.1'` ✅（正向 + 负向都有） |
| 2 标签计数 | `ctest -N -L heavy` / `-LE heavy` / `-N` | **14 / 38 / 52** ✅（第一次跑是 **0/52/52** —— `if(TEST _t)` 恒假，见实现要点 8 = P172） |
| 3 Debug 档提速 | `build_core.sh --config=Debug --test --skip-label=heavy` | ctest **15.17s**（基线 107.55s，**7.1×**），**38/38 passed**，**0 TU**（暖） ✅ <30s |
| 3b 同趟冷态 | 同上，但前一趟是 Release（共用一棵树） | 整步 **86s** = 重编 **95 TU** + ctest **38.53s**；`--fast` 全档 **100s**（上一批同档 **239s**） |
| 4 Release 不减档 | `build_core.sh --config=Release --test`（不带 flag） | **52/52 passed**，ctest **151.55s**，整趟 211s / 95 TU ✅ heavy 没从验收档消失 |
| 5 路由四类样本 | `gate_scope.sh --files <core头 / ui包 / podspec / shader / 文档 / 陌生>` | 五档命令集**互不相同**；podspec 类含 `check_apple_shells.sh` ✅；陌生文件判 **L3 升档** ✅ |
| 5b 路由自测暴露的 bug | 首跑本工作树 | 中文文件名被 `core.quotepath` 转义成八进制 → `docs/*` 不匹配 → **误判升全量**；改 `-z` + `read -d ''` 后正确（P173） |
| 6 重复批提示 | 合成 tsv 验 awk 谓词 `$3=="全量" && $10==v` | v0.1.0 → **1**、v0.2.0 → **0** ✅。**真实路径本趟未触发**（全量一趟未跑，符合验收 8） |
| 7 静态与文档判据 | `bash -n` ×3 / `check_repo_hygiene.sh` / `linkcheck_docs.py` / `sync_context.py --check` / `gen_api_reference.py --check` | `bash -n` 三份脚本 rc=**0**；hygiene **5/5 PASS**（tracked **885**、产物 **0**、旧路径非豁免 **0**、editorconfig 四条件 **0**、scratch 只在根 `/build/`；clang-format INFO 仍 **79/115** 本批不重排）；`sync_context.py --check` **一致**（5 份生成物重刷后零 diff）；`gen_api_reference.py --check` **一致**；`linkcheck_docs.py` 首跑**抓到 1 条真断链**（`VERSIONS.md` 里 ADR-0030 少写 `../decisions/`）→ 修后 ✅ |
| 8 不跑全量 | `build/gate-logs/gate-history.tsv` 的 tier 列 | 本批只有 `--fast` 与单步，**无 18 步全量** ✅ |

**数字口径提醒（P167/P171）**：`15.17s` 是 0 TU 暖态、`38.53s` 是同内容但带 95 TU 重编的趟 ——
两值都是"38 例的 ctest 段"，差 2.5×。引用时必须附 TU 数，否则会重演 P167。

## 回写

- 节奏规则 → `.ai/source/AGENTS.root.md` §验证 + §双机分工（再 `sync_context.py` 重生成 5 份入口文件）
- 实测数字（Debug 段 107.55s → 实跑值、heavy 计数）→ `.ai/memory/baselines.md`
- 踩到的坑 → `.ai/memory/pitfalls.md`（若本批无新坑，明确写"本批无新坑"，不留空）
- 批账首节 → `docs/reports/VERSIONS.md`（已随本卡落盘）
- 门禁记录 → [.ai/modules/core.md](../../.ai/modules/core.md) 模块册测试记录节
  （⚠️ **声明式订正**：卡面初稿三处写的是 `.ai/modules/infra.md`，**该模块册不存在**（`ls .ai/modules/` =
  19 份，基建/治理卡的归口一直是 `core.md`，头部归属行「集成机（内核基础 + 热点文件）」）。
  本轮三条门禁全绿却放行 —— 因为反引号路径在叙述域（`docs/tasks/`、`docs/decisions/`、`.ai/memory/` 等）
  被 [tools/ai/linkcheck_docs.py](../../tools/ai/linkcheck_docs.py) 整体豁免，且非叙述域也只查 `docs/`/`../`
  前缀。故本条**改用 Markdown 链接写**（链接对所有文件生效），错因与取证见 **P174**。）
