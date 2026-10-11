# RESEARCH-011：仓库布局与分层整改方案

> 日期：2026-10-10 22:10（CST）
> 上游命题：传哲「工程架构不是很清晰…很多编译文件夹、测试文件夹、代码混着；源码和工程也乱放；
> 分层不清晰，有些抽象如 Platform 根本不知道是啥，要通用一点。看专业仓库怎么管，有没有更好的方案」
> 方法：磁盘实勘（命令取数，非文档口径）+ 业界布局惯例检索对照
> 本期动作：**只出方案，不动代码**（迁移动作需先由传哲拍板 P0 一步）
> 数字纪律：所有规模数字为实测；业界惯例标注来源 `[E]`（公开资料/社区惯例，非本项目实测）

---

## 0. 三句话结论

1. **`.gitignore` 其实是干净的** —— 入库产物数为 0（`git ls-files -i -c --exclude-standard` = 空）。
   你看到的"编译文件夹混着"发生在**磁盘与开发者视野层**，不是版本库污染。
2. **但仓库当前处于"半重构未提交"状态**：INFRA-022 的目录迁移做了一半从未提交
   —— HEAD 里内核还在 `engine/core/{include,src}/`（140 文件），磁盘上已经搬到 `engine/core/cq/`（137 文件，**全部未入库**），
   另有 152 个删除、46 个修改挂在暂存区外。**这个必须先收拾，否则任何 checkout/rebase/pull 都会把旧布局拉回来。**
3. **Platform 这个名字确实要换**，建议换成 `platform/`。理由与候选对比见 §5。

---

## 1. 现状实勘（磁盘 vs 版本库）

### 1.1 规模对照（实测）

| 目录 | 磁盘文件数 | 磁盘体积 | 入库文件数 | 性质 |
|---|---|---|---|---|
| `apps/` | 65,662 | **5.5G** | 155 | 源 + Swift/Clang 预编译产物（`.pcm` 8,455 个） |
| `build/` | 39,116 | 2.6G | 0 | CMake + xcodebuild + SPM scratch |
| `third_party/` | 11,051 | 160M | 4 | FFmpeg 源码 + **in-source 产物** + 配置 |
| `engine/` | 4,259 | 345M | 182 | 源 + SPM `.build` |
| `vendor/` | 2,509 | 30M | 0 | Bundler gem 本机缓存（45 个已解包 gem） |
| `docs/` | 209 | — | 201 | 文档 |
| `tests/` | 177 | — | 86 | 测试与 golden 资产 |

**入库总量 726**：其中源码类（`.c/.h/.cpp/.hpp/.mm/.m/.swift`）= **260**，markdown 文档 = **253**。
也就是说，**文档数量几乎等于源码数量**。这本身也是一个信号（见 §6 遗留问题）。

### 1.2 产物散落的六处（实测）

| # | 位置 | 体积/数量 | 生成者 |
|---|---|---|---|
| 1 | `/build/` | 39,116 文件 / 2.6G | CMake `cmake -S . -B build` |
| 2 | `/build/spm/<pkg>/` | 1.1G | SPM scratch（P84 规则要求的重定向） |
| 3 | `apps/apple/packages/*/.build/` | **5 处**：Editor 120M / Player 215M / SharedUI 408M / Camera 185M / Draft 0 | SPM 默认 scratch（**P84 规则没执行到**） |
| 4 | `apps/apple/{ios,mac}/build/` | `ios/build` 含 7,509 个 `.pcm`、`DerivedData` 1.1G | xcodebuild 默认 derivedData |
| 5 | `engine/bindings/swift/.build/` | 499 个 `.pcm` | SPM |
| 6 | `third_party/src/ffmpeg/` | **277 个 `.o` + 277 个 `.d`** | FFmpeg **in-source build** ← 最脏的一处 |

第 2 项和第 3 项**同时存在**：说明同一件事（swift test）有两条 scratch 路径，1.1G 重复。

### 1.3 版本库半迁移状态（本节是本轮最严重发现）

```
git status --porcelain       →  152  D  /  46  M  /  17  ??
```

删除（`D`）的分布：

| 目录 | 数量 |
|---|---|
| `engine/core/src/**` | 91 |
| `engine/core/include/**` | 46 |
| `engine/platform/apple/**` | 14 |
| `apps/apple/pods_post_install.rb` | 1 |

对照：

- HEAD（`git ls-tree -r HEAD`）里内核位于 **`engine/core/include/` + `engine/core/src/`**，共 140 个文件
- 磁盘上内核位于 **`engine/core/cq/`**，137 个文件，`git ls-files engine/core/cq` = **0**（整目录未入库）
- `engine/core/include/`、`engine/core/src/{ai,audio,...}`、`engine/core/tests/` 在磁盘上已是**空壳目录**

**后果**：
1. 任何人 `git clone` 后拿到的是**旧布局**，与 ADR-0033、`engine/core/CMakeLists.txt:17-84`、今天的文档全部对不上；
2. 现在执行 `git checkout` / `git stash` / `rebase` / `pull`，会把 137 个旧文件**拉回磁盘**，与新目录并存形成双份代码；
3. 双机并行下，远端开发机 pull 到的是旧布局，而集成机磁盘是新布局 —— 两边写集天然错位。

这条必须优先于所有"美观"的重构。

### 1.4 测试确实分散（7 处命名不一）

| 位置 | 文件数 | 命名 |
|---|---|---|
| `tests/unit/`（根） | 45 | `test_*.cpp` / `test_*.c`，另有非前缀的 `*_compile.cpp`、`cxx20_smoke.cpp` |
| `tests/golden/`（根） | 131 | golden 图片与视频资产 |
| `engine/bindings/swift/Tests/` | 7 | `*Tests.swift` |
| `apps/apple/packages/{Camera,Editor,Import,Player}/Tests/` | 22 | `*Tests.swift` + 辅助文件无后缀 |
| `tools/deps/tests/`、`tools/perf/launch_bench/Tests/` | 6 | Python / Swift |
| `engine/core/tests/` | 1 | **仅 `.gitkeep`，空壳** |

C++ 侧集中、Swift 侧就近，两套规则并存。

### 1.5 manifest 三套并存

| 类型 | 数量 | 覆盖范围 |
|---|---|---|
| `CMakeLists.txt` | 13 | C++ 内核 + Platform + 假占位（android/ohos 是 `add_custom_target` 空壳） |
| `Package.swift` | 7 | Swift 绑定 + 6 个 UI 包 |
| `Podfile` ×2 + `podspec` ×7 | 9 | Apple App 集成 |

同一批 Swift 包**同时**被 SPM 与 CocoaPods 声明（`apps/apple/packages/X/` 下 `Package.swift` 与 `X.podspec` 成对出现）。
CMake 唯一根 manifest 是好的 —— 责任分担层次是清楚的，缺的是三者的一致性校验。

### 1.6 治理文件缺失

| 文件 | 状态 |
|---|---|
| 根 `README.md` | **不存在**（全库 0 个根级 README，只有 4 个子目录级） |
| `.clang-format` | 不存在 |
| `.editorconfig` | 不存在 |
| `.clang-tidy` | 不存在 |
| `CODEOWNERS` | 不存在 |
| `CMakePresets.json` | 不存在 |
| `.github/workflows/*.yml` | **仅 `.gitkeep`，无任何 CI workflow** |
| `.zcodeignore` | 存在但与 `.gitignore` **不同步**（仍写单包 `SharedUI/.build/`，缺 `/.build/`、`__pycache__/`，多出无关项） |

---

## 2. 业界基准 [E]

来源：CMake Mastery 系列（W.M. Zafar）第 16 章、MangaD 的 *Common C++ Project Layouts* 实践指南、
以及若干 CMake/Conan 工程结构文章。三份独立资料给出的**收敛结论一致**：

| 业界惯例 | 内容 |
|---|---|
| 顶层固定集合 | `CMakeLists.txt` · `cmake/`（模块）· `src/` · `include/<project>/` · `apps/` · `tests/` · `docs/` · `third_party|extern/` · `build/` · `CMakePresets.json` · `README.md` |
| `src/` vs `include/` | 核心是区分**内部实现**与**对外接口**；仅做可执行文件时可省略 `include/` |
| `build/` 纪律 | 「永远不要提交到版本控制」，建议 presets 统一输出 |
| 多库 monorepo | `libs/<库名>/{include,src,CMakeLists.txt}` + `apps/<应用>/` |
| 平台相关代码 | 单独隔离到平台目录（推荐的 illustrated layout 直接给出 `src/common/` + 平台子目录） |
| `CMakePresets.json` | 被列为推荐（可复现 Debug/Release/工具链配置） |

对照本项目：**顶层结构其实大体合格**（已经有 `engine/`、`apps/`、`tests/`、`tools/`、`third_party/`、`cmake/`、`docs/`）。
真正偏离业界的不是"少了哪个顶层目录"，而是下面四条：

1. 单一构建根的纪律没有落到每一条工具链上（ §1.2 六处散落）
2. 一处 third-party 用了 **in-source build**，把 `.o` 写进了源码树
3. 平台层用了不自明的缩写 `platform`
4. 缺 `README` / `CMakePresets.json` / 格式化配置 / CI

---

## 3. 差距汇总

| # | 问题 | 严重度 | 类型 |
|---|---|---|---|
| **A** | 半迁移未提交（137 文件未入库 + 152 删除悬挂） | **P0 阻塞** | 版本一致性 |
| B | FFmpeg in-source build，554 个 `.o/.d` 混在第三方源码树 | P1 | 产物隔离 |
| C | SPM scratch 两套路径并存，重复 1.1G | P1 | 产物隔离 |
| D | `platform` 命名不自明，且接口目录内文件名前缀风格混用（`platform_clock.h` vs `capabilities.h`） | P1 | 可读性 |
| E | `engine/core/cq/cq/` 空套娃 + `include/`、`src/`、`core/tests/` 空壳残留 | P1 | 清理 |
| F | 测试七处分散、两套管法 | P2 | 组织 |
| G | 根 README / clang-format / editorconfig / CI / CODEOWNERS 全缺 | P2 | 治理 |
| H | `.zcodeignore` 与 `.gitignore` 不同步 | P2 | 治理 |
| I | 三套 manifest 无一致性校验 | P2 | 组织 |
| J | 文档数量≈源码数量（253 vs 260） | P3 观察 | 协作成本 |

---

## 4. 建议的目标布局（最小改动版）

> 原则：**只动必要的，不做大规模搬迁**。顶层已经合格，不要推倒重来。

```
ChuanqiCut/
├── README.md                  ★新增  唯一入口（构建/布局/分层三句话）
├── CMakePresets.json          ★新增  Debug/Release + 统一 binary dir
├── CMakeLists.txt                    唯一根 manifest（保持）
├── .clang-format .editorconfig CODEOWNERS   ★新增
├── .github/workflows/build.yml        ★新增 CI（最少：core 编译 + ctest）
│
├── cmake/                            保持（CompileOptions / Warnings）
├── engine/
│   ├── core/cq/                      保持（头实现共置，ADR-0033）
│   │   ├── cq_sdk.h                  唯一 public C ABI
│   │   ├── platform/        ★改名自 platform/    ← 平台接口契约
│   │   └── {base,command,model,media,gfx,preview,session,audio,ai}/
│   ├── platform/            ★改名自 platform/    ← 各平台实现
│   │   └── {apple,android,ohos}/
│   ├── bindings/{swift,kotlin,arkts}/
│   └── *.podspec
├── apps/  tests/  tools/  docs/  shaders/  third_party/   保持
└── build/                            ★唯一构建根（其余五处全部重定向进来）
    ├── cmake/ spm/ xcode/ third_party/  ← 按工具链分区
```

**要点**：顶层不动；只改两个目录名、删四个空壳、把五处产物重定向到 `build/`、补四个治理文件。

---

## 5. 命名方案：把 Platform 换成什么

### 5.1 现状（实测）

存在**两个** `platform` 目录，语义不同，这是最容易误解的地方：

| 路径 | 角色 | 内容 |
|---|---|---|
| `engine/core/cq/platform/` | 接口契约（12 文件） | `platform.h`、{platform_common,platform_clock,platform_log}.h、{capabilities,gfx,media,audio,inference,net,fs}.h |
| `engine/platform/` | 各平台实现（18 文件入库） | `apple/{base,gfx,media}/*.mm`、`android/**`、`ohos/**`（后两者是空占位 target） |

**"Platform 是什么"在全库的唯一解释出处**：
`docs/specs/Platform-接口契约.md:13` —— 「Platform（Platform Abstraction Layer）是**所有平台实现的契约**」。
全库 `grep` 仅此一处展开缩写。**这就是你说"根本不知道是啥"的根因**：一个三级缩写的项目核心概念，
解释只存在于一份 spec 的一句话里，日常接触的 `platform.h`、`platform_clock.h`、`cq/platform/`、`core/src/platform/` 都不自明。

另外 `core/cq/platform/` 内部文件名**前缀风格混用**：4 个 `platform_*` 前缀 + 8 个裸领域名并存。

### 5.2 候选对比

| 候选 | 含义 | 自明性 | 业界用法 | 评价 |
|---|---|---|---|---|
| **`platform/`** | 平台 | ★★★ 普通英文词，无需展开 | Flutter engine `shell/platform/`、Chromium 有 platform 组件 | **推荐**。读目录就知道放的是什么 |
| `adapter/` | 适配器 | ★★★ 但偏设计模式术语 | Java/Android 生态常见 | 次选。强调"适配别家接口"，但容易与设计模式混淆 |
| `hal/` | 硬件抽象层 | ★☆ | 嵌入式惯例 | **不建议**。本仓库对的是操作系统/图形 API，不是硬件 |
| `ports/` | 移植层 | ★☆ | BSD/Unix 传统 | 有历史包袱，非 Unix 背景的人看不懂 |
| `system/` | 系统 | ★★ | Rust std `sys`、Go `syscall` | 可行但偏"系统调用"语义 |
| `backend/` | 后端 | ★★ | 图形管线惯例 | 与 gfx backend 概念撞车 |

**推荐 `platform/`**。改名映射：

| 旧 | 新 |
|---|---|
| `engine/core/cq/platform/` | `engine/core/cq/platform/` |
| `engine/platform/` | `engine/platform/` |
| `#include "cq/platform/platform_clock.h"` | `#include "cq/platform/clock.h"` ← 顺带去掉冗余的 `platform_` 前缀 |
| target `cq_platform_apple` | `cq_platform_apple` |
| 任务前缀 `PALA-xxx` | 建议保持 `PALA-`（历史卡号不改，新卡用 `PLAT-` 需另行裁定） |

同时补一条硬：**目录名与概念缩写必须在根 README 有一行解释**，杜绝下一个 `platform`。

---

## 6. 分阶段迁移计划

### P0 — 收拾半迁移（**必须最先做，需你拍板**）

> 这一步不做，后面任何整改都是在双份代码上施工。

| 步骤 | 命令/动作 | 风险 |
|---|---|---|
| 1 | `git add -A engine/core engine/platform` 把 137 新增 + 152 删除**作为一个完整重命名提交** | 低。建议用 `git mv` 语义提交，保证后续溯源不断 |
| 2 | 核实它确实是纯移动（内容 diff 应极小）后再提交 | 若有内容变更应拆两个提交 |
| 3 | 删除磁盘空壳：`engine/core/include/`、`engine/core/src/{ai,audio,...}`、`engine/core/tests/`、`engine/core/cq/cq/` | 无风险 |

**替代方案**：若有疑虑，可这批改动先让你过一眼 diff 再提交。**不建议回退** —— 迁移本身是对的，只是没收尾。

### P1 — 构建根收敛（一次性，收益最大）

| 步骤 | 动作 |
|---|---|
| 4 | `apps/apple/packages/*/.build/` 与 `build/spm/` 二选一：统一到 `build/spm/<pkg>`（执行既有 P84 规则），删掉包内 5 处 |
| 5 | xcodebuild 统一 `-derivedDataPath "$ROOT/build/xcode/<target>"`（改 `tools/build/*.sh`） |
| 6 | FFmpeg 改 **out-of-tree**：`-B "$ROOT/build/third_party/ffmpeg"`，清理源码树内 554 个 `.o/.d` |
| 7 | `.gitignore` 补 `/build/**`（明确分区），`.zcodeignore` 重新对齐 |
| 8 | 加 `CMakePresets.json`，把 binary dir 钉为 `${sourceDir}/build/cmake` |

预期收益：`apps/` 从 5.5G 降到约 100M，`third_party/` 从 160M 降到约 100M，开发者视野里不再有 `.pcm`/`.o`。

### P2 — 命名可读性

| 步骤 | 动作 |
|---|---|
| 9 | `platform` → `platform`（两处目录 + include 路径 + CMake target + 相关 ADR/模块册文档） |
| 10 | `core/cq/platform/` 内文件去掉冗余 `platform_` 前缀 |
| 11 | 所有受影响卡的写集路径同步更新（记 pitfalls：又是一次全仓路径批量变更） |

风险提示：这会动 `cq_sdk.h` 之外的所有内核 include。**属于热点文件批量变更，必须走集成机一次性做完**，且与 B0（渲染地基）争写集 —— 建议在 B0 开工前完成，否则会打架。

### P3 — 组织与治理

| 步骤 | 动作 |
|---|---|
| 12 | 测试归并：C++ 单测就近共置（`<模块>/tests/`），根 `tests/` 只留跨模块集成测试 + golden |
| 13 | 补根 `README.md`（含分层图 + 目录速查 + 缩写表） |
| 14 | 补 `.clang-format` / `.editorconfig` / `CODEOWNERS` |
| 15 | 补最小 CI：core 编译 + ctest + golden verify（放 `.github/workflows/`） |
| 16 | 加 `tools/check_deps_consistency.py`：校验 CMake / SPM / CocoaPods 三方依赖清单一致 |

---

## 7. 明确不做（避免重蹈过度整改）

- **不做五到七层深的目录套娃**（`libs/xxx/src/yyy/include/zzz/`）。本项目就三个组件：内核、平台实现、各端 App，两层足够。
- **不引入 Bazel/Buck**。CMake + SPM + CocoaPods 三件套是 Apple 生态的事实标准，换体系收益远小于代价。
- **不把 markdown 文档合并清理**。文档多是本阶段的协作方式决定的（每批都要留台账与问卷），
  强行精简会丢决策记录，但 §3 的 J 项值得持续观察。
- **不在 P0/P1 完成前动任何目录名**。特别是 P2 的改名与 B0 渲染地基争夺写集，必须先做完 P2 再开 B0。

---

## 8. 数字纪律声明

- §1 所有规模数字为本次实测（`find` / `du` / `git ls-files` / `git ls-tree` 现场执行，可复验）。
- §2 业界惯例为公开资料检索 `[E]`，属于社区收敛惯例而非标准，**不代表本项目必须照抄**。
- §6 的工作量判断均为 `[E]`，未经拆解估算。
- 本文不含性能数字。

---

## 9. 来源

- 现状实勘：`git status --porcelain`、`git ls-tree -r HEAD`、`git ls-files -i -c --exclude-standard`、`find` / `du` 实测
- `engine/core/cq/` 文件清单见 `engine/core/CMakeLists.txt:17-84`
- Platform 全称唯一出处：`docs/specs/Platform-接口契约.md:13`；平台层注释 `engine/platform/CMakeLists.txt:1`、`engine/platform/apple/CMakeLists.txt:1`
- 业界布局惯例 `[E]`：[CMake Mastery Part 16 — Structuring Projects](https://www.wasilzafar.com/pages/series/cmake-mastery/cmake-mastery-part16-structuring-projects.html)、[Common C++ Project Layouts (Practical Guide)](https://gist.githubusercontent.com/MangaD/5ae179783a813fef3add881cc714d79b)、CSDN 若干 CMake/Conan 工程结构文章
- 关联：`ADR-0033`（头实现共置）、`ADR-0034`（分批推进）、`INFRA-022`（源收拢 engine/，半途未提交）、pitfalls `P84`（SPM scratch 规则）、`P98`（backlog 写集路径过期）
