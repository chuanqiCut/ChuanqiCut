# TASK-INFRA-034：治理补齐（CI / .clang-format / .editorconfig）与活文档路径收口

```yaml
id:          TASK-INFRA-034
layer:       基建
goal:        补上从未落地的 CI 与代码风格配置，把 tools/probe 并入 tools/qa，并把搬家后的路径回填到所有"会被执行的"文档
input:       [RESEARCH-018 §2 F/G/H 项（从未动）, .github/workflows/.gitkeep（空占位）, 027~033 的最终路径,
              pitfalls P151 附带发现（`gen_api_reference.py --check` 无人校验 → 接口文档过期 4 天）,
              027 遗留的过渡忽略规则（INFRA-032 后指向不存在目录）]
output:      [.github/workflows/ci.yml, .clang-format, .editorconfig, tools/qa/probe/**, tools/probe(删),
              活文档路径回填（根 README.md、docs/BUILD.md、.agents/skills/**、.ai/modules/**）]
write_set:   .github/workflows/*, .clang-format, .editorconfig, tools/probe/**（迁出即删）→ tools/qa/probe/**,
             tools/ci/check_repo_hygiene.sh（新增）, tools/ci/run_gate.sh（print_summary 修复 + gen_api_reference --check 新步）,
             .gitignore, .zcodeignore（删 4 条指向 `engine/bindings/swift/` 的死忽略规则，INFRA-032 之后失效；
             **INFRA-033 又使 2 条失效**：两文件的 `shaders/generated/`，见"死忽略规则清理"验收项）,
             README.md（仓库根）, docs/BUILD.md, docs/COCOAPODS.md（pod 树与"两个本地 spec 同目录"叙述重写）,
             .agents/skills/**/SKILL.md, .ai/modules/**, .ai/memory/{pitfalls,baselines}.md,
             docs/README.md（**范围收缩**：§六交接表、:12 上手命令、§九"做到哪了"三处已由 INFRA-035 改掉，
             本卡不得重复改也不得回滚；其余索引行仍归本卡）,
             docs/specs/PLATFORM-接口契约.md,
             tools/ai/linkcheck_docs.py（**域豁免或收紧 BACKTICK_PATH**，见"linkcheck 存量断链"验收项；
             不改 checker 则该判据恒不可达）,
             engine 侧 5 处注释（cq_sdk.h、cq_sdk.cpp、base/chq_status.h、platform/chq_capabilities.cpp、
             platform/apple/gfx/gfx_metal_internal.h，均为 `tests/unit/<平铺名>` 引用回填，不动代码），
             docs/tasks/TASK-BACKLOG.md §15 状态位。
             ⚠️ **执行中追加的写集（2026-10-17，卡原文未列，按"验收判据不可假绿"原则必须登记）**：
             `tools/build/build_shader_toolchain.sh`（**新增**，P160 的修复主体 —— 本卡复现 CI 时发现
             "构建期第三方工具只在本机暖缓存里"，不补这个脚本 `ci.yml` 的 core 段就永不可能绿）、
             `third_party/src/SPIRV-Cross/CMakeLists.txt` 的**不入库本地补丁**（池 [23]，等传哲判定）、
             `docs/handoff/HANDOFF-025-*.md`（本批收口交接）、`docs/tasks/TODO-POOL-*.md` 追加 [22]/[23]、
             **`docs/decisions/ADR-0045-*.md`（新）与 `docs/README.md` 的 ADR 索引行**、
             ⚠️ **一处非注释的源码改动**：`engine/platform/apple/media/audio_engine.mm:252`
             未用形参 `note` → `/* note */`。**这是 P146 的存量红**（该函数整段在
             `#if TARGET_OS_IPHONE` :212-271 里，`build_core.sh --platform=apple` 走 macOS 切片编不到，
             所以 core-dbg/core-rel 一路绿、只有 `apple-xcframework` 段红；引入者 `b471b8c`），
             新加的 `ios-compile` 步第一次把它编出来。卡面 write_set 原文只声明了"engine 侧 5 处注释"，
             本行属**必要偏离**，登记在此（数字详见 §实测 P146 节与 `.workbuddy/memory/2026-10-16.md`）
read_set:    git ls-files 全量, tools/build/*.sh, run_gate.sh
deps:        [TASK-INFRA-028, TASK-INFRA-029, TASK-INFRA-030, TASK-INFRA-031, TASK-INFRA-032, TASK-INFRA-033, TASK-INFRA-035]
acceptance:
  - `.github/workflows/` 下至少一个可运行 workflow（当前只有 .gitkeep）：
    在 GitHub runner 上 `cmake` 走系统 PATH（`CMAKE_BIN=cmake`），跑 `tools/build/build_core.sh --platform=apple --test`；
    **本地等价证据**必须是 `CMAKE_BIN=$(command -v cmake) tools/build/build_core.sh --platform=apple` 通过，
    不允许把"远端 CI 绿"当作已验证（AGENTS：远端门禁不可信）。
    ⚠️ **P147 的 flake 必须先在 workflow 里排除**：`platform_apple_decode` 在全量段里会因
    `PopFrame` 的固定 1s 丢帧判据（`media_decode.mm:681-698`）在负载高时真丢帧而红（实测全量 44.38s 失败 /
    单跑 3/3 绿）。workflow 里用 `ctest -E 'platform_apple_decode'` 或把它列 allow-missing 并在本机阶段批补跑；
    **禁止用"CI 失败就无脑重试三次"掩盖**（那是把 P147 变成永久噪声）。
    判据：workflow 的 core 段在本机连续 2 次跑都绿，且日志里能看到被排除的用例名单。
  - `.clang-format` 落地但**本批不重排任何源码**：用
    `clang-format --dry-run --Werror $(git ls-files 'engine/*.h' 'engine/*.cpp' 'engine/**/*.h' 'engine/**/*.cpp')`
    统计当前违规文件数，该数字作为基线写进 `.ai/modules/core.md`，重排另开卡分批
  - `.editorconfig` 存在且与 `.clang-format` 的缩进/换行一致（两者冲突即验收不通过）
  - `git ls-files tools/probe | wc -l` = 0，`git ls-files tools/qa/probe | wc -l` = 3
  - 活文档零残留：`grep -rn "packages\|engine/bindings\|^shaders/\|tools/probe" README.md docs/BUILD.md docs/COCOAPODS.md docs/specs .agents/skills .ai/modules`
    命中数 = 0（**docs/research|decisions|tasks|handoff 正文与 .workbuddy/memory 属 append-only，禁止回填，见红线 5**）
    —— ⚠️ **INFRA-032 之后该 pattern 本身失效**：`engine/bindings` 字面已清零，但 `bindings/swift`
    （不带 `engine/` 前缀的旧写法）仍散落在文档里。本卡把 pattern 扩成
    `packages|engine/bindings|(^|[^a-z])bindings/swift|shaders/src|(^|[^/a-z])shaders/generated|tools/probe`，
    **2026-10-16 实测基线**（INFRA-033 之后重测，含 shader 搬家新债）：
    README.md **3**（:16 `shaders/src/blit.{vert,frag}`、:184 同、:389 目录树 `shaders/src/` 行 —— 三条全归本卡改）、
    `docs/README.md` **1**（:136，见下条专项）、
    `docs/BUILD.md` **1**（:57 案底叙述 → 判定"会不会被当命令执行"，可不改但须注明回填）、
    `docs/COCOAPODS.md` **4**（:5 `apps/apple/packages`、:16 树里 `bindings/swift/`、:64 `engine/bindings/swift/prepare.sh`、
    :137 `bindings/swift/Package.swift`；**另 :4 的 `engine/ChuanqiCutEngine.podspec` 不匹配 pattern 但已过期**，
    podspec 现落 `api/swift/` → 整棵目录树与"两个本地 spec 同目录"的叙述都要重写）、
    `docs/specs` **16 行 / 11 份文件**，其中 `ARCH-005-UI层策略与工程结构.md:126/:132` 两行是搬家批
    故意留的「原 …」标注（**判定不改**）→ 真实债 **14 行 / 9 份**。
    INFRA-033 使 `ARCH-003-跨平台内核与GPU-Shader策略.md` 新增 2 行过期：
    :88 架构图框名与 :130 "位置约束"条 —— `shaders/src/` → `engine/shaders/portable/`、
    `platform/<platform>/shaders/` → `engine/shaders/native/<platform>/`；:130 是**规范句**不是历史，必改）、
    `.agents/skills` **0**（`cq-build-test/SKILL.md:80` 与 `cq-shader-portability/SKILL.md` 的 4 处
    已由 INFRA-032/033 各自改掉 —— 判据"会被下一个 agent 当命令执行的文件必须在 breaking 批内修"）、
    `.ai/modules` **5**（`ui-apple.md:19` 与模块册行 :768/:769 是搬家批故意留的「原 …」历史标注、
    `camera.md:122` 是带日期的真机批记录、`shader.md:14` 是 INFRA-033 写的作废说明 →
    **五条都属历史行，本卡判定为不改**）。
    `docs/specs` **不在红线 5 的豁免目录内**（豁免只含 decisions/research/reports/handoff/reviews/tasks），
    所以那 14 行是本卡的活文档债，别当成历史记录漏掉。
    `TASK-BACKLOG.md` §历史行里的 10 处属 `docs/tasks` 豁免域，**不改**。
    ⚠️ **INFRA-032 收工时追加一条，且本卡的 grep 范围必须补 `docs/README.md`**（现在的范围只有仓库根 `README.md`）：
    `docs/README.md:136` 的接口参考行写 `engine/bindings/swift/Sources/CChuanqiCut/include/cq_sdk.h` ——
    **双重过期**：门面搬家 + `CChuanqiCut` 目录名早在 ADR-0033/INFRA-022 时代就已改成 `ChuanqiCutCore`
    （真源：`tools/docs/gen_api_reference.py:15` = `api/swift/Sources/ChuanqiCutCore/include/cq_sdk.h`）。
    这行在文档地图里，属"会被下一个 agent 当事实读"的活文档 → 本卡改。
  - **接口文档入门禁**（INFRA-032 暴露，P151 附带发现）：`run_gate.sh` 新增一步
    `python3 tools/docs/gen_api_reference.py --check`。案底：该生成器从未进门禁，`docs/api/engine-api.md`
    在 10-12~10-16 的 AIEDIT/AUDIO-002/效果参数批次里**长期过期**，直到 032 重跑才发现 ——
    实测符号 **76 → 103**（新增 24 个函数 + 3 个 struct），行数 406 → 516，无符号消失。
    判据：故意往 `cq_sdk.h` 加一个声明后 `--check` 必须非零退出（防"门禁步骤恒绿"）。
    ⚠️ 同时评估**生成器输出质量**（INFRA-032 重跑时实测）：`会话` 一节 **219 行里塞了 47 个 ```c 代码块**，
    因为没有 `---- 子节 ----` 注释的声明会被逐条出块。要么改生成器按大节聚合，要么在 `cq_sdk.h` 补子节注释 ——
    **入门禁之前先定口径**，否则门禁锁住的是一个没人愿意读的产物。
  - **死忽略规则清理**：`.gitignore:66-67` 与 `.zcodeignore:70-71` 的 `engine/bindings/swift/{Frameworks,.build}/`
    四条在 INFRA-032 之后指向**不存在的目录**（027 当时为"搬迁期两边都留着"故意保留）。本卡删除旧四条，
    只留 `api/swift/**` 形式；判据 = `git check-ignore -v` 对 `api/swift/Frameworks/ChuanqiCut.xcframework`
    仍命中新规则，且 `git status --porcelain` 在搬家后依旧无未忽略产物。
  - `tools/ci/check_repo_hygiene.sh` 能一次跑完上述四条并给出退出码，且被 ci.yml 调用
  - **INFRA-030 遗留的平铺旧引用清零**（只认活文件域）：
    `git ls-files -z engine .ai docs/specs README.md docs/BUILD.md .agents/skills | xargs -0 grep -nE "tests/unit/[a-z_0-9]+\.(cpp|c)"`
    命中数 = 0（平铺形式即缺模块段）。搬家前基线实测 **37 行 / 去重 36 处 / 13 个文件**（2026-10-16：
    `.ai/modules/core.md` 7、`media.md` 6、`.ai/memory/pitfalls.md` 5、`platform-apple.md` 3、
    `docs/specs/PLATFORM-接口契约.md` 3、`platform.md` 2、`session.md` 2、`.ai/memory/baselines.md` 2、`gfx.md` 1、
    `engine/**` 5 处注释 + `engine/bindings/swift/Sources/ChuanqiCutCore/include/cq_sdk.h`（symlink，与 cq_sdk.h 同一处）。
    **INFRA-030 执行后追加一条**：仓库根 `CMakeLists.txt:14` 注释里的 `tests/unit/test_c_abi.c`
    → `tests/unit/abi/test_c_abi.c`（基线随之为 38 行 / 去重 37 处 / 14 个文件）。
    替换目标按 030 的分组表逐个对，**改前先确认文件真在新目录里**：这些引用里混有 brace 展开形式
    （`test_{time,status,log,alloc}.cpp`）与"符号限定"形式（`test_time.cpp::TestOverflowBoundary`），不能机械替换。
    `engine/core/cq/cq_sdk.h` 属高冲突文件，只在本卡（集成机末批）改。
    豁免域（红线 5 不回填）：`docs/{decisions,research,reports,handoff,reviews,tasks}`、`.workbuddy/memory`。
  - **修掉 P145**：`run_gate.sh` 的 `print_summary()` 不得再读上一次遗留的同名日志。
    判据（可机器验）：中途 `kill` 掉门禁后摘要里**不出现任何未执行 step 的行**；
    正常跑完时摘要行数 = `PASS+FAIL+SKIP` 计数之和。实现方式：每个 step 起始处 `: > "$log"` 截断，
    摘要只遍历本次真正进入过 `run_step`/`if` 分支的 step 列表。
  - **linkcheck 存量断链分类处置**（INFRA-035 收口时记的"6 条"到 INFRA-032 收口时**实测已是 9 条**，
    多出的 3 条全部来自治理文档自己：`TASK-BACKLOG.md:567`、本卡 :90、`TASK-INFRA-035.md:70`）：
    根因是 `linkcheck_docs.py:22` 的 `BACKTICK_PATH = re.compile(r"`([^`\s]+\.md)`")` 把
    **反引号里"作为讨论对象的死路径"也当成可导航的链接**。本卡列的处置清单本身就是这种讨论 ——
    照现在的判据"断链数 < 6"**永远达不成**（越写清单越红）。
    两条路二选一并写进 checker 注释：① checker 按域豁免 `docs/{tasks,reports,handoff}`（这些是
    append-only 叙述域，不是导航面）；② `BACKTICK_PATH` 只在"看起来像指路"时才判定（例如同段有
    `→`/`见`/`link` 语义，或直接取消反引号判定、只查 `[..](..)`）。
    **修完 checker 后的真实存量**才是下面这几条，逐条判定：
    `docs/specs/PAL-接口契约.md`（ADR-0035 已把它改名 `PLATFORM-接口契约.md`，纯路径修正 → 可改）、
    `docs/reports/LEDGER-W42.md`（RESEARCH-011 全名变更、ADR-0011 已改名，同属纯路径修正）、
    `docs/handoff/HANDOFF-021`（指向**从未存在**的 `TASK-EDIT-007/008.md`，不是搬家造成的 ——
    **不得改号或造文件**，只在 `docs/README.md` 或模块册登记"该引用无效"）。
    判据改为：**checker 修完域豁免后**，`python3 tools/ai/linkcheck_docs.py` 断链数 ≤ 6，
    且 `docs/tasks/**` 不再出现在命中列表里（P146 之外的口径：判据取条数，退出码恒 0 不可信）。
  - **P146 的覆盖面评估**（本卡决定是否机械化）：`build_core.sh --platform=apple` 只出 macOS 切片，
    `engine/platform/apple/**` 里被 `#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE` 包裹的代码
    （例：`audio_engine.mm:212-271` 的 `RegisterSessionObservers`）**从未进过 core-dbg/core-rel**，
    b471b8c 因此带着"门禁绿、iOS 编不过"入库。两个候选：
    (a) 在 `run_gate.sh` 的 core 段之后加一步 `build_core_apple.sh --config=Release`（与 apple-xcframework 重复，但提前暴露）；
    (b) 加一个只编译不链接的 iOS-device 窄检 target。**先测时长**再定，选 (b) 不得把单次窄检推过 3 分钟。
verification:
  - CMAKE_BIN=$(command -v cmake) tools/build/build_core.sh --platform=apple 2>&1 | tail -10
  - bash tools/ci/check_repo_hygiene.sh; echo "exit=$?"
  - git ls-files tools/qa tools/probe
risk:        .clang-format 一旦"顺手全量格式化"就是把 300+ 文件塞进布局整改批，diff 淹没真实改动、
             并与所有在途业务卡冲突 —— 本卡明确只落配置与基线数字，重排另开卡分批。
             CI 的真实风险是把不可验证的远端状态写成本机已验证（P82/ADR-0030 反复强调）。
parallel:    false（末批，依赖全部前序批的稳定路径）
```

## 背景

RESEARCH-011 §3 的 F（无 CI）、G（无 .clang-format/.editorconfig）、H（活文档里的机器绝对路径）三项
在 10-11 P2 时未执行，本轮复勘确认仍未动：`.github/workflows/` 只有一个 `.gitkeep`。
另外 `tools/probe/`（真机远程验证 SOP + 2 个脚本）与 `tools/qa/`（beauty_harness）职责重叠，
顶层 `tools/` 因此多出两个语义相近的小目录；`tools/perf/` 保留独立（perf 与 probe 不是一回事）。

## 实现要点

- CI 只跑**不需要真机/不需要 Xcode 壳**的那一段（core 编译 + ctest + hygiene），
  双壳构建与真机仍归集成机阶段批（ADR-0030），不在 CI 里造假绿。
- 路径回填的判定标准是"**这份文档会不会被人/机器当命令执行**"：会 → 改；是历史记录 → 不改。
- `check_repo_hygiene.sh` 是本卡留下的防复发工具：忽略规则锚定、活文档旧路径、入库产物三条都做成退出码。
  ⚠️ **旧路径检查必须走 `git ls-files`（或至少 `grep -I`）**：INFRA-032 实测裸 `grep -r engine/bindings apps/`
  命中 `xcworkspace/xcuserdata/…/UserInterfaceState.xcuserstate`（已忽略的本机二进制，永远清不掉），
  直接把该条判据变成恒假 → 脚本会因噪声红，然后被人加 `|| true` 废掉。判据只认入库文件。
- `run_gate.sh` 属高冲突文件（031/032 也写它），故 print_summary 的修复排到**末批**（本卡 deps 已含 031/032），
  避免与包路径迁移撞同一文件。

## 验收

见 yaml；CI 项必须写"本机以 `CMAKE_BIN=$(command -v cmake)` 复现通过"，
远端 workflow 首跑结果单独标注（未跑成就是未跑成）。

## 回写

- `.ai/memory/pitfalls.md`：若回填过程中发现旧路径写进了 append-only 记录，按 P103 只加不改
  → 实落 **P160 / P161 / P162**（2026-10-17 追加，P160 含四条构建期依赖规则 + 大小写陷阱第五条）
- `.ai/modules/core.md`：clang-format 违规基线数字 → 另加 2026-10-17「干净复现四遍」行
- `.ai/modules/shader.md`：SHADER-001 构建期依赖出树 + P162 幂等/只读自证两行
- **新增 ADR-0045**（卡原文没有这条，是 P160 之后必须补的）：
  `docs/decisions/ADR-0045-构建期依赖必须入库产出与门禁缓存状态口径.md` + `docs/README.md` ADR 索引行。
  内容 = 构建期依赖必须有入库产出脚本 / 交付判据必须含"清空产物根重跑" / 引用"门禁绿"必须标注缓存状态 /
  CI 装配步顺序 / 幂等四硬规则。**没有升为 `AGENTS.md` 红线**（真源是热点文件，本批已因红线 #6 动过），
  理由与边界写在该 ADR 末节。
- 日志 → `.workbuddy/memory/2026-10-16.md` 与 `2026-10-17.md`；本卡是整改批的收口卡，收工前按 AGENTS 8 项清单逐项勾

## 实测（本机 = 集成机，2026-10-16 23:31~23:5x，Intel x86_64 / macOS 26.7.1 / Xcode 26.6 / cmake 4.4.3）

### 全量门禁（17 步，`tools/ci/run_gate.sh`）

**PASS=17 / FAIL=0 / SKIP=0，exit 0，墙钟 10m57s**（23:31:05 → 23:42:02）。
步数由 15 → **17**：新增 `api-doc`、`ios-compile`；原内联 `artifacts` 一步并入 `hygiene`（判据只留一份）。

| 步 | 数字 |
|---|---|
| deps | `manifest.toml` 7 条校验通过 |
| headers | `scanned 43 header(s) … 0 violation(s)` |
| hygiene | 4/4 PASS（详见下节） |
| layer-hygiene | 两趟 119 文件，R1 违规 0 |
| api-doc | `gen_api_reference.py --check` exit 0（全文比对） |
| ios-compile | iOS-device 切片只编译 `cq_core`+`cq_platform_apple` PASS |
| core-dbg | **52/52**，78.96s（`-Werror`） |
| core-rel | **52/52**，74.55s |
| apple-xcframework | 三切片齐，`macos-arm64_x86_64/libChuanqiCut.a` 双 arch，`ok: library links and runs` |
| 包测试 | bindings **26** / player **52** / camera **77** / import **16** / editor **81** = **252**，0 失败（与 P148 基线逐字相等）；sharedui = `swift build`（无测试，摘要留空不猜） |
| golden | `built_ok=21 / built_fail=0 / unbuilt=0 / 901784 B` |

### P145（摘要读遗留日志）修复 + 负向测试

- 实现：开跑 `rm -f build/gate-logs/*.log` + 每步起始 `: > "$log"` 截断 + 摘要**只遍历
  `SUMMARY` 数组**（`record()` 是 PASS/FAIL/SKIP 的唯一出口）。
- **负向测试**（可机器验）：`PYTHON_BIN=/bin/ls tools/ci/run_gate.sh --fast` 强制第 1 步红 →
  真实 exit **1**、摘要 `PASS=0 FAIL=1 SKIP=0 （行数 1）`、**后面 16 个 step 一行都不出现**；
  跑后 `ls build/gate-logs/` 只剩 `deps.log`（预置的三条遗留 `apple-editor/apple-player/core-rel`
  日志在开跑即被清空 → 两层防御都取到证）。
- 正常路径判据：本次 17 步 = 行数 17 = `PASS+FAIL+SKIP` 之和 ✅。
- 顺带修摘要数字口径：`apple-*` 改取 `Executed N tests, with M failures` 这行（原来取
  `Test Suite … passed at <时间戳>`，摘要里只有时间戳没有数字）。

### P146（iOS 分支从不参与编译）决策 = 候选 (b)，实现成新脚本而非 CMake target

- 覆盖面缺口取证：同一份 `audio_engine.mm` 的 `RegisterSessionObservers` 符号数
  `nm -a`：**ios-device 4 / ios-sim 3 / macos 0**。
- 候选 (a)（core 段后提前跑 `build_core_apple.sh`）**实测冷 8m20s** → 否决：超本卡 3 分钟口径，
  且与后面的 `apple-xcframework` 是同一份活，只是把重复劳动提前。
- 候选 (b) 落地 = `tools/ci/check_ios_compile.sh`：复用 `build_core_apple.sh` 自己已有的
  `build/apple/ios-device` 缓存，`cmake --build … --target cq_core cq_platform_apple`（只编译、
  不 libtool / 不 xcframework / 不签名）。**暖机 2~6s**，冷机 `--prime` 走 `build_core_apple.sh`。
- **负向测试**：往 `#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE` 段内注入语法探针 →
  脚本 `FAIL（rc=2）`、exit 1；撤销后文件 md5 与注入前逐字节一致（`819f1bc72e99c61100bfd4bd712258d1`）。
- ⚠️ **写集偏离登记**：本卡原文写"加一个只编译不链接的 iOS-device 窄检 **target**"。实现改成
  独立脚本，理由是加 target 必须动 `engine/platform/apple/CMakeLists.txt`（高冲突文件、且属
  platform 线写集）；脚本形态的判据与代价等价。P158 记的是本步实现里踩到的 `$?` 坑。

### 接口文档入门禁（P151）

- `docs/api/engine-api.md`：516 → **538 行**，95 个 ```c 块、**11** 个 `###` 子节、9 个 `##` 大节
  （符号 103，无消失）。
- 生成器修的是**静默失配**：旧 `SUB_RE` 只认单行同尾锚点，而本仓 11 个子节锚点全是
  "标题贴结尾横线"或三行框式 → **命中 0**，103 条声明被出成 10 节孤立代码块。改成
  `SUB_INLINE_RE` + `SUB_FRAMED_RE` 两条并列，并加 `(?=[^\s\-])` 前视防把纯横线当标题。
- **负向测试**：往 `cq_sdk.h` 加一条声明 → `--check` exit 1（全文比对，不是符号集合比对）；
  删除后 exit 0。探针已从 `cq_sdk.h` 完全移除（`grep -rn hygiene_negative_probe` = 0 命中）。

### 仓库卫生四条（`tools/ci/check_repo_hygiene.sh`，exit = 失败项数）

`4/4 PASS`：
1. **ignore-anchoring**：9 条正探针（含 `/build/`、`tmp*/`、`Pods/`、`engine/vendor/`、
   `api/swift/Frameworks/`、`ui/*/.build/`、`apps/apple/*/build/`）全部按**声明行号**命中，
   5 条负探针（`tools/ci/run_gate.sh`、`engine/shaders/portable/blit.vert`、两份 `Package.swift` 等）
   必须不被忽略；另有死规则扫描（规则的字面目录前缀必须真实存在）。
2. **legacy-paths**：判据只认 `git ls-files -z`（P155），含迁移标记（`原 `/`已迁`/`→`/`作废`…）
   的行豁免 —— 实测 **33 行豁免、非豁免 0**。
3. **tracked-artifacts**：tracked **856** 个文件，构建产物 **0**。
4. **editorconfig**：CRLF / 行尾空白 / 末行换行 / tab 四条件**全零命中**。
   唯一为凑判据改的文件是 `docs/handoff/HANDOFF-024-…md`（补一个末尾换行，whitespace-only）。
   INFO（不判红）：clang-format 违规 **79/115**。

### 死忽略规则清理 + 平铺引用清零

- `.gitignore` / `.zcodeignore` 各删 2 条 `engine/bindings/swift/**`（自 032 起指向不存在目录）
  与仓库根那对 `shaders/generated/`（自 033 起出树）。取证：
  `git check-ignore -v` 对 `api/swift/Frameworks/ChuanqiCut.xcframework/x`、`api/swift/.build/x`、
  `engine/shaders/generated/x` 分别命中 `:66`、`:67`、`:45` 三条**新**规则。
- 本卡 `tests/unit/<平铺名>` 判据实测：卡上 grep（engine / .ai / docs/specs / README.md /
  docs/BUILD.md / .agents/skills / 根 CMakeLists）**命中 0**（基线 38 行 / 37 处 / 14 文件 → 清零）。

### linkcheck 存量断链（选项 ①：checker 按域豁免）

- 修 checker 前实测 **10 条**命中，且 **10/10 全部落在叙述域**（decisions/research/reports/
  handoff/reviews/tasks/archive + `.ai/memory`）→ 照旧判据"断链数 < 6"永不可达（越写清单越红）。
- 落地：`BACKTICK_PATH` 判定跳过叙述域；`[..](..)` 真链接仍全库判。修完 **0 条**，`exit 0`
  （判据要求 ≤6，超额达成）。
- 顺手消掉一条**自己造出来的**命中：`docs/README.md` 是导航面，登记"该引用是合写简写不是断链"
  时若把死路径写成 `` `docs/tasks/…` `` 就会被自己的判据判红 → 改为**只写文件名不带 `docs/` 前缀**，
  并把这条口径写进正文（讨论死路径请放 `docs/tasks` 等叙述域）。
- 结论纠正：本卡原写 `HANDOFF-021` 指向"**从未存在**的 `TASK-EDIT-007/008.md`" 是**未核磁盘的推断**。
  实测 `docs/tasks/TASK-EDIT-007.md` 与 `TASK-EDIT-008.md` **两份都在**，那行是两卡的合写简写
  → 不改历史交接文档，只在 `docs/README.md` §六 登记实测结论。

### 代码风格两份配置

- `.clang-format`：BasedOnStyle Google + `IndentWidth 4` / `AccessModifierOffset -4` /
  `ColumnLimit 0` / `ReflowComments false` / `DerivePointerAlignment true` / `SortIncludes false`。
  每一条都是**实测挑出来的**：`AccessModifierOffset` 取 -4 时违规 69，取 0/+4 时 79；
  开 `SortIncludes` 违规 69 → 73/74（会打散手工分组）。
- `.editorconfig`：629 个入库文本文件实测最常见缩进列（C/C++/ObjC++/Swift/Python/Shell = 4，
  json/toml/yml/podspec = 2，md 列表嵌套 = 2）；`[*.md] trim_trailing_whitespace=false`
  （行尾两空格是硬换行语义）；pbxproj/plist = tab 且**不带**末尾换行（Xcode 生成物实测）。
- 两者口径一致：4 空格、LF、末尾一个换行、不设列宽。落地时**只做基线不做红闸**，
  违规基线写进 `.clang-format` 头部与 `.ai/modules/core.md`。

### Apple 双壳（P129 配方，本批末批统一跑）

| 端 | pod install | xcodebuild |
|---|---|---|
| ios | `bundle exec pod install` **rc=0**，"There are **14** dependencies from the Podfile and **14** total pods installed" | `-workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS` → **BUILD SUCCEEDED**，`error: 0` / `warning: 24` 行 |
| mac | 同款 **rc=0**，**7** dependencies / **7** pods | `-scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES`（**不带 `-destination`**，两者冲突）→ **BUILD SUCCEEDED**，`error: 0` / `warning: 11` 行 |

- **产物非空壳取证**（P149）：ios App 包内 `beauty_bilateral.metallib` **9215B** /
  `face_warp` **5792B** / `beauty_guided` **8118B**，时间戳 23:45:04 = 本次构建，三个数字与
  INFRA-031 基线逐字节相等。
- **033 搬家在壳里真实生效取证**：壳的 `[CP-User] SHADER-001` run-script 每次构建都跑（xcodebuild
  为此告警"does not specify any outputs"），本次把 `build/generated/shaders/blit_msl.h`
  重写成 **1689B** —— 与 033 记录的搬家后数字一致 → 壳吃的确实是 `engine/shaders/portable/` 那份。
- ⚠️ **warning 行数不是稳定指标**（032 记 mac 6 行、本次 11 行）：增量编译决定重编多少 TU，
  告警只对已重编的 TU 出现。本次 11 行逐条分类全是既有项（`-Wdocumentation-html` 4、
  `sd`/`nb_sd` doc 参数 2、headermap、duplicate build file、SHADER-001 run-script、
  DVTDownloads 搜索路径、AppIntents metadata），**零 error、零新增类别**。
- **踩坑**：非交互 shell 里 `LANG`/`LC_ALL` 未设 → CocoaPods 在 `unicode_normalize` 崩，
  两端 `pod install` 各 `rc=1` 且日志只有 ruby 栈（第一眼看像 Podfile 写错）。已在脚本里
  显式 `export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` 后跑通 → 登记 **P159**。

### CI core 段本机复现（判据"连续 2 次绿 + 日志能看到排除名单"）

复现脚本按 workflow 顺序逐字搬：`rm -rf build` → `CMAKE_BIN=cmake tools/build/build_shader_toolchain.sh`
→ `CMAKE_BIN=cmake tools/build/build_core.sh --platform=apple --config=Debug` → `ctest -N` **打印排除名单**
→ `ctest -E platform_apple_decode` → `check_repo_hygiene.sh`。`CMAKE_BIN=cmake` 靠把
`$HOME/.workbuddy/binaries/cmake/.../bin` 塞进 PATH 实现（本机 cmake 不在 PATH），等价于 runner 的系统 cmake。

| 遍 | 脚本版本 | toolchain | build_core | ctest | hygiene |
|---|---|---|---|---|---|
| run1 | 大小写修正**前** | rc=0 | rc=0 | rc=0 **51/51** 186.74s | — |
| run2 | 出参目录小写版 | rc=0 | rc=0 | rc=0 **51/51** 172.84s | rc=0 |
| run3 | + SPIRV-Cross 横幅本地补丁 | rc=0 | rc=0 | rc=0 **51/51** 271.32s | — |
| run4 | **P162 修复后的交付版** | rc=0 | rc=0 | rc=0 **51/51** 83.52s | rc=0 |

- **四遍都打印排除名单**：`Test #45: platform_apple_decode`。判据要"能看到被排除的用例名单"，
  所以显式跑 `ctest -N | grep` 取证，**不靠 `-E` 静默少跑**（少跑与跑绿在日志里长得一样）。
- 干净单遍 **6m48s ~ 11min**（run4 整段 09:42:02→09:48:50；run2 段 09:16:03→09:25:30 含 hygiene）。
  ⚠️ **ctest 墙钟四遍为 186.74 / 172.84 / 271.32 / 83.52s**，同是 51/51 全过却差 3 倍以上
  → 本机 ctest 墙钟**不可当指标**，可比的只有 rc 与通过数（run3 慢是因为三遍连打、机器持续满载）。
- **判据"连续 2 次绿"由 run3 + run4 满足**（run4 = 最终交付版；run1 用的是大小写修正前的脚本，
  单独标注，不计入交付版证据）。
- **第一次尝试（`build_core.sh --clean`，未装工具链）就是红的**，且红得有价值：
  `build rc=2` → `make[1]: *** [engine/platform/apple/CMakeFiles/cq_shaders_msl.dir/all] Error 2`，
  随后 `ctest rc=8`、`2% tests passed, 50 tests failed out of 51`，50 个失败全属
  `Could not find executable` → **构建期第三方工具（glslang / SPIRV-Cross）只存在于本机暖缓存，
  仓库里没有任何脚本产出它**。登记 **P160**，修复主体 = 新增 `tools/build/build_shader_toolchain.sh`
  （pin 从 `third_party/manifest.toml` 读，脚本不写死 commit）+ `ci.yml` 在内核构建**之前**加装配步。
- ⚠️ **判据证据等级要写清**：17 步全量门禁的 `PASS=17` 与本表**不是同一口径**。门禁从不删
  `build/tools/`，所以"构建期依赖齐不齐"这一层**从未进入 17/17 的判据** —— 10-16 之前所有"绿"
  都只是**暖缓存证据**（baselines 已把这条写成新口径）。
- **负向测试又抓到交付版脚本自己的两个缺陷（P162）**：`--check-only` 名义只读、实际会走 `rm -rf`
  分支；补丁指纹守卫拿 `SPVC_PATCH_FP:STRING=` grep，而裸 `-D` 在 cache 里落成 `:UNINITIALIZED=`
  → **恒不命中** → 每次暖跑误判"补丁变了"、白删白重编。两处已修并复验：
  暖态完整跑 = 两个工具都 `产物已存在，跳过编译`、"强制重编"零行；
  暖态 `--check-only` = 两产物 `OK` 且 `spirv-cross` md5 跑前后逐字节一致；
  藏掉 `glslang` 后 `--check-only` rc=**1**（报 `产物缺失`），恢复后 md5 一致、正向 rc=**0**。
- 本机**没复现**的一步：workflow 里的 **FFmpeg 装配**（本机走 `third_party/prebuilt/` binary 模式）。
  远端首跑状态仍标"未验证"。

## 本卡改过/新增的活文档（回填判定 = "会不会被下一个人当命令或事实读"）

- **P160 的后续新增（卡原文没有这一项，因为是复现 CI 时才暴露的）**：
  `tools/build/build_shader_toolchain.sh`（新，可执行）、`.github/workflows/ci.yml` 的装配步与
  第 4 条写死约束、`docs/BUILD.md` 新增「构建 shader 工具链」小节（含 `--check-only` 只读口径、
  产物字节数、"必须在 `build_core.sh` 之前"的顺序约束、症状"`ctest` 50/51 Could not find executable"）、
  `.ai/modules/shader.md` 落地状态行与门禁记录、`.workbuddy/memory/MEMORY.md` 新增
  「构建期依赖铁律（P160）」节、`docs/handoff/HANDOFF-025-*.md`（本批收口交接）、
  池 [22]/[23] 两条。

- `README.md`（仓库根）：3 处 `shaders/src/`（:16/:184/:389 目录树）改到 `engine/shaders/portable/`；
  §5 门禁表补本批行；"顺延/待定"里的 P3 工程规范五件按实际勾掉三项。
- `docs/README.md`：:136 接口参考行**双重过期**修正（`engine/bindings/swift/Sources/CChuanqiCut/…`
  → `api/swift/Sources/ChuanqiCutCore/include/cq_sdk.h`）；§六 补"核过的失效引用"；
  §八 登记 `check_repo_hygiene.sh` / `check_ios_compile.sh` / `gen_api_reference.py` 三个新入口。
- `docs/COCOAPODS.md`：目录树与"两个本地 spec 同目录"叙述按三次搬家重写（pod 根 = `api/swift/`，
  `ChuanqiCutCore`/`ChuanqiCutFFmpeg` 仍在 `engine/`）；旧 4 处 `packages`/`bindings/swift` 字面清零。
- `docs/BUILD.md`：`build/` 分区三条纪律（cmake 留根、禁新具名散目录、双 scratch 不并存）。
- `docs/specs/`：`ARCH-003` :88 架构图框名与 :130 规范句改到 `engine/shaders/{portable,native}/`；
  `ARCH-005` §6 工程结构树整段按 ADR-0044 重写（172 行）；11 份 spec 的 :4 回填横幅由 031/032 批已挂。
- `docs/CODESTYLE.md` §5：删掉"`­.clang-format` 待引入（INFRA-012）"这句**已过期**的话，
  改成落地状态 + 基线数字 + "只报不判"口径；⚠️ 本卡写集原文未列 `docs/CODESTYLE.md`，属**收口时补入**
  （理由：它声明自己是"代码风格唯一标准"，`.clang-format` 落地后不同步就是两份真源）。
- `.ai/modules/`：`core.md` 补代码风格基线节与门禁记录行；`platform.md` / `preview.md` 两处
  指向**仓库里根本不存在**的 `platform/apple/shaders/blit_fullscreen_msl.h` 的死引用改成
  "构建期产物 `build/generated/shaders/blit_msl.h`（源 = `engine/shaders/portable/blit.{vert,frag}`）"，
  同时把 `blit_pass.mm` / `frame_provider_apple.mm` 补上 ADR-0033 之后的 `gfx/`、`media/` 段；
  6 处 `CMAKE_BIN=/Users/zhuning/...` 改 `"$HOME/.workbuddy/..."`（H 项：活文档里的机器绝对路径）。
- engine 侧注释：`cq_sdk.h`、`cq_sdk.cpp`、`base/chq_status.h`、`platform/chq_capabilities.cpp`、
  `platform/apple/gfx/gfx_metal_internal.h` 的 `tests/unit/<平铺名>` 引用全部回填到模块子目录。

## 未做与登记（不做假绿）

- `CODEOWNERS` 未落（P3 五件剩这一件）—— 需要传哲给各模块归属人的 GitHub 用户名，属决策不是施工。
- **远端 workflow 首跑未验证**：本卡只给"本机等价复现"证据（见上节「CI core 段本机复现」），GitHub Actions 上
  的真实首跑要等本批 push 之后；在那之前 `ci.yml` 的状态是"本机复现绿、远端未跑"。
  CI 里唯一没在本机复现的是 **FFmpeg 装配步**（本机走 `third_party/prebuilt/` binary 模式，
  CI 走浅 clone + `build_ffmpeg_demux.sh` 源码模式）。
- **P160 只修到"本机可从零装配"，pin 级校验仍有一道口子**：`third_party/src/{glslang,SPIRV-Cross}`
  是历史会话手搓的**非 git 树**，脚本只能做版本级核对并明打"commit 级 pin 不可校验"。
  CI / 新克隆机走的是按 `pin_ref` 浅 fetch 的 git 树，那一路才有 `HEAD == pin` 的硬判据。
  - **2026-10-17 追加（INFRA-045 收尾批）**：传哲对本条判「**本批不管，继续挂着**」。
    所以 `ci.yml` 的状态**仍是**"本机复现绿、远端未跑"，不要有人替它改口。
    本机 `gh` **未安装**（`command -v gh` 空），连远端 run 状态都取不到 —— 想验要么在有 `gh` 的机器上，
    要么由人在 Actions 页面看，别把"看不见"写成"通过"。
- **池 [22]**（append 进 `TODO-POOL-门禁真机待办池.md`）：仍有 **90** 个 tracked 文件使用生成前的旧路径
  `engine/core/cq/**`→`core/include/cq/**` 形式，`check_repo_hygiene.sh` 的 legacy-paths 判据**看不到这一类**
  （它只扫已登记的字面）。修法只能逐文件，**禁止批量替换**（P156 的案底就是这个），改完再扩 pattern 列表。
- **池 [23]**：本机 `third_party/src/SPIRV-Cross/CMakeLists.txt` 带着一个**不入库的本地补丁**
  （把 `git describe` 在非 git 树里向上抓宿主 HEAD 造成的"假归属版本横幅"改成 manifest pin），
  并用 `SPVC_PATCH_FP` 当 cache key 让补丁一改就自动强制重编。CI 走的是**未打补丁的上游树**。
  ⚠️ 这是"本机与 CI 源码不完全同源"的既成事实，**待传哲判定是否接受**；不接受则按池里写的替代路走
  —— 本机也**始终**按 pin 做 `git checkout`（`ensure_src` 已有该路径，代价 `third_party/src/` 重取
  约 25~40s/仓），补丁随之作废。
- clang-format 全库重排**没做**，按本卡风险条另开卡分批（166 个文件的 cosmetic diff 不能塞进布局批）。
  → **2026-10-17 由 [TASK-INFRA-046-全库clang-format重排.md](TASK-INFRA-046-全库clang-format重排.md) 做掉**：
  本卡那个 **166** 是"扫到的文件数"（engine 105+10 + tests 51），**违规数**是 engine **79/115** + tests **34/45**；
  实排 **113** 个文件（166 里本来就有合规的，vendor 不入库所以碰不到）。现状全库违规 **0/168**。
- 池 [20]（TimelineKit 在仓库外、iOS 轨道区依赖不可复现本地路径）本批判定**不收编**，
  仍留在池里待传哲拍板；池 [18]（把双壳纳入门禁）本卡只做到"iOS 切片只编译"这一半，
  壳构建（约 10min×2）仍未进门禁。
