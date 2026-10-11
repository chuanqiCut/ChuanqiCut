# HANDOFF-018：INFRA-022 仓库布局与分层整改 —— P0/P1/P2 完成，P3 交接（2026-10-11）

> 接手人开第一步前**必读**：`ADR-0035-PAL统一改名为Platform.md`（映射表 + 保留清单 + 三条红线）、
> `RESEARCH-011-仓库布局与分层整改方案.md` §5（四阶段计划）、`docs/reports/LEDGER-W42.md`
> 末尾三条（P0/P1/P2 实现 + ctest 闭环 + 提交落地）。
>
> 本轮定位：把 RESEARCH-011 的 P0（半迁移落库）、P1（产物清理）、P2（PAL → Platform 改名）
> 三批做完并**带实证提交**。P3 未开工，交接在此。

## 0. 当前状态一览

| 阶段 | 内容 | 状态 | 实证 |
|---|---|---|---|
| **P0** | 半迁移状态落库（137 文件纯移动）+ 空壳目录清理 | ✅ 已提交（`9afd18c` / `f436fef`） | 150 个纯移动 + 2 个移动加修改，零内容丢失 |
| **P1** | 构建产物清理 + gitignore 同步 + CMakePresets + 修 PIN_REF bug | ✅ 已提交（`2dd4edd` 含部分） | `apps/` **5.5G → 4.3M**；`cmake --list-presets` 输出 debug/release |
| **P2** | `PAL` → `Platform` 全量改名（目录 + 标识符 + 概念名 + 文档） | ✅ 已提交（`be669e3` / `2dd4edd` / `b5b2eec`） | `build_core.sh --test` → **46/46**；门禁 38 头 0 违规 |
| **P3** | 根 README / `.clang-format` / `.editorconfig` / `CODEOWNERS` / 最小 CI | ❌ **未开工** | — |

**当前 main 领先 origin 3 个提交**（未推送）：`be669e3` → `2dd4edd` → `b5b2eec`。

## 1. P2 改名的关键事实（接手改代码前必读）

### 新名一律用这套
```
目录：engine/core/cq/platform/（契约）+ engine/platform/（实现）+ tools/platform/
类型：PlatformPtr<T> / IPlatformResource
宏  ：CQ_PLATFORM_*_H_
目标：cq_platform_apple（CMake）/ cq_tests_platform_apple_*（test）/ platform_apple_*（ctest）
```

### 有意保留，不要「顺手改掉」
| 项 | 处数 | 为什么保留 |
|---|---|---|
| `PALA-xxx` / `PALD-xxx` 任务卡号 | 336 / 39 | 无合理映射（`PLATA-`/`PLATD-` 更糟），改了会让 TASK / BACKLOG / HANDOFF 几百处引用断链。已在 `TASK-BACKLOG.md` 第 43 行下加注明 |
| `.workbuddy/memory/2026-*.md` 日期日志 | ~110 | append-only 历史流水 |
| `LEDGER-*.md` 历史条目 | — | ADR-0034：台账禁止改写历史条目 |
| `*.xcframework` 内 Headers | — | 构建产物（0 tracked），下次构建自动重建 |

### 三条红线（本次踩出来的，已写进 ADR-0035 与 `.ai/modules/platform.md`）
1. **门禁白名单写死目录名**：`tools/platform/check_platform_headers.py` 的
   `CONTRACT_DIR_NAMES` 含 `"platform"`。目录再改名而白名单不同步 →
   **静默漏扫整个目录**（不报错、CTest 全绿、git status 看不出来）。这是 **P95 的复发**。
2. **ctest 名随 target 改，文档里的 `ctest -R <name>` 必须同步** ——
   编译抓不到这类断链，只有跑测试才炸。
3. **podspec 路径不走 CMake 链路**：`engine/CChuanqiCut.podspec` 的
   `source_files` 是 `core/cq/**` + `platform/apple/**`（相对 `engine/`），
   **编译过 ≠ pod install 过**。改目录后必须单独核这里。

## 2. P3 的具体任务（下一步）

按 RESEARCH-011 §5.4，五件，都很小但缺了会影响协作：

1. **根 `README.md`** —— 现在仓库根没有 README。需要：分层图（core → platform → bindings → apps）、
   目录速查表、缩写表（`Platform` / `PALA` / `PALD` / `RenderGraph` 等）、构建与门禁一条命令入口。
   ⚠️ P2 已证明「缩写不自明」是真痛点，缩写表务必写。
2. **`.clang-format`** —— C++ 全库无统一格式配置。
3. **`.editorconfig`** —— 跨编辑器缩进/换行统一。
4. **`CODEOWNERS`** —— 高冲突文件的归属（`cq_sdk.h` / CMake / podspec / Podfile / project.yml / CI）。
5. **`.github/workflows` 最小 CI** —— 复用 `tools/ci/run_gate.sh`（**禁止另写一套编译命令**，ARCH-001 §9）。

**建议顺序**：README → .clang-format → .editorconfig → CODEOWNERS → CI。
CI 放最后（跑通需要时间，且依赖前面稳定）。

## 3. 未提交的 28 个文件（**不属 INFRA-022 写集，待传哲决定**）

| 位置 | 数量 | 内容 |
|---|---|---|
| `apps/apple/packages/` | 17 | 相机模块既有改动（`CameraManager.swift` +122、`MakeupParams.swift` +36、`MetalFXScaler.swift` +47）+ 新增 `CameraFormatSelector.swift` 及测试 |
| `apps/apple/{ios,mac}/` | 7 | 壳工程 Podfile / Podfile.lock / project.yml / Info.plist |
| `tools/build/make_ffmpeg_xcframework.sh` | 1 | 新增未跟踪，属 DEPS/INFRA 线 |
| `third_party/manifest.toml` | 1 | 依赖清单改动（热点文件，须集成机处理） |
| `ChuanqiCut-AppIcon-Launch.miora` + `_assets/` | 2 | 图标设计源文件 |

## 4. 本轮踩的坑（已修，别重犯）

**P103（2026-10-11 立）**：全仓机械替换**必须显式排除 append-only 文件**
（`docs/reports/LEDGER-*.md`、`.workbuddy/memory/YYYY-MM-DD.md`、`.zcode/plans/*`）。
本轮把台账扫进去，24 处被改写。最隐蔽的一类：描述变更的行被改成 `A → A`
（「`pal` → `platform`」变成「`platform` → `platform`」），**旧名丢失、语义归零**，
grep 计数完全看不出来，只能逐行读。
→ **替换后必须专门复核 `→` 形式的行**。

## 5. 并发协作：给 DEPS 线（另一会话 / 另一 agent）的交接

> 2026-10-11 09:00 确认：**另一 agent 正在同一工作区并行跑 DEPS 线**（FFmpeg 9.0.2 双集成
> + xcframework 打包 + LGPL 处置，卡号 DEPS-012）。本节是给它的交接，INFRA-022 线的接手人也要读。

### 5.1 我（INFRA-022 线）已经做了什么 —— 会影响你的部分

**全仓 `PAL` → `Platform` 改名，5 个提交已落库、未推送**：

```
be669e3  文档与治理层（124 文件）
2dd4edd  代码 / 构建 / 测试 + P1（100 文件）
b5b2eec  skill 定义同步（3 文件）
822b313  HANDOFF-018 + 台账 + README 补登
5c4a001  台账：并发写入登记
```

**对你有影响的改名**（若你的新代码引用了旧名会断链）：

| 旧 | 新 |
|---|---|
| `cq/pal/*.h` | `cq/platform/*.h` |
| `engine/pal/` | `engine/platform/` |
| `cq_pal_apple` | `cq_platform_apple`（CMake target） |
| `PalPtr<T>` / `IPalResource` | `PlatformPtr<T>` / `IPlatformResource` |
| `CQ_PAL_*_H_` | `CQ_PLATFORM_*_H_` |
| `tools/pal/check_pal_headers.py` | `tools/platform/check_platform_headers.py` |

⚠️ **历史卡号 `PALA-xxx` / `PALD-xxx` 有意保留了**（336 / 39 处）—— 不要顺手改，
改了会让 TASK / BACKLOG / HANDOFF 几百处引用断链。已在 `TASK-BACKLOG.md` 第 43 行下加注明。

### 5.2 两个写集交叉点 —— 已核，未冲突，但你提交时要知道

我逐个核过，**你的改动是叠加在我的提交之上，没有互相覆盖**：

**① `tools/build/build_ffmpeg_demux.sh`**（你我**都**改了）
- 我改：第 39 行 `PIN_REF` 由 35 字符补全为 40 字符
  （`946fcce07b6dcd0331c8cc609192aeff5e1924f8`）。
  **原来第 51 行的校验必然失败**（deps.lock 与源码 HEAD 都是 40 字符），这是个真 bug。
- 你改：PARSERS 去掉 `hevc`/`mpeg4video`/`opus`（上游 Makefile 不闭合）、
  加 `--arch="$ARCH"`、加链接闭合冒烟（第 87 行之后）。
- ✅ 现状：`grep -n "PIN_REF=" ` 显示 40 字符**仍在**，你的改动也在，行区间不重叠。
- ⚠️ 你提交该文件时，**这个 diff 会同时含你我两人的改动**，commit message 里请都提到。

**② `engine/CChuanqiCut.podspec`**（你我**都**改了）
- 我改：`source_files` 的 `pal/apple/**` → `platform/apple/**`（第 33 行）、
  `HEADER_SEARCH_PATHS` 的 `$(PODS_TARGET_SRCROOT)/platform/apple/{base,gfx,media}`（第 63-65 行）。
- 你改：license 段改写为 `NOTICE.md` + LGPL-2.1-or-later 说明。
- ✅ 现状：叠加态完整（`git show HEAD:... | grep -c NOTICE` = 0，工作区 = 2，说明我的已入库、你的在工作区）。

### 5.2b 09:40 复核：你又触及的高冲突共享文件 —— 已核，我的改名未被回退

你在 09:0x 又改了一批，其中几个是**我这次动过的高冲突文件**。我逐个核过，
**你的改动是叠加，没回退我的改名**（你基于已含我改名的 HEAD 工作，所以天然叠加）：

| 文件 | 你的动作 | 我的改名是否还在 | 证据 |
|---|---|---|---|
| `CMakeLists.txt`（根） | 改 | ✅ 在 | `add_subdirectory(engine/platform)` 第 40 行 ✓ |
| `engine/core/CMakeLists.txt` | 改 | ✅ 在 | `platform` 提及 2 处 ✓ |
| `tests/CMakeLists.txt` | 改 | ✅ 未在本次 diff 中（本次动的是别处） | — |
| `engine/core/cq/` | **新增** `ffmpeg_probe.{cpp,h}` | ✅ 新增，未覆盖我任何文件 | `git status` 显示 `??` ✓ |
| `.ai/memory/baselines.md` | 改 | ✅ 我加的 2026-10-11 段在 | 计数 1 ✓ |
| `engine/NOTICE.md` | 新增 | — | 你的地盘 |
| `docs/tasks/TASK-DEPS-012.md` / `ADR-0036` | 新增 | — | 你的地盘 |

**反查全仓确认无回退**：`grep -rn "cq/pal/\|cq_pal_\|PalPtr\|CQ_PAL_" engine tests CMakeLists.txt` → **0 命中**。

⚠️ **编号提醒**：你取了 `ADR-0036`（FFmpeg 本地 Pod 二进制接入和 LGPL 处置），
我此前记的「下一号 0036」已作废，我这边顺延为 **0037**。
**并发时编号要现取现核** —— 两个 agent 同日取号极易撞，别只看 `docs/README.md` 的表（会滞后）。

### 5.3 我没有碰的（你的地盘，随便动）

`third_party/CMakeLists.txt`（你引入 `cq_ffmpeg` target，binary/source 双模式，85 行 diff）、
`third_party/manifest.toml`、`tools/build/make_ffmpeg_xcframework.sh`（新建，08:51:04，未跟踪）。
我的 4 个提交里 `third_party/` 与 `make_ffmpeg_xcframework` **命中数全为 0**（已逐个 `git show --name-only` 核过）。

### 5.4 给你的三条提醒

1. **我的 5 个提交未推送**，main 领先 origin 5 个。你 push 前先 `git log` 看一下，
   **别用 `git pull --rebase`**（会动我未推送的本地提交）。
2. **我的 46/46 ctest 是在我的提交版本上跑的，不含你的 `third_party` 改动**。
   你改完 CMake 引入 `cq_ffmpeg` 后**必须重跑** `build_core.sh --test`，
   我的数字不能直接当你的回归基线。
3. `tools/ci/run_gate.sh` 我改了（门禁脚本路径 `tools/pal/...` → `tools/platform/...`）。
   你若在 CI 里加 FFmpeg 相关步骤，注意这行已被我动过。

### 5.5 剩余风险

- 两条线长期共用一个脏工作区：**任一方执行 `git checkout` / `git stash` / `git reset` 都可能波及对方**。
  建议**你先提交你的改动**，让工作区收敛。
- 28 个未提交文件里有 `apps/apple/` 相机改动（17）与壳工程（7），
  **既不是我的写集也不是你的**，待传哲决定去向，别顺手提交。

## 6. 验证口径提醒（给下一个接手人）

- 本机是 **Intel Mac**（`uname -m` = x86_64），**无 ANE / ProRes 硬编** ——
  任何性能数字都**不得**作产品阈值。
- macOS App 构建必须带 `-arch x86_64 ONLY_ACTIVE_ARCH=YES`（P96）。
- iOS App 构建只认 `ChuanqiCutApp` scheme + `iphoneos` generic device。
- **全量门禁 `tools/ci/run_gate.sh` 本轮未跑**，只跑了 `build_core.sh` + ctest。
  报「验收完成」前必须补跑（且按 ADR-0034 需先问传哲）。
