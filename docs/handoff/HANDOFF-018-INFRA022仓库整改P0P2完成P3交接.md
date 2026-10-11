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

## 5. 验证口径提醒（给下一个接手人）

- 本机是 **Intel Mac**（`uname -m` = x86_64），**无 ANE / ProRes 硬编** ——
  任何性能数字都**不得**作产品阈值。
- macOS App 构建必须带 `-arch x86_64 ONLY_ACTIVE_ARCH=YES`（P96）。
- iOS App 构建只认 `ChuanqiCutApp` scheme + `iphoneos` generic device。
- **全量门禁 `tools/ci/run_gate.sh` 本轮未跑**，只跑了 `build_core.sh` + ctest。
  报「验收完成」前必须补跑（且按 ADR-0034 需先问传哲）。
