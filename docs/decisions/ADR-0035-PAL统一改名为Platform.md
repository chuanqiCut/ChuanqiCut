# ADR-0035：PAL 统一改名为 Platform

- **状态**：已接受（2026-10-11 执行完毕）
- **日期**：2026-10-11
- **决策者**：传哲（拍板）+ 集成机执行
- **依据**：`RESEARCH-011-仓库布局与分层整改方案.md` §5.2；传哲命题
  「有些抽象如 PAL，根本不知道是啥，通用一点」
- **相关**：ADR-0019（文档分层）、ADR-0033（源码共置与双 Pod 边界）、ADR-0034（分批推进）

## 背景

仓库里 `pal` 有两个语义不同的目录：`engine/core/cq/pal/`（接口契约）与 `engine/pal/`（平台实现）。
全库唯一解释出处埋在 `docs/specs/PAL-接口契约.md:13`，**缩写不自明** —— 传哲原话：
「有些抽象如 PAL，根本不知道是啥」。

`PAL` = Platform Abstraction Layer。对比 `platform / adapter / hal / ports / system / backend`
六个候选后选 **`platform`**（RESEARCH-011 §5.2）。

## 决策

**不止改目录，把 `PAL` 这个概念名一并改掉。** 只改目录路径而保留 `PAL` 概念名、
`PalPtr` 等标识符、门禁脚本白名单里的 `"pal"`，等于没解决「不自明」这个问题，
而且会在改名后留下**静默失效**的隐患（见下「红线」）。

### 改名映射表

| 类别 | 旧 | 新 | 处数 |
|---|---|---|---|
| 目录 | `engine/core/cq/pal/` | `engine/core/cq/platform/` | — |
| 目录 | `engine/pal/` | `engine/platform/` | — |
| 目录 | `tools/pal/` | `tools/platform/` | — |
| 文件 | `pal.h` / `pal_clock.h` / `pal_log.h` / `pal_common.h` | `platform.h` / `clock.h` / `log.h` / `common.h` | 4 |
| 文件 | `pal_frame_provider.{h,cpp}` | `platform_frame_provider.{h,cpp}` | 2 |
| 文件 | `tests/unit/pal_headers_compile.cpp` | `platform_headers_compile.cpp` | 1 |
| 脚本 | `tools/pal/check_pal_headers.py` | `tools/platform/check_platform_headers.py` | 1 |
| 模块册 | `.ai/modules/pal{,-apple,-android}.md` | `platform{,-apple,-android}.md` | 3 |
| 文档 | `docs/specs/PAL-接口契约.md` | `docs/specs/PLATFORM-接口契约.md` | 1 |
| 文档 | `ADR-0011-core调用PAL工厂的隔离规则.md` | `...Platform工厂...` | 1 |
| CMake target | `cq_pal_apple` / `cq_pal_android` / `cq_pal_ohos` | `cq_platform_*` | 27 引用 |
| include guard | `CQ_PAL_*_H_` | `CQ_PLATFORM_*_H_` | 147 |
| 类型 | `PalPtr<T>` | `PlatformPtr<T>` | 436 |
| 类型 | `IPalResource` | `IPlatformResource` | 137 |
| 类型 | `PalDevice` / `PalEncoder` / `PalFrameProvider(Facade)` | `Platform*` | 49 |
| 概念名 | `PAL` / `pal`（注释、文档） | `Platform` / `platform` | ~1200 |
| 测试 target | `cq_tests_pala_*` | `cq_tests_platform_apple_*` | 20 |
| ctest 名 | `pala_*` | `platform_apple_*` | 20 |

### 有意保留（不改）

| 项 | 处数 | 理由 |
|---|---|---|
| `PALA-xxx` / `PALD-xxx` 任务卡号 | 336 / 39 | 没有合理映射（`PLATA-`/`PLATD-` 更糟），改了会让 TASK / BACKLOG / HANDOFF 里几百处历史引用全部断链。已在 `TASK-BACKLOG.md` 第 43 行下方加注明：「PALA/PALD 即 Platform 层 Apple/Android」 |
| `.workbuddy/memory/2026-*.md` 日期日志 | ~110 | append-only 历史流水，改了就不是当时的记录 |
| `docs/reports/LEDGER-*.md` 历史条目 | — | ADR-0034：台账 append-only，禁止改写历史条目 |
| `*.xcframework` 内 Headers | — | 构建产物（0 tracked），下次构建自动重建 |

## 红线（本次踩出来的）

1. **门禁脚本的目录白名单必须与目录改名同步。**
   `check_pal_headers.py` 里 `CONTRACT_DIR_NAMES = {"pal", ...}` 若不同步改成 `"platform"`，
   门禁会**静默漏掉整个 platform 目录**（不报错、CTest 全绿、git status 看不出来）。
   这是 **P95 的复发**，本次已修并在脚本内加注释固化。
2. **ctest 用例名必须跟着 test target 一起改，并同步所有文档里的 `ctest -R` 命令。**
   编译抓不到这类断链 —— 只有跑测试才会炸。本次同步了 TASK-MEDIA-021~026、
   HANDOFF-003、PLATFORM-接口契约 三处。
3. **全仓机械替换必须显式排除 append-only 文件**（见 **P103**）。
   本次把 `LEDGER-W42.md` 扫进去，24 处被改写，其中「`pal` → `platform`」式的
   变更描述被改成 `A → A`，**旧名丢失、语义归零**。这类错 grep 计数看不出来，只能逐行读。

## 验证

- `tools/build/build_core.sh --platform=apple --config=Debug` → **EXIT_CODE=0**，
  首轮全量重编 2m55s，0 error / 0 warning
- 同上加 `--test` → **46/46 测试通过**，EXIT_CODE=0，耗时 113.32s
- `python3 tools/platform/check_platform_headers.py` → **38 header(s), 0 violation(s)**
- 全仓 `pal` 残留复核：仅剩 `PALA`(336) / `PALD`(39) / `keepalive`(7，误匹配) /
  P103 与改名注释中的有意引用(7)

## 影响

- 代码层 174 个文件 + 文档层 90 个文件
- **无用户可见功能变化**，纯命名与结构整改
- 与 B0 渲染地基争写集（RESEARCH-011 §遗留已预判），**须在 B0 开工前完成** —— 本次已完成

## 后续

- P3（根 README / `.clang-format` / `.editorconfig` / CODEOWNERS / 最小 CI）未开工
