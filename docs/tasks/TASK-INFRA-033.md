# TASK-INFRA-033：shader 两半并入 `engine/shaders/{portable,native}/`

```yaml
id:          TASK-INFRA-033
layer:       SDK
goal:        Portable GLSL 从顶层 shaders/src 并入 engine/shaders/portable，Platform-Native 落 engine/shaders/native/<os>，
             同时删掉空残壳 shaders/generated 并修订 AGENTS 红线 #6 的路径措辞
input:       [ADR-0044 决策 4, cq-shader-portability, engine/platform/apple/CMakeLists.txt:45-77]
output:      [engine/shaders/portable/{blit.vert,blit.frag}, engine/shaders/native/README.md（预留说明）,
              engine/platform/apple/CMakeLists.txt 路径, tools/shaders/build_shaders.py 输入根,
              .ai/source/AGENTS.root.md 红线 #6 + 5 个生成物, 删除顶层 shaders/]
write_set:   shaders/**（迁出即删）→ engine/shaders/**, engine/platform/apple/CMakeLists.txt,
             tools/shaders/build_shaders.py, .ai/source/AGENTS.root.md,
             AGENTS.md / CLAUDE.md / .cursorrules / .github/copilot-instructions.md / .windsurfrules
             （**只能由 tools/ai/sync_context.py 生成**）
read_set:    .gitignore（027 已预声明 shaders/generated 兼容规则）, docs/BUILD.md
deps:        [TASK-INFRA-032]     # 串行：032 改 pod 根后 podspec 文件清单才稳定
acceptance:
  - `git ls-files engine/shaders | wc -l` = 3（blit.vert / blit.frag / native/README.md）
    且 `git ls-files shaders | wc -l` = 0
  - MSL 生成链仍然产出真实头文件：`ls build/generated/shaders/` 非空且 blit MSL 头大小 > 0
    （产物位置不变：`engine/platform/apple/CMakeLists.txt:59` 指向 `CMAKE_BINARY_DIR/generated/shaders`）
  - `-Werror` 编译通过，ctest 用例数与本批开始前一致
  - 红线 #6 措辞已改：`grep -n "engine/shaders/portable" .ai/source/AGENTS.root.md` 命中，
    且 5 个生成物与真源一致（重跑 `python3 tools/ai/sync_context.py` 后 `git diff --stat` 对这些文件为零变化）
  - `python3 tools/platform/check_platform_headers.py` 退出码 0，且其输出的
    `scanned N header(s)` 中 N 与本批开始前相同（该脚本扫的是 `engine/core/cq`，本批不该动它；
    N 变了说明误改了扫描根）
verification:
  - tools/build/build_core.sh --platform=apple --test 2>&1 | tail -20
  - ls -l build/generated/shaders/
  - python3 tools/ai/sync_context.py && git diff --stat -- AGENTS.md CLAUDE.md .cursorrules .windsurfrules .github/copilot-instructions.md
risk:        shader 是**双端一致性的基线**：Portable 层禁止平台扩展，搬目录时不得顺手把
             `.glsl` 改成平台方言（cq-shader-portability 四条硬约束）。
             另一个坑是生成链静默失效：如果 DEPENDS 路径写错而产物已在 build/ 里，构建会复用旧头并报绿
             —— 必须 `--clean` 或删 `build/generated/` 重跑一次，确认产物由新路径重新生成。
parallel:    false（动 shader 与 AGENTS 真源，须单独成批）
```

## 背景

AGENTS.md 红线 #6 描述的两层 shader 现实中分居两处：Portable 在仓库根 `shaders/src/`，
Platform-Native 约定在 `platform/<p>/shaders/`（目前该目录不存在；真实平台特化产物是
`ui/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/Effects/*.metal` 三个（INFRA-031 前在
`apps/apple/packages/` 下），属 App 侧相机效果，不并入本模块）。
仓库根 `shaders/generated/` 是**空残壳**：`.gitignore:44-45` 已把新旧两个落点各写一条（INFRA-027 预声明），
真实产物一直落在
`build/generated/shaders/`（`engine/platform/apple/CMakeLists.txt:59` 的 `CQ_GENERATED_SHADER_DIR`）。

## 实现要点

- 三个 `.metal` **不**并入 `engine/shaders/native/`：它们在 UI Pod 内、随 App bundle 编译
  （且 ADR-0031 阶段 4 的实测结论是 script_phase 产物到不了 App bundle，见 P85），
  属于相机效果实现而非引擎 shader 模块。本卡只建 `engine/shaders/native/README.md` 说明预留与边界。
- `DEPENDS` 里两条源路径与 `build_shaders.py` 的输入根必须同批改，否则增量构建假绿（见 risk）。
  实测改动点：`engine/platform/apple/CMakeLists.txt:69-70`（DEPENDS 两条）、
  `tools/shaders/build_shaders.py:104` 的 `src_dir = repo_root / "shaders" / "src"`（**代码级，唯一的真路径构造**），
  外加同脚本 `:4/:17/:20/:42/:44/:46` 的注释与产物头 banner。
  `engine/ChuanqiCutCore.podspec:66` 只调脚本并传 `--repo-root`，**不含** `shaders/src` 字面 → 本批不动 podspec（属 032 写集）；
  `tools/ci/run_gate.sh` 对 shader 零命中 → 也不动。
- 本批**不**改 README/周报里的目录树描述（`README.md:16,184,388` 仍写 `shaders/src/`）：
  `README.md` 属 034 写集，由末批统一回填，避免两批碰同一文件。

## 验收

见 yaml；必须报告 check_platform_headers.py 的扫描文件数前后值与 MSL 产物字节数。

## 实测（2026-10-16 22:2x~22:42，本机 = 集成机，模块级窄检）

**没有跑全量 15 步门禁** —— shader 与真源改动只碰构建路径，验收性数字归末批 INFRA-034 一趟。

| 判据 | 数字 |
|---|---|
| tracked 形态 | `git ls-files engine/shaders` = **3**（`portable/blit.vert` / `portable/blit.frag` / `native/README.md`）；`git ls-files shaders` = **0** 且磁盘上 `shaders/` 已不存在 |
| 防"增量复用假绿" | 先 `rm -rf build/generated` 再 `tools/build/build_core.sh --platform=apple --test` → **exit 0**；日志 `[27%] SHADER-001: glslang → SPIR-V → spirv-cross → MSL (blit)` 真实执行、`[shaders] 生成 …/build/generated/shaders/blit_msl.h` |
| 编译 + 单测 | `error:` **0** 行（`-Werror` 生效）；`ctest` **100% tests passed out of 52**，real **135.17s** —— 用例数与本批开始前一致 |
| MSL 产物字节 | `spv/blit.vert.spv` **960B** / `spv/blit.frag.spv` **548B** / `msl/blit.vert.metal` **418B** / `msl/blit.frag.metal` **410B** —— 四条与搬家前**逐字节相等**；`blit_msl.h` **1665B → 1689B** |
| +24B 差额可解释 | 用 `git show HEAD:tools/shaders/build_shaders.py` 与现版逐行比 `HEADER_BANNER`：仅两行路径字面变化，各 **+12B**（`shaders/src/*.glsl` → `engine/shaders/portable/*.glsl`；`来源：shaders/src/blit.vert / blit.frag` → 同前缀），合计 **+24B** → 与产物差额**精确相等**，证明是 banner 而非转译结果变了 |
| GLSL 代码等价 | 剥离 `//` 注释后 md5 与 `HEAD:shaders/src/*` 相同（vert `568b81024e9e24d46e75f60fa0775eda`、frag `687a47617c0344e74f95f849726783d4`）→ 红线 #6「Portable 禁平台扩展」没被顺手破 |
| 扫描根未误改 | `python3 tools/platform/check_platform_headers.py` → `scanned **43** header(s) … **0** violation(s)`，exit 0 —— 前后值都与 INFRA-032 基线逐字相同 |
| 入口一致性 | `python3 tools/ai/sync_context.py` 后 `--check` → "所有入口文件与真源一致"；`grep -n engine/shaders/portable .ai/source/AGENTS.root.md` 命中红线 #6（:21）|

**实测后追加的改动（yaml 之外，均属同批改路径）**：
- `engine/platform/apple/CMakeLists.txt` 的 `add_custom_command` 末行原是脱敏残留
  `    其编辑器组件)`（`git log -S` 追到 commit `6ccf29b B0`，全仓唯一受害代码文件）→ 按 CMake 惯例补
  `VERBATIM)`。**原词不可考**，靠"清缓存重生成 + 编译 + ctest 全绿"证明行为不变。
- 写集**扩张 2 个文件**（超出 yaml，须如实登记）：`engine/core/cq/platform/chq_gfx.h` 注释 2 处
  （SPIR-V 链"尚未落地"的过期自陈 + `platform/<platform>/shaders/` → `engine/shaders/native/<platform>/`）、
  `engine/shaders/portable/blit.vert:8` 同一路径措辞。理由：这两处是**本批搬家直接判为过期**的规范句，
  留给 034 会让下一个 agent 按 `platform/<platform>/shaders/` 建目录。
- `.ai/modules/shader.md` 4 处路径 + §二 Platform-Native "位置"行改成 `engine/shaders/native/<platform>/`（本期为空）；
  `.agents/skills/cq-shader-portability/SKILL.md` 4 处（含把两条**不存在的脚本**换成真实命令）、
  `.agents/skills/cq-build-test/SKILL.md` 的"tools/shaders/ 目前是占位"假陈述换成生成器实命令。
- **回写落点纠正**：yaml 与本卡原写 `.ai/modules/gfx.md`，实测 `grep -n "shaders/src\|blit_msl\|generated/shaders" .ai/modules/gfx.md`
  = **零命中** → shader 目录树与生成链归口 `.ai/modules/shader.md`（模块册两行已落）。

## 残留（登记给 INFRA-034，非本批写集）

- `README.md` **3 行**：:16 / :184 / :389 仍写 `shaders/src/`（README 属 034 写集，避免两批碰同一文件）。
- `docs/specs/ARCH-003-跨平台内核与GPU-Shader策略.md` **2 行**：:88 架构图框名、:130「位置约束」规范句
  （`platform/<platform>/shaders/` 已作废）。specs **不在红线 5 豁免目录**内 → 属活文档债。
- 旧落点的死忽略规则：`.gitignore:44` 与 `.zcodeignore:48` 的 `shaders/generated/`（目录整个不存在了）。
  `:45` / `:49` 的 `engine/shaders/generated/` **保留** —— 落点树现在活着，产物实际走
  `build/generated/shaders/`，这条是零成本的防御性规则（034 卡已按"删 2 留 2"登记）。
- **与本批无关的既有死引用**：`.ai/modules/platform.md:144`、`.ai/modules/preview.md:152` 指向
  `platform/apple/shaders/blit_fullscreen_msl.h` —— 该文件在仓库里**根本不存在**（`git ls-files | grep blit_fullscreen_msl` = 0，
  B0 手写内联 MSL 退役时就没删干净引用），034 一并清。

## 回写

- AGENTS 真源 + 5 生成物（本卡已含，`sync_context.py --check` 绿）
- `.ai/modules/shader.md`：shader 目录树与生成链 + 模块册两行（**不是 gfx.md**，见上"回写落点纠正"）
- `docs/tasks/TASK-INFRA-034.md`：写集行、零残留 grep pattern 扩 `shaders/src` / `shaders/generated`、
  实测基线重测（README **3** / docs/README **1** / BUILD **1** / COCOAPODS **4** / specs **16 行 11 份**、
  .agents/skills **0** / .ai/modules **5**，历史标注逐条判不改）、死忽略规则清理扩成"删 4+2 留 2"
- 日志 → `.workbuddy/memory/2026-10-16.md`

