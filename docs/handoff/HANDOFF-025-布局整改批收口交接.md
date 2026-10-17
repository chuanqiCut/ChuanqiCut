# HANDOFF-025：仓库布局整改批（INFRA-026~035）收口交接

- 日期：2026-10-17（跨零点，实作从 10-16 晚续到 10-17 早）
- 交接人：WorkBuddy（模型）
- 拍板人：传哲
- 关联：ADR-0044（顶层布局）、RESEARCH-018（RESEARCH-011 的复勘 delta）、BACKLOG §15、
  TASK-INFRA-026 ~ 035（十张卡，其中 027/028 合一执行）
- 本批新增坑号：P150 ~ P161（`.ai/memory/pitfalls.md`），其中 **P160 是本批最贵的发现**
- 本机前提：集成机，macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / **Intel x86_64** / 无 Homebrew /
  cmake 4.4.3 不在 PATH（`$HOME/.workbuddy/binaries/cmake/CMake.app/Contents/bin`）

---

## 一、状态：**整批仍未 commit，等传哲一句话**

传哲的指令是「做完」= 033、034 都做完后整批一起提。**判据完成 ≠ 已提交**：

- 索引现状（`git status --porcelain` 分类计数，本文件写完时实测）：
  **245 R / 83 M / 41 RM / 22 ?? / 3 D / 2 A**。
  `R` 占大头是搬家批的本征形状（`git mv` 保留历史），不是"改了很多内容"。
- 22 个 `??` **全是**本批新增文件，逐个点名（提交时一个都不该漏）：
  `.clang-format`、`.editorconfig`、`.github/workflows/ci.yml`、`docs/archive/README.md`、
  `docs/decisions/ADR-0044-*.md`、`docs/decisions/ADR-0045-*.md`、`docs/research/RESEARCH-018-*.md`、
  `docs/handoff/HANDOFF-025-*.md`（本文件）、`docs/tasks/TASK-INFRA-026.md ~ 035.md`（十张）、
  `tools/build/build_shader_toolchain.sh`、`tools/ci/check_ios_compile.sh`、
  `tools/ci/check_repo_hygiene.sh`、`.workbuddy/memory/2026-10-17.md`（当日日志，历史上日志都入库）。
- ⚠️ **全批只有一处"非注释"的源码改动**：`engine/platform/apple/media/audio_engine.mm:252`
  未用形参 `note` → `/* note */`。**它是 P146 的存量红**（函数整段在 `#if TARGET_OS_IPHONE` 里，
  macOS 切片编不到 → core-dbg/core-rel 一路绿、只有 xcframework 段红；引入者 `b471b8c`），
  由本批新增的 `ios-compile` 步第一次编出来。提交说明里请单独点出这一行，别混进"布局批零代码改动"的叙述。
- 分支规矩（AGENTS「提交」）：`<person>/<task-id>-<slug>`，一个任务一个 PR。整批合一提时
  **建议按三段拆**，否则 244 个 `R` 会把真实改动淹掉：
  1. `git mv` 移动集（0 内容改动的 `R100` 为主体）；
  2. 治理新增（CI / 两个配置文件 / 三个新脚本 / `.gitignore` 锚定）；
  3. 活文档跟随（README/BUILD/CODESTYLE/模块册/skills）。
  拆与不拆由传哲定，**不要擅自 squash**。
- ⚠️ **保险提交 `11152db1`（"pre-032 insurance"）仍在本地历史里**，不推远端、不作为交付。
  它救过一次事故（P157：`git checkout --` 把 ARCH-005 的 030/031/032 批改动整段抹掉，
  靠它按 blob 取回）。收口时按传哲意思 `git reset` 或 squash 处理，**处理前先确认工作区干净**。

## 二、落定的顶层形状（接手时按这个找文件）

| 顶层 | 内容 | tracked 实测 |
|---|---|---|
| `engine/` | `core/`（头与实现共置，`cq/` 下按域）+ `platform/` + `shaders/{portable,native}/` + `vendor/` + 两个 podspec | **127** |
| `api/swift/` | Swift 门面（原 `engine/bindings/swift/`）+ `ChuanqiCutEngine.podspec` 的 pod 根 | **25** |
| `ui/` | 六个 Swift 包（Camera / Draft / Editor / Import / Player / SharedUI），扁平，保留 `ChuanqiCut` 前缀 | **124** |
| `apps/apple/{ios,mac}/` | 只剩两端原生壳（Podfile + xcodeproj） | 48 |
| `tests/unit/<模块>/` | 12 个模块子目录 / **51** 文件（**ctest 用例名一律没动**，仍 52 条） | — |
| `tests/golden/` | 含新迁入的 `edit_plan/`（**59** 个夹具，原在 `engine/core/cq/ai/plan/`） | — |
| `third_party/prebuilt/` | 第三方产物归口（不入库） | — |
| 产物根 | 唯一临时产物根 `build/`，分区：`build/spm/<包>`、`build/xcode/`、`build/gate-logs/`、`build/tools/` | — |

- 总 tracked **856**（027~033 各批守恒在 857，034 因删除死忽略规则与新增文件在此值上下浮动；
  引用时用 `git ls-files | wc -l` 现测，别抄本行数）。
- **旧路径在磁盘上必须为 0**：`git ls-files shaders ai/plan tools/probe engine/bindings` 全 0。
- CocoaPods 硬耦合（ADR-0044 §2 记录，别当洁癖问题）：pod 根 = podspec 所在目录，
  `source_files` 是**pod 根相对**路径，所以 Engine podspec 必须与 `Sources/` 同层，
  `engine/` 里才留了 `ChuanqiCutCore.podspec` / `ChuanqiCutFFmpeg.podspec` 两个壳。

## 三、门禁数字（本机 = 唯一验收口径）

**全量门禁 `tools/ci/run_gate.sh` = 17 步，PASS=17 / FAIL=0 / SKIP=0，墙钟 10m57s（暖缓存）**
（步数从 15 → **17**：加 `api-doc`、`ios-compile`，原内联 `artifacts` 并入 `hygiene`）。

| 项 | 数字 |
|---|---|
| 内核单测 | Debug **52/52**、Release **52/52** |
| Swift 包 | bindings 26 + player 52 + camera 77 + import 16 + editor 81 = **252**，0 失败 |
| 头纯净性 | `scanned 43 header(s) … 0 violation(s)` |
| 图层卫生 | 两趟 **119** 文件，R1 违规 **0** |
| golden | `built_ok=21 / built_fail=0 / unbuilt=0 / total_bytes=901784` |
| 仓库卫生 | `check_repo_hygiene.sh` **4/4 PASS**（旧路径 raw 命中 23 行**全部**带迁移标记，非豁免 0） |
| 接口参考 | `gen_api_reference.py --check`：`docs/api/engine-api.md` 538 行 / 103 符号 |
| 文档链接 | `linkcheck_docs.py` **0** 命中（修 checker 前 10 条，全落在叙述域） |
| 双壳 | ios 14/14 pods + **BUILD SUCCEEDED**；mac 7/7 + **BUILD SUCCEEDED**；
  壳内 metallib `9215 / 5792 / 8118 B` 与 031 基线逐字节相等（P149 反例是 96B 空壳） |

数字逐条在 `.ai/memory/baselines.md` 的「2026-10-16 · INFRA-034」节与
`docs/tasks/TASK-INFRA-034.md` §实测。
⚠️ **这 17/17 是暖缓存证据**（门禁从不删 `build/tools/`）—— 干净复现的证据在下一节，两套数字不可互替。

## 四、本批最贵的发现：P160（构建期依赖只活在暖缓存里）

为了交出"CI 可用的本地等价证据"，按 workflow 顺序**真的清空 `build/`** 复现，结果直接炸：

```
[ 27%] SHADER-001: glslang → SPIR-V → spirv-cross → MSL (blit)
error: shader 工具链不可用（试过：…/build/tools/glslang/StandAlone/glslang）
→ ctest rc=8，2% tests passed, 50 tests failed out of 51（全是"找不到可执行文件"）
```

根因：**`tools/shaders/build_shaders.py` 编译期硬要两个二进制，而仓库里从来没有产出它们的脚本**
（`deps.py` 无 build 子命令、`tools/CMakeLists.txt` 是占位、`third_party/CMakeLists.txt` 只管 ffmpeg、
git log 无此脚本）。本机那套是历史会话手搓的，源码与产物又都在 `.gitignore` 里。
**17 步门禁从不删 `build/tools/`，所以这一层从未进入判据** —— 暖缓存绿了整整几周。

落地（接手后不必重做）：

- 新增 `tools/build/build_shader_toolchain.sh`：pin 从 `third_party/manifest.toml` 读
  （脚本自己不写死 commit）、源码缺失按 `pin_ref` 浅 fetch 并校验 `HEAD == pin`、
  幂等、失败残骸自清、产物 `--version` 自检 + **端到端真转一遍 SHADER-001**（`blit_msl.h` = **1689 B**）。
- `.github/workflows/ci.yml` 加装配步（第 4 条写死约束：**必须在 `build_core.sh` 之前**，
  `--clean` 会把刚装好的 `build/tools/` 一起清掉）。
- `docs/BUILD.md` 新增「构建 shader 工具链」小节（含症状识别：看到 ctest 大面积红先回构建日志最早的 error）。

修复过程中又抓到三个只在"干净机"才出现的坑，全部记进 P160/P161：
SPIRV-Cross CLI 要求六个 backend 全开（关任一即 FATAL_ERROR）、失败的 configure 会把旧 `-D` 值
锁进 `CMakeCache.txt` 使"改对重跑"看着仍失败（P161）、日志重定向目标目录在新克隆机上不存在。
**另纠一处只在大小写敏感卷上才暴露的隐患**：出参目录改用 `build_shaders.py` 默认的
全小写 `build/tools/spirv-cross/`，不再依赖 APFS 不区分大小写"碰巧能用"。

**复现次数与版本对应（判据口径，别混着引用）**：

| 遍 | 脚本版本 | 结果 |
|---|---|---|
| run1 | 大小写修正**前** | toolchain/build/ctest 全 rc=0，**51/51**（186.74s） |
| run2 | 大小写修正版 | 全 rc=0，**51/51**（172.84s）+ hygiene rc=0 |
| run3 | + SPIRV-Cross 横幅本地补丁 | 全 rc=0，**51/51**（271.32s） |
| run4 | **P162 修复后的交付版** | 全 rc=0，**51/51**（83.52s）+ hygiene rc=0 |

四遍都在日志里显式打印排除名单 `Test #45: platform_apple_decode`；卡面判据"连续 2 次绿"由
**run3 + run4** 满足。干净单遍 6m48s~11min；⚠️ ctest 墙钟四遍差 3 倍以上 → 本机只有 rc 与通过数可比。

**P162（负向测试抓到的是我自己的脚本）**：`--check-only` 名义只读、实际仍会走 `rm -rf` 分支；
"补丁指纹变了就自动重编"的守卫拿 `SPVC_PATCH_FP:STRING=` 去 grep cache，而**裸 `-D` 在 cache 里落成
`:UNINITIALIZED=`** → 恒不命中 → 每次暖跑都误判"补丁变了"、白删白重编 ~65s。两处已修并复验
（暖态完整跑 = 两工具均 `跳过编译`；暖态 `--check-only` = 产物 md5 前后一致；藏 `glslang` → rc=**1**）。
**接手要带的规则**：只读模式必须在函数入口短路，不能每个副作用点各判一次；grep CMake cache 键时
类型段写成可选 `^KEY(:[A-Z]+)?=`。

这两节的规则**已升为 ADR-0045**（适用面不限于 SHADER-001：任何编译期被调用的外部二进制都算），
其中"是否把本机非 git 树改成始终按 pin checkout"仍待传哲拍板。

## 五、接手第一步要做什么

1. **问传哲要不要提交、按几段提交**（本文件 §一）。不确认不 commit、不 push。
   同一轮请一并复核 **ADR-0045**（P160 铁律 + "引用门禁绿必须标注缓存状态"的口径，集成机自决立规）
   与池 **[23]**（本机 SPIRV-Cross 不入库本地补丁 = 本机与 CI 依赖不同源）。
2. push 之后看 **远端 workflow 首跑**：本机只做了等价复现；`ci.yml` 的 FFmpeg 装配步
   走的是"浅 clone 源码 + `build_ffmpeg_demux.sh`"，本机是 prebuilt binary 模式，**没在本机复现过**。
   已在本机验证的是 `ensure_src` 的取源码命令组：SPIRV-Cross 走**完整三步**
   （`clone --no-checkout --filter=blob:none` → `fetch --depth 1 origin <pin>` → `checkout --detach <pin>`）
   实测 `HEAD == pin`、38s；glslang 只验到 `fetch --depth 1 origin <pin>` 那一步
   （`FETCH_HEAD == pin`、25s，未整树 clone），**checkout 那步是同一命令模板推出来的，未逐字跑**。
3. clang-format **全库重排卡**（本批只落基线与违规数字：`engine/**` 79/115、`tests/**` 34/51，
   只报不判红）。166 个文件的 cosmetic diff 不许塞进任何功能批。
4. `.clang-tidy` 仍未引入（INFRA-012 剩余部分）。
5. 池条目 **[18]**（双壳进门禁：本批只做到"iOS 切片只编译"那一半，壳构建约 10min×2 未入门禁）、
   **[20]**（TimelineKit 在仓库外、无版本控制；本批判定**不收编**，Podfile 已加路径断言守卫）、
   **[21]**（`ui/ChuanqiCutDraft` 六包里唯一从未被编译的包）、
   **[22]**（**新**：活文档仍在用上上代路径 `core/include/cq/**`，90 个 tracked 文件命中，
   其中描述当前状态的 9 份模块册 + 1 份 spec 待逐文件人改；`check_repo_hygiene.sh` 的旧路径
   判据只覆盖本批搬过的前缀，管不到它 —— 不是它绿，是没人判）、
   **[23]**（**新**：本机 `third_party/src/SPIRV-Cross/CMakeLists.txt` 里有一处**不入库的本地补丁**，
   用来压掉"非 git 树 → `git describe` 向上抓宿主仓库 HEAD"的假版本横幅；待传哲判定是否接受该状态，
   不接受就改成始终按 pin 做 git checkout）。
6. `CODEOWNERS` 未落：需要传哲给各模块归属人的 GitHub 用户名，属决策不是施工。

## 六、本批的坑，一句话一条（细节读 `.ai/memory/pitfalls.md`）

- **P150** CocoaPods 的 `source_files` 是 pod 根相对路径，脚本机械替换会**静默丢源码**。
- **P151** 生成型文档（`docs/api/engine-api.md`）长期过期无人知 → `--check` 已入门禁；
  解析器匹配不到 ≠ 规则不存在。
- **P152** SPM 增量缓存会钉死旧绝对路径，搬家后 `run_gate` 首跑必红 → 清 `build/spm`（1.2G）。
- **P153** 检索纪律：判据只认入库文件（`git ls-files`），未跟踪的本地文件不算证据。
- **P155** `git ls-files` 不带 `-z` 会把非 ASCII 路径加引号转义，逐行遍历 = 中文名整批静默漏检。
- **P156** 批量路径替换会**二次改写「原 xxx」标注行**，把历史说明改成反向错误（禁批量替换）。
- **P157** 未提交大改批里对单文件 `git checkout --` = 直接销毁本批工作（长批次先建保险提交）。
- **P158** `if cmd; then …; fi` 无 `else` 会把 `$?` 归零 → 负向测试"看着红、实际绿"。
- **P159** 非交互 shell 没有 `LANG` → `pod install` 在 ruby `unicode_normalize` 崩，日志只见栈。
- **P160 / P161** 见本文件 §四。
- **P162** 自称"只读校验"的模式里混着 `rm -rf`，且 grep CMake cache 键时把类型段写死 `:STRING=`
  （裸 `-D` 实际落 `:UNINITIALIZED=`）→ **判据恒不命中**：幂等守卫每次误删重编、`--check-only` 反过来
  破坏判据现场。规则：只读模式在函数入口短路；cache 键匹配写 `^KEY(:[A-Z]+)?=`。

## 七、明确没做 / 不支持（不要当成已完成）

- 远端 CI **首跑未验证**（本机等价复现绿不等于 Actions 绿，AGENTS「验证」口径）。
- clang-format 全库重排**没做**；`.clang-tidy` 没引入。
- 双壳构建**没有**进 `run_gate.sh`（只加了 iOS 切片只编译一步）。
- TimelineKit **没有**收编（仍指本地路径，Podfile 有守卫）。
- `ui/ChuanqiCutDraft` 仍**零门禁覆盖**。
- 本批**没有任何性能结论**：全是布局与判据，性能基线沿用 10-13 的窄检数字。

---

## 七、状态更新（2026-10-17 10:3x）：**本批已提交到本地 main，未 push**

§一 那句"整批仍未 commit"**已过期**，接手时按本节找状态：

- `294d518` 搬家（294 路径）/ `a7a20b8` 治理（12 路径）/ `b08f78a` 活文档（91 路径）/ 第四段 P163 修复。
  **`origin/main` 仍在 `5cfcdcb`，本地领先**——push 与否等传哲。
- ⚠️ **一处归属错位**（已知、已就地声明，不要照抄提交正文的归属句）：
  `tools/build/build_shader_toolchain.sh` 落在**第一段**（搬家段），不是第二段；
  第二段正文里那句"下一段随文档"是错的。分组用的是"全暂存后反选摘出"，反选清单漏了 `tools/build`。
  没重写历史（未确认不 amend），改在第三段正文显式纠正。**归属以 `git show --stat` 为准。**
- 提交后复测抓到 **P163**：`check_repo_hygiene.sh` 的旧路径判据命中**了自己的正则定义行**
  （脚本未跟踪时不在 `git ls-files` 射程内，一提交就现形，4/4 → 3/4 FAIL）。
  修法 = `SELF` 排除自己 → **4/4 PASS，tracked 878**（提交前 856 + 新入库 22）。
- 待办池不变：**[22]** 旧头路径 90 文件、**[23]** SPIRV-Cross 本地补丁、**[20]** TimelineKit、
  **[18]** 双壳进门禁、**[21]** Draft 零覆盖。**远端 workflow 首跑仍未验证**（本批没 push，谈不上）。

---

## 八、状态更新（2026-10-17 12:2x）：追加批 INFRA-036/037 已提交**本地**，未 push

§七 之后又走了一轮（传哲九条裁定的落地批），接手时按本节找状态：

- 本地两个 commit：`ae50a68` INFRA-036（活文档三代死路径适配，池 [22] 关闭）/
  `4595865` INFRA-037（双壳进总门禁第 6 步 `apple-shells`，池 [18] 关闭 + P164 三层机械防护）。
  **传哲 12:2x 明确「提交到本地」→ 未 push**，`origin/main` 仍在 `55653bf`。
- 验收数字（本机全量，同趟）：`run_gate.sh` **PASS=18 / FAIL=0 / SKIP=0**，墙钟 ≈20m40s，
  core 52/52 ×2、六包 252 用例、双壳暖 44.5s（冷 280s）、hygiene **5/5**（提交后复跑，P163 纪律）。
- 新增坑：**P164**（构建 scratch 第三次进源码树 ⇒ 绝对路径+落点断言+跑完自查+判据 5）、
  **P165**（长表格行锚点被嫁接）、**P166**（结构性推断当实测口径，被自家实测推翻）。
- **待办池**：[18]、[22] 已关闭；[23] 定调「具体事务具体分析」按案处理；新增 **[24]** iOS 模拟器切片
  —— 传哲先说「没必要支持」、同轮改判「**先不动**」，已冻结。解冻需传哲明确指令，前置见 [24]（**注意 [24] 里第 1 件是同轮写错的、已在其内更正**：`check_ios_compile.sh` 默认 `ios-device`，并不吃 sim 树）。
- **下一步归谁**：
  1. **传哲**：合并问卷 `QUESTIONNAIRE-UIA-044-045-合并版-…`（31 项，D5/E1/F3 三项要他定）；
     push 时机；INFRA-038（并行化）批不批——依据是实测 A/B **254s → 70s（3.6×）**，见 `baselines.md`。
  2. **接手的 agent**：别碰模拟器切片；要做 INFRA-038 就只改两个 `cmake --build` 调用点
     （`build_core.sh:85`、`build_core_apple.sh:178`），并**顺手把每步时长记进 `run_gate.sh` 摘要**
     ——现在脚本不记时长，我只能靠日志 mtime 反推。
  3. `.clang-format` 全库重排：**不在本批**，79/115 是现状基线，重排要单开卡（会把真实 diff 淹掉）。

## 九、INFRA-038 落地与新的成本口径（2026-10-17 12:2x~13:0x，集成机）

§八 的「下一步归谁」里第 1、2 条**同日做完**（传哲先给「开工」+「推」）：

- **改动面四个脚本**（写集见 `TASK-INFRA-038-门禁并行化.md`）：三个 `cmake --build` 调用点补
  `--parallel "${CQ_JOBS}"` + `run_gate.sh` 每步时长入账。**§八 那句"两个调用点"是漏数**——
  实际三处，第三处是 `check_ios_compile.sh:75`（它只编两个静态库 target，同样是单线程）。
- **全量门禁实测**：`PASS=18 / FAIL=0 / SKIP=0`，墙钟 **568s = 9m28s**（串行基线 20m40s → **2.18×**）；
  Debug/Release 各 **52/52**、六包 **26/52/77/16/81**、双壳 **90s**（半暖，本趟前面刚重建过 xcframework）、
  golden `21/0/0` 901784B。摘要每行带 `[Ns]`，末行「墙钟 567s / 已计时合计 567s / 差 0s」= 计时自证。
- **§八 引用的"外推 ~10min"作废**：`--parallel` 只压构建段，**ctest 段一点没动** → core 两步只从
  817s 到 411s。新的成本重心：**`media_sequential_real` 一个用例占 ctest 58%**（113.88s / 195.5s），
  以及 **Debug/Release 共用一棵 `build/`**（每趟白做一遍全量重编）。
- **接手时要知道的三条纪律**（都是本轮新踩的）：
  1. **P167**：说某步"暖/便宜"必须附「重编了几个 TU」（`grep -c 'Building CXX'`）。
     本轮 `build_core_apple.sh` 的"暖"实为 **91s / 57 TU**，不是上一趟的 17.3s no-op，成因未取证。
  2. **P168**：后台任务的 `completed exit 0` 通知**可能早于实际完成**（本轮任务还在 88% 就推了完成、
     输出文件为空）。取数字要看日志结束行 + `ps` 无进程 + 自己写在日志末尾的计时行。
  3. 加速比要指明**是哪一段**的：构建段 3~5×、步骤墙钟 1.78×、全程 2.18×，三个数都真。
- **仍卡在传哲那边**：合并问卷（31 项，D5/E1/F3 他定）；池 **[25]/[26]** 两个候选要不要立项；
  池 [24] / INFRA-039（模拟器切片）保持 ⏸ 冻结；`.clang-format` 全库重排单开卡。

## 十、状态更新（2026-10-17 13:2x~13:4x）：问卷回收结卡 + 门禁时长定口径 + 卡点分档表

§九 的「仍卡在传哲那边」四条，同日解决一条（**合并问卷 → 已回收**）、其余仍在。本轮做完的事：

- **门禁时长（回答"现在全量多久"）**：**PASS=18 / FAIL=0 / SKIP=0**，全量档墙钟
  **427s = 7m07s**（上一趟同档 568s；差 141s **全是缓存态**，不是又优化了）。
  `--fast` 档 **PASS=8 / SKIP=3**、**239s**。引用时必须带**三件**：档位、缓存态（暖要说清重编了几个 TU）、
  build/ctest 拆分。数字全在 `baselines.md`「并行化后全量门禁第二趟」。
- **每趟出总结**：`run_gate.sh` 现在落两份产物（`build/gate-logs/gate-summary.md` + `gate-history.tsv`，
  都不入库）。写这函数时踩 **P170**（`{ } > file` 里的 `return` 从函数返回 → tsv 静默没写、门禁仍全绿）。
- **UIA-044/045 同日结卡**（ADR-0034 的问卷门开了）。**回收口径诚实**：传哲整体判定"验收通过"，
  未逐项勾选、无截图、G1 没给新内存样本 → 28 项按整体入账，表里的 ☐ 不代打勾。
- **三裁定 → 两新卡**：**D5 点选也暂停** → `TASK-UIA-046`；**E1 先补内核 muted ABI** →
  `TASK-CORE-011`（池 [19] 待决策态解除，条目不关）；**F3 iPad 接受现状** → 不建卡，
  UIA-045 那条"保留右栏需抽共享宿主对象"的风险**撤下**。BACKLOG 补 §16（041~045 欠的行一并补）。

### 卡点分档（谁能动，不是优先级排序）

**A. 要传哲点头（决策 / 高冲突面，agent 无权自行做）**

| # | 卡点 | 现状证据 | 点头之后是谁做 |
|---|---|---|---|
| A1 | 池 **[25]** / INFRA-040：Debug/Release 共用一棵 `build/` | **有计数**：同趟 `core-dbg` 重编 **0 TU**、`core-rel` 重编 **95 TU** | 集成机改 `build_core.sh` + CI + hygiene 判据 5 的 scratch 清单 |
| A2 | 池 **[26]** / INFRA-041：`media_sequential_real` 占 ctest **54%** | 本趟 58.23s / 107.63s（独立实测 113.88s，**单例秒数两趟差 2×**） | 传哲选三条路之一；缩样要写明"判据射程变小" |
| A3 | 池 **[20]** TimelineKit 在仓库外、**无版本控制** | Podfile 指 `../../../../ChatGPT/zui`；新克隆 `pod install` 必失败；UIA-045 已就地改过组件 3 处无历史 | 传哲放行"改 Podfile 引用路径"才动得了（他 10-16 明确"引用不要改"） |
| A4 | 池 **[16]** + **[24]** / INFRA-039：模拟器 | 传哲先"没必要支持"、同轮改判"**先不动**" | 解冻需明确指令；前置两件在池 [24] |
| A5 | 池 **[23]**：本机 SPIRV-Cross 打了不入库的补丁 | CI 与本机**不同源**（P160 同族风险） | 判定"入库 / 撤补丁 / 记豁免" |
| A6 | `CODEOWNERS`（INFRA-034 遗留） | 待传哲给用户名 | 给名字即可落 |
| A7 | `.clang-format` 全库重排 | 现状基线 INFO **79/115**，重排会淹掉真实 diff | 单开卡，时机他定 |
| A8 | 轨道 `enabled` 要不要跟 CORE-011 同批补 | mixer `:446` 同时消费 `!enabled \|\| muted`，**一比一拓** | 一句话；不做则轨道"启用"仍是只能看不能点 |
| A9 | UIA-046 的小决策：**点空白取消选中**算不算"也暂停" | 默认**不算**（D5 说的是点选片段）；改是**一行** | 不做决定就按默认落 |

**B. 卡在条件，不卡决策（缺的是环境/机会，不是拍板）**

- 远端 **CI workflow 首跑从未验证**；且 CI 的 **FFmpeg 装配步本机没复现过**（本机绿 ≠ 远端绿，ADR-0030）。
- **并行后的冷态全量门禁（`rm -rf build`）未实测**——现在只能说暖态 7m07s / 9m28s，冷态只有串行基线 18m58s。
- **P167 未定位**：`build_core_apple.sh` 的"暖"仍重编 57 TU，两条候选成因都没取证。
- G1（播放 60s+ 内存/帧率）要**设备 + 传哲操作**，脚本侧无法回收。

**C. 卡在 agent（可以直接开工，只等"开工"两个字）**

- **UIA-046**：`EditorViewController.swift:585` 一处 + `isEditing`→`pausesPlayback` 改名 + 一条用例。
- **CORE-011**：`ChqTimeline::SetTrackMuted` → `ChqSetTrackMutedCommand` → `SubmitSetTrackMuted` →
  `cq_session_set_track_muted` → Swift `setTrackMuted` → 适配层 `case .setTrackMuted`（去回滚）+ 三处单测
  + `engine-api.md` 重生成（符号 103→104）。**动 `cq_sdk.h` = 集成机独占，开发机不得认领。**
