# TASK-INFRA-030：tests/unit 平铺 51 文件按模块分目录（ctest 用例名一律不动）

```yaml
id:          TASK-INFRA-030
layer:       基建
goal:        tests/unit/ 从 51 个平铺文件改为按 engine/core/cq 模块名分组的子目录，可读性提升而门禁口径零变化
input:       [RESEARCH-018 §1.2 问题 5, 传哲 2026-10-16 决策 2（单测归 tests/unit/<模块>/，不就近共置）]
output:      [tests/unit/<module>/**, tests/CMakeLists.txt 的 51 个 add_executable 源路径, 3 处 ffprobe 绝对路径回退]
write_set:   tests/unit/**, tests/CMakeLists.txt, tests/unit/CMakeLists.txt（若拆分为子目录级 include）
read_set:    .ai/modules/*.md（模块归属），docs/tasks/TASK-CORE-*.md
deps:        [TASK-INFRA-029]        # 同写 tests/CMakeLists.txt，串行让路
acceptance:
  - `git ls-files tests/unit | wc -l` = **51**（45 `.cpp` + 6 `.c`，迁移前后一个不少）
  - **用例名集合与数量迁移前后完全一致**：`ctest -N` 的排序输出 diff 为空。
    基线（2026-10-16 本机实测，搬家前落盘 `/tmp/ctest-names-before.txt`）：
    `tests/CMakeLists.txt` 有 **52 个** `add_test(NAME ...)`（= 51 个 unit 源文件可执行 + 1 个
    `platform_header_gate`，后者 COMMAND 直接调 `tools/platform/check_platform_headers.py`，**没有源文件**）；
    `tools/build/build_core.sh --platform=apple --test` 的 Debug 段实跑 **`100% tests passed out of 52`，155.97s**。
    迁移后必须仍是 52 例、用例名集合 diff 为空。
    ⚠️ ctest 不在本机 PATH，且 `build/` 会被门禁的 Release 段重新 configure（实测该时刻 `ctest -N` 只报 43 例），
    **取基线数字必须在两次 configure 之间、或用 `--test` 的日志尾部**，不要对活着的 `build/` 直接敲 ctest。
    取 ctest 的方式：`CTEST_BIN=/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/ctest`，
    与 `build_core.sh:89` 同源。
  - 子目录集合 = `engine/core/cq/` 下 **11 个模块名全部命中**（ai/audio/base/command/gfx/media/model/
    platform/preview/render/session）∪ {abi}，共 12 个目录，无空壳目录
  - `grep -rn "/Users/zhuning" tests/unit` 零命中（3 个 apple 测试的 ffprobe 回退改为 `CQ_FFPROBE_BIN` 或 PATH 查找）
  - `tools/build/build_core.sh --platform=apple --test` 全量通过，数字与迁移前一致
verification:
  - "$CTEST_BIN" --test-dir build -N | sort > /tmp/before.txt（迁移前落盘）；迁移后同法得 after.txt 并 diff
  - git ls-files tests/unit | wc -l
  - tools/build/build_core.sh --platform=apple --test 2>&1 | tail -20
risk:        add_test 的名字与源文件路径是两回事 —— 只改路径不改名字是本卡的底线。
             若顺手"规范化"用例名，会让历史门禁记录、模块册里的数字（如 core 45/45）全部对不上，
             等于毁掉可比性（P82 编号纪律的同类问题）。
parallel:    false（与 029 同写 tests/CMakeLists.txt）
```

## 背景

`tests/unit/` 51 个文件（45 `.cpp` + 6 `.c`）平铺在一级，`tests/CMakeLists.txt` 里每个都单独
`add_executable` + `add_test`（合计 52 个 `add_test`，多出的是无源文件的 `platform_header_gate`）。分模块目录后，"某模块有没有测"能一眼看出，
也与 `engine/core/cq/<module>/` 形成镜像，新人可对着两边找测试。

## 实现要点

- **不改** `add_test(NAME ...)`；只改 `add_executable` 里的源文件相对路径。
- 分组规则：**按被测特性所在模块**，证据取「被测头文件 + 断言主导符号 + `target_link_libraries`」。
  ⚠️ 已实测**不可**用"主导 include"自动归类：51 个文件里 13 个先 include `cq/base/chq_status.h`，
  且媒体/图形类测试几乎都带 `cq/platform/*.h`（平台层定义接口），启发式会把它们全塞进 `base/`。
  下表为逐文件人工定案（2026-10-16，符号计数取证）：

  | 目录 | 文件 | 定案依据 |
  |---|---|---|
  | `abi/` (6) | `test_c_abi{,_session,_edit,_player,_preview,_property}.c` | 只 `#include "cq/cq_sdk.h"`；测的是门面 ABI，不属任何单模块 |
  | `base/` (8) | `cxx20_smoke.cpp`, `test_time`, `test_status`, `test_perf`, `test_log`, `test_log_workflow`, `test_alloc`, `test_concurrency` | 仅 `cq/base/*`（`cxx20_smoke` 无 cq include，是工具链基线） |
  | `platform/` (3) | `platform_headers_compile.cpp`, `test_capabilities`, `test_capabilities_apple` | `cq/platform/chq_capabilities.h`；断言主导符号 `ChqCapability`(41) |
  | `gfx/` (3) | `gfx_headers_compile.cpp`, `test_gfx_device`, `test_gfx_metal` | `chq_gfx_device.h`；`test_gfx_metal` **名字前缀是历史 `platform_apple_`，主题确为 Metal 渲染后端，按主题归 gfx** |
  | `media/` (17) | `media_frame_provider_compile.cpp`, `test_asset_registry`, `test_cache`, `test_decoder_pool`, `test_system_frame_provider`, `test_media_sequential_acquire`, `test_ffmpeg_probe`, `test_frame_provider_apple`, `test_media_smoke_apple`, `test_media_bframe_real_apple`, `test_media_sequential_real_apple`, `test_media_decode_apple`, `test_media_demux_apple`, `test_media_encode_apple`, `test_media_muxer_apple`, `test_media_muxer_audio_apple`, `test_native_image_importer_apple` | 特性是解封装/解码/编码/混流/取帧；`chq_media.h`/`chq_system_frame_provider.h` 只是接口落点 |
  | `preview/` (3) | `test_player_clock`, `test_preview_pump`, `test_preview_renderer` | `cq/preview/*` |
  | `render/` (1) | `test_render_graph` | `cq/render/chq_render_graph.h` 等 3 个 render 头 |
  | `model/` (2) | `test_model_timeline`, `test_model_property` | property 主导符号 `ChqPropertyValue`(43) > `ChqSetEffectParamCommand`(8) → 属模型侧 |
  | `command/` (1) | `test_model_command` | 主导符号是 Command 栈：`ChqInsertClipCommand`(12)/`ChqCommandHistory`(10)/`ChqAddTrackCommand`(9)，`ChqTimeline`(10) 只是载体 |
  | `audio/` (4) | `test_audio_pcm`, `test_audio_graph`, `test_audio_mix`, `test_preview_mixer` | `cq/audio/*`；`test_preview_mixer` 的头是 `chq_preview_mixer.h`、add_test 名 `core_audio_preview_mixer` |
  | `session/` (2) | `test_editor_session`, `test_thread_model` | `cq/session/*`；`test_thread_model` 名字前缀 `core_` 是历史遗留 |
  | `ai/` (1) | `test_edit_plan_validator` | `cq/ai/chq_edit_plan.h` |

  合计 6+8+3+3+17+3+1+2+1+4+2+1 = **51**，与 `git ls-files tests/unit | wc -l` 一致。
- 用 `git mv` 保留 blame。
- **本卡不改源码/文档注释里的旧路径**。实测活文件域有 **36 处 / 13 个文件**引用 `tests/unit/<平铺文件名>`：
  `engine/core/cq/cq_sdk.h:14`、`engine/core/cq/cq_sdk.cpp:7`、`engine/core/cq/base/chq_status.h:89`、
  `engine/core/cq/platform/chq_capabilities.cpp:8`、`engine/platform/apple/gfx/gfx_metal_internal.h:10`
  这 5 处源码注释，加 `.ai/modules/{core,media,platform,platform-apple,session,gfx}.md`、
  `.ai/memory/{pitfalls,baselines}.md`、`docs/specs/PLATFORM-接口契约.md`。
  其中 `cq_sdk.h` 属**高冲突文件**，全部统一交给 INFRA-034 的引用路径收口（已写入 034 写集与验收），
  避免本卡写集越界碰内核。
- `tests/CMakeLists.txt` 里 `unit/xxx.cpp` 共 **51 处**引用（实测 `grep -c "unit/"` = 51，
  且 51 行全部是 `add_executable` 的源路径，**没有**别的 `unit/` 用法），逐条改成 `unit/<module>/xxx.cpp`。
- ⚠️ 3 处 `ffprobe` 绝对路径在**单测源文件里**，不在 CMakeLists：
  `test_media_muxer_apple.cpp:208`、`test_media_muxer_audio_apple.cpp:262`、`test_media_encode_apple.cpp:196`，
  三处形状完全相同（`CQ_FFPROBE_BIN` 环境变量优先，否则硬编码 `/Users/zhuning/.workbuddy/...`）。
  改成 **env > `$HOME/.workbuddy/binaries/ffmpeg/bin/ffprobe`（用 `access(..., X_OK)` 判存在）> 裸 `ffprobe`（交给 shell 走 PATH）**，
  与 `tests/golden/generate.py:225-228` 的三档回退口径一致。不得只删硬编码 —— 本机 ffprobe 不在 PATH，
  直接退成裸 `ffprobe` 会让这三个用例从"过"变"失败/跳过"，破坏与迁移前的可比性。
- **搬家安全性取证**（2026-10-16 实测，全部为只读扫描）：
  - 16 处非 `cq/` 的本地 include（`media_decode.h`、`gfx_metal_internal.h`、`ai/plan/chq_edit_plan_validator.h`）
    由 `target_include_directories` 提供**绝对目录**，与源文件位置无关 → 移动后不必改 include。
  - 夹具路径全部走注入宏 `CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}"`（6 处）与
    `CQ_EDIT_PLAN_GOLDEN_DIR`（INFRA-029 已改），**不依赖 `__FILE__` 相对定位** → 移动后不必改。
  - `__FILE__` 只在 `test_preview_mixer.cpp:43` 的 `CHECK` 宏里用于打印失败位置，
    搬家后失败信息会变成 `tests/unit/audio/test_preview_mixer.cpp` —— 属预期，不改代码（STYLE-001 统一收编）。
- 基线落盘：`"$CTEST_BIN" --test-dir build -N | sed -n 's/^ *Test *#[0-9]*: //p' | sort`
  → **52 行**（`/tmp/ctest-names-before-030.txt`，2026-10-16 19:15 取，处于两次 configure 之间）。
  ctest 不在 PATH，取数用 `$HOME/.workbuddy/binaries/cmake/CMake.app/Contents/bin/ctest`（与 `build_core.sh:23` 同源）。
- 分组映射已用脚本校验过覆盖性（`/tmp/030-map.txt`）：12 目录 / 51 文件，
  未覆盖 = 0、拼写错 = 0、重复分配 = 0。执行时以该表为唯一依据，不再临场判断归属。

## 验收

见 yaml；必须贴出迁移前后 `ctest -N` 的两份计数与 diff 结果。

**实测（2026-10-16）**：

- `git ls-files tests/unit | wc -l` = **51**（迁移前后同数）；`find tests/unit -maxdepth 1 -type f` = **0**
  （根目录无平铺残留）；`find tests/unit -mindepth 1 -type d` = **12**（abi/ai/audio/base/command/gfx/
  media/model/platform/preview/render/session），无空壳目录
- **51 条全部以重命名入索引（`git status --porcelain tests/unit` = 48 `R ` + 3 `RM`），
  `git diff --cached -M --stat tests/unit` = 51 files changed, **0 insertions / 0 deletions** → blame 保住。
  3 条 `RM` 的 `M` 是下方 ffprobe 回退补丁，仍在工作区未入索引（纯搬家本身 0 内容改动）
- 用例名口径零变化：`add_test(NAME ...)` 仍是 **52** 条且 `git diff` 里 **0 行**涉及 `add_test`；
  `ctest -N` 排序输出 before(52) vs after(52) → **diff 为空**
- `tests/CMakeLists.txt` 的 51 条源路径全部改为 `unit/<module>/…`，
  改前脚本取证：occurrences 51 / unique 51 / mapping 缺项 0
- `grep -rn "/Users/zhuning" tests/unit` = **0**；3 个 apple 混流/编码用例的 ffprobe 回退改为
  env > `$HOME/.workbuddy/.../ffprobe`（`access(X_OK)` 判存在）> 裸 `ffprobe`，并各加 `#include <unistd.h>`
- Debug 窄检：`tools/build/build_core.sh --platform=apple --test` → **`100% tests passed out of 52`**，
  real 180.83s，exit 0
- 全量门禁：**PASS=15 / FAIL=0 / SKIP=0**（exit 0；数字同上，逐段见 `.ai/modules/core.md` 模块册与
  `.ai/memory/baselines.md`）
- 双壳构建（「每批窄检 + 双壳构建」纪律，P129 配方）：**4 步全部 exit 0**
  - `apps/apple/ios` `LANG=en_US.UTF-8 bundle exec pod install` → **14 dependencies / 14 total pods installed**
  - `apps/apple/mac` 同款 → **7 dependencies / 7 total pods installed**
  - 两份 `Podfile.lock` **零 diff**（本卡只动 `tests/**`，pod 根未碰 —— 这是搬家正确性的直接证据）
  - ios `xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build`
    → **BUILD SUCCEEDED**，`error:` 0 行 / `warning:` 24 行（全为既有 `IPHONEOS_DEPLOYMENT_TARGET 9.0`
    与 SHADER-001 run-script「无输出项故每次都跑」告警，不属本卡）
  - mac `-scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build` → **BUILD SUCCEEDED**，
    `error:` 0 行 / `warning:` 6 行

**执行中踩到的自己的坑（登记，防复发）**：本工具链的 shell 是 **zsh**，
`for f in $rest` 与 `set -- $files` **不做词分割**（zsh 默认不 split 未加引号的变量），
第一次搬家脚本因此把"整行文件名串"当成目录名，`mkdir -p` 造出 8 个含空格的畸形目录名
（另有 3 条报 `File name too long`）。**没有任何文件被移动**（脚本静默跳过），
用 `find tests/unit -mindepth 1 -type d -empty -delete` 清掉后改用 `bash -c '…'` 重跑才正确。
教训：**批量 `git mv` 一律显式 `bash -c`，或在 zsh 里用 `${=var}` / 数组**；
且每次批量搬家后必须核 `find <根> -maxdepth 1 -type f` 与 `git status --porcelain` 的重命名条数，
不能只看 `git ls-files | wc -l` 对得上就收工。

## 回写

- 测试目录形态 → `.ai/modules/core.md` 模块册「测试与门禁记录」段（已登记）
- 日志 → `.workbuddy/memory/2026-10-16.md`
- 遗留：`tests/unit/<平铺名>` 的引用面按本卡「不改源码/文档注释里的旧路径」条款**整体交给 INFRA-034**；
  执行后新增一条待回填点：仓库根 `CMakeLists.txt:14` 的注释 `tests/unit/test_c_abi.c`（已补进 034 清单）
