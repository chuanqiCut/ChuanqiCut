# ChuanqiCut 文档索引

> 新人（或新 Agent）从这里开始。

## 三步上手

```bash
cat AGENTS.md                          # 1. 根规则（自动加载）
cat .ai/modules/<你负责的模块>.md        # 2. 模块上下文
cat docs/tasks/TASK-<ID>.md            # 3. 你的任务
```

---

## 一、调研与评审

| 文档 | 说明 |
|---|---|
| [`research/RESEARCH-001-现有调研文档批判性评审与事实核验.md`](research/RESEARCH-001-现有调研文档批判性评审与事实核验.md) | **先读这份**。对仓库原有 6 份调研文档的批判性评审：10 条事实性错误、7 项结构性矛盾裁决、14 项缺失工程主题、保留/修正/废弃清单 |

### 历史调研文档（已被评审，结论见 RESEARCH-001）
- `../技术方案决策书.md` — **已被 ARCH-001 取代**，保留作历史记录
- `../技术调研_视频管线全链路技术细节.md` — 20 个管线环节的算法原理，**保留为算法参考**
- `../技术调研_系统API局限性与FFmpeg取舍分析.md` — seek/变速/倒放的边界分析，结论被 ADR-0003 采纳
- `../技术调研_管线选型决策表.md`、`../技术调研_关键架构补遗.md`、`../技术调研_MediaPipe加速与系统API对比.md`、`../技术调研_剪辑软件技术方案分析.md` — 保留为素材

---

## 二、技术方案

| 文档 | 说明 |
|---|---|
| [`specs/ARCH-001-技术方案总纲.md`](specs/ARCH-001-技术方案总纲.md) | **主方案**：定位、平台路线、分层、时间模型、线程模型、工程结构、门禁、里程碑 |
| [`specs/ARCH-002-依赖治理与开源SDK能力管理.md`](specs/ARCH-002-依赖治理与开源SDK能力管理.md) | 开源库管理机制：双集成（源码/二进制）、能力裁剪（FFmpeg 三档位）、协议门禁、SBOM |
| [`specs/ARCH-003-跨平台内核与GPU-Shader策略.md`](specs/ARCH-003-跨平台内核与GPU-Shader策略.md) | C++ 内核、薄 GFX 抽象、SPIR-V shader 工具链、RenderGraph、色彩、容差、内存预算 |
| [`specs/ARCH-004-平台适配矩阵与Android-HarmonyOS落地.md`](specs/ARCH-004-平台适配矩阵与Android-HarmonyOS落地.md) | 四平台能力矩阵、运行时能力查询、Apple 要点、**Android 落地方案**、**鸿蒙预留** |
| [`specs/ARCH-005-UI层策略与工程结构.md`](specs/ARCH-005-UI层策略与工程结构.md) | UI 为什么不共享、各端选型、绑定层设计、时间线性能要求 |

---

## 三、决策记录（ADR）

| ADR | 决策 |
|---|---|
| [`0001`](decisions/ADR-0001-采用C++共享内核.md) | 采用 C++20 共享内核，UI 各端原生；废弃 KMP |
| [`0002`](decisions/ADR-0002-薄GPU抽象与Shader中间表示.md) | 自研薄 GFX 抽象 + SPIR-V 中间表示；不引入 MetalPetal，不走 MoltenVK 统一 |
| [`0003`](decisions/ADR-0003-FFmpeg仅Demux与能力裁剪.md) | FFmpeg 定位为可选 demux/seek 后端，默认 demux-only 档位 |
| [`0004`](decisions/ADR-0004-以signalsmith-stretch替代SoundTouch.md) | 以 signalsmith-stretch (MIT) 替代 SoundTouch (LGPL) |
| [`0005`](decisions/ADR-0005-共享模型资产不共享推理SDK.md) | AI 推理共享模型资产，不共享推理 SDK；后处理在 C++ 共享 |
| [`0006`](decisions/ADR-0006-有理数时间与项目文件版本模型.md) | 有理数时间 + schema 版本与迁移器链 |
| [`0007`](decisions/ADR-0007-鸿蒙作为可选项的架构预留.md) | 鸿蒙 P2 可选，本期只做接口编译检查 |
| [`0008`](decisions/ADR-0008-FFmpeg本地git管理与依赖版本锁定.md) | FFmpeg 走 GitHub 官方镜像 + 本地 git 管理；源码依赖一律锁 commit，「定期拉最新」= 人工 bump 而非跟随 HEAD |

---

## 四、任务

| 文档 | 说明 |
|---|---|
| [`tasks/TASK-BACKLOG.md`](tasks/TASK-BACKLOG.md) | **118 个任务**，按 UI / SDK / 跨平台 / 基建 分层，含依赖、写集、验收、并行批次、关键路径 |
| `tasks/TASK-*.md` | **任务单卡**（按 `.ai/templates/task.md` 逐个生成，进入某 Phase 前先生成该 Phase 的卡）。已生成：`INFRA-001`、`INFRA-002`、`CORE-001`、`CORE-006` |

---

## 五、AI 协作

| 文档 | 说明 |
|---|---|
| [`ai/HANDOFF-001-编码阶段会话交接.md`](ai/HANDOFF-001-编码阶段会话交接.md) | **准备写代码时先读这份**。为什么新开会话、开场 prompt 模板、会话切分规则、Phase 0 开局顺序、我的能力边界 |
| [`ai/AI-COLLAB-001-上下文工程与Skill体系.md`](ai/AI-COLLAB-001-上下文工程与Skill体系.md) | 上下文分层、项目 Skill、记忆回写规则、多人协作规则 |
| `../.ai/modules/*.md` | 15 份模块上下文 |
| `../.ai/memory/*.md` | pitfalls / baselines / device-matrix |
| `../.agents/skills/*/SKILL.md` | 8 个项目技能 |
| `../.ai/source/AGENTS.root.md` | 根规则真源（各工具入口文件由 `tools/ai/sync_context.py` 生成） |

---

## 六、状态

- 方案文档：**v1.0，待 Review**
- 性能基线：**尚未建立**（`PERF-001` 完成后填充，在此之前所有性能数字均为估算）
- 代码：**骨架阶段**（INFRA-001 已落地 monorepo 目录骨架与 CMake 顶层入口；真实内核逻辑由 CORE 系列任务填充）

---

## 七、工程目录骨架（INFRA-001）

> 由 `TASK-INFRA-001` 建立。权威目录树见 [`specs/ARCH-001-技术方案总纲.md` §8 工程仓库结构]；本仓库的实际落盘结构以该节为准。

顶层目录（CMake 可识别的入口）：

| 目录 | 角色 | 本任务落盘内容 |
|---|---|---|
| `core/` | C++20 共享内核 | `CMakeLists.txt`（占位 `cq_core`）、`include/cq/cq_sdk.h`（占位伞形头）、`src/`、`tests/` |
| `pal/apple` · `pal/android` · `pal/ohos` | 平台适配 | 各 `CMakeLists.txt`（占位 `cq_pal_<platform>`）；ohos 仅预留 |
| `apps/apple` · `apps/android` · `apps/ohos` | 原生 UI 壳 | 各 `CMakeLists.txt`（占位 `cq_<platform>_app`；真实构建走 Xcode/Gradle/Hvigor） |
| `third_party/` | 第三方依赖 | `CMakeLists.txt`（占位，**本期不引入依赖**）；`manifest.toml` 由依赖治理任务维护 |
| `tools/` | 构建/工具脚本 | `CMakeLists.txt`（占位 `cq_tools`）；子目录 `build/shaders/ai/compliance` 预留 |
| `tests/` | 内核单测 | `CMakeLists.txt`（`enable_testing()` + 占位 `cq_tests`） |
| `shaders/` · `bindings/` | shader 源 / 语言绑定 | 仅占位目录（`.gitkeep`），实现归各自任务 |
| `build/` | CMake 构建产物 | **不入库**（已写入 `.gitignore`） |

构建验证（需先安装 `cmake`，本环境尚未安装）：

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --target help    # 应能看到 cq_core / cq_pal_* / cq_*_app / cq_third_party / cq_tools / cq_tests
```
