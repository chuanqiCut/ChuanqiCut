# ChuanqiCut 文档地图

> 新人（或新 Agent）从这里开始。本文件只描述**文档体系的结构与规则**（稳定内容）；
> 项目当前进展一律看 [`handoff/`](handoff/)（会话级状态）与 [`tasks/TASK-BACKLOG.md`](tasks/TASK-BACKLOG.md)（任务状态），
> **不在本文件里维护状态快照** —— 状态写在索引里必然过期（本文件 v1 版即是教训）。

## 三步上手

```bash
cat AGENTS.md                          # 1. 根规则（自动加载）
cat .ai/modules/<你负责的模块>.md        # 2. 模块上下文
cat docs/handoff/HANDOFF-004-*.md      # 3. 最近交接（状态以最新一份为准）
```

---

## 一、文档分层（六层）

```
调研 RESEARCH ──评审──▶ 决策 ADR ──展开──▶ 方案 ARCH ──拆解──▶ 规格 SPEC
                                                              │ 拆解
                                                              ▼
教训 pitfalls / 数据 baselines ◀──回写── 执行 TASK（BACKLOG 总账 + 单卡）──▶ 交接 HANDOFF
```

| 层 | 目录 | 回答的问题 | 生命周期 |
|---|---|---|---|
| **调研** | `research/` | 事实是什么？有哪些选项？ | 一次性产出；结论被 ADR/SPEC 吸收后转为素材 |
| **决策** | `decisions/` | 选了哪条路？为什么？ | 追加式（append-only），只标"已取代"不删改 |
| **方案** | `specs/ARCH-*` | 系统怎么架构？ | 随实现演进，大改需挂 ADR |
| **规格** | `specs/<域>-*` | 某功能做什么？验收是什么？ | 随任务实现更新 |
| **执行** | `tasks/` | 谁在做什么？做到哪了？ | BACKLOG 是总账 DAG；每任务一张单卡 |
| **交接** | `handoff/` | 下个会话从哪继续？ | 新会话新文件，旧文件只作历史参考 |

支撑层（不在 docs/ 下）：`.ai/modules/`（模块上下文）、`.ai/memory/`（pitfalls / baselines / env）、
`.workbuddy/memory/`（日志与长期约定）、`.agents/skills/`（项目技能）。
完整规则见 [ADR-0019](decisions/ADR-0019-文档体系分层与归档规则.md)。

---

## 二、调研（research/）

| 文档 | 说明 |
|---|---|
| [`RESEARCH-001-现有调研文档批判性评审与事实核验.md`](research/RESEARCH-001-现有调研文档批判性评审与事实核验.md) | 对第一代 7 份调研的批判性评审：10 条事实错误、7 项矛盾裁决、14 项缺失主题、§5 保留/修正/废弃处置表。**引用第一代文档前先读它** |
| [`RESEARCH-002-相机采集与实时特效链路调研.md`](research/RESEARCH-002-相机采集与实时特效链路调研.md) | 相机域调研（2026-10-04），上游为 ADR-0014 / SPEC-CAM-001 |
| [`RESEARCH-003-智能成片竞品调研.md`](research/RESEARCH-003-智能成片竞品调研.md) | 智能成片竞品调研（剪映图文成片 / iMovie / 必剪等），下游 ADR-0020 / AIEDIT-001 |
| [`RESEARCH-004-拍摄与编辑UI主流方案调研.md`](research/RESEARCH-004-拍摄与编辑UI主流方案调研.md) | 拍摄与编辑 UI 主流方案调研 |
| [`RESEARCH-005-功能面板信息架构与四端布局调研.md`](research/RESEARCH-005-功能面板信息架构与四端布局调研.md) | 功能面板信息架构与四端布局调研，下游 UIA-019 |
| [`RESEARCH-006-独立播放器内核与交互调研.md`](research/RESEARCH-006-独立播放器内核与交互调研.md) | 独立播放器内核选型（AVPlayer 过渡 vs 自研 C++ session vs FFmpeg/mpv 等 8 方案对比）与交互范式（一线产品手势/控制层/键盘/无障碍），支撑 SPEC-UIA-020 与 ADR-0022 |
| [`RESEARCH-007-顶级拍摄剪辑App布局与操作逻辑深度调研.md`](research/RESEARCH-007-顶级拍摄剪辑App布局与操作逻辑深度调研.md) | 全球顶级拍摄/剪辑 App 的控件分区、手势与面板切换规则深拆（18 家），§5 delta 表为编辑域 Spec 的操作层输入（建议位编号备注见文内） |
| [`RESEARCH-008-剪映移动端编辑页范式与框架选型.md`](research/RESEARCH-008-剪映移动端编辑页范式与框架选型.md) | 剪映移动端编辑页范式拆解 + SwiftUI/UIKit 框架选型，下游 ADR-0024 / BACKLOG §12（**原 006，2026-10-07 撞号让位改号**） |
| `legacy/`（7 份） | 第一代调研素材（2026-09-23 前）：6 份 `技术调研_*.md` + `技术方案决策书`。**只读**，每份头部有状态横幅；性能数字一律 [E]、结论已被评审修正 |

**规则**：新的调研产出一律建 `RESEARCH-00x-<标题>.md`（编号纪律见 ADR-0019）；
被评审淘汰的原始材料放 `legacy/` 加横幅，**不删除**——它们是 RESEARCH-001 的评审对象与证据。

---

## 三、决策记录（decisions/，ADR-0001 ~ 0024）

| ADR | 决策 |
|---|---|
| [0001](decisions/ADR-0001-采用C++共享内核.md) | 采用 C++20 共享内核，UI 各端原生；废弃 KMP |
| [0002](decisions/ADR-0002-薄GPU抽象与Shader中间表示.md) | 自研薄 GFX 抽象 + SPIR-V 中间表示；不引入 MetalPetal |
| [0003](decisions/ADR-0003-FFmpeg仅Demux与能力裁剪.md) | FFmpeg 定位为可选 demux/seek 后端，默认 demux-only 档位 |
| [0004](decisions/ADR-0004-以signalsmith-stretch替代SoundTouch.md) | 以 signalsmith-stretch (MIT) 替代 SoundTouch (LGPL) |
| [0005](decisions/ADR-0005-共享模型资产不共享推理SDK.md) | AI 推理共享模型资产，不共享推理 SDK |
| [0006](decisions/ADR-0006-有理数时间与项目文件版本模型.md) | 有理数时间 + schema 版本与迁移器链 |
| [0007](decisions/ADR-0007-鸿蒙作为可选项的架构预留.md) | 鸿蒙 P2 可选，本期只做接口编译检查 |
| [0008](decisions/ADR-0008-FFmpeg本地git管理与依赖版本锁定.md) | FFmpeg 走官方镜像 + 本地 git；源码依赖锁 commit |
| [0009](decisions/ADR-0009-项目timescale修正为120000.md) | 项目 timescale 60000 → 120000 |
| [0010](decisions/ADR-0010-平台支持基线与开发参数.md) | 平台支持基线与开发参数 |
| [0011](decisions/ADR-0011-core调用PAL工厂的隔离规则.md) | core 调用 PAL 工厂的隔离规则 |
| [0012](decisions/ADR-0012-时间线交互的命令提交时机与撤销栈线程边界.md) | 时间线交互的命令提交时机与撤销栈线程边界 |
| [0013](decisions/ADR-0013-相机特效Shader先行Native层与Portable欠账.md) | 相机特效 Shader：Native 层先行 + Portable 欠账 |
| [0014](decisions/ADR-0014-相机模块采用iOS原生栈.md) | **相机模块采用 iOS 原生栈**（相机域豁免 PAL/C ABI） |
| [0015](decisions/ADR-0015-相册选择器系统过渡与自研浏览器.md) | 相册选择器：系统 picker 过渡 + 自研浏览器 |
| [0016](decisions/ADR-0016-预览取帧的线程归属与共享命令队列.md) | 预览取帧的线程归属与共享命令队列 |
| [0017](decisions/ADR-0017-顺序取帧快路径与解码器显示序重排.md) | 顺序取帧快路径与解码器显示序重排 |
| [0018](decisions/ADR-0018-预览宽高比的视口接缝.md) | 预览宽高比的视口接缝 |
| [0019](decisions/ADR-0019-文档体系分层与归档规则.md) | **文档体系分层与归档规则**（本地图的权威定义） |
| [0020](decisions/ADR-0020-智能成片与大模型接入边界.md) | 智能成片与大模型（LLM）接入边界（特征上云/素材不出设备/EditPlan 校验） |
| [0021](decisions/ADR-0021-CoreImage-kernel不走Xcode内建Metal阶段.md) | CIKernel 构建链路：`.metal` 用 `metal -fcikernel` 编，不走 Xcode 内建 Metal 阶段 |
| [0022](decisions/ADR-0022-独立播放器AVPlayer过渡与内核演进接缝.md) | 独立播放器 AVPlayer 过渡 + `PlayerEngine` 接缝与 C++ session 演进触发条件 |
| [0023](decisions/ADR-0023-外挂字幕解析层归属.md) | 外挂字幕解析层归属（Swift 过渡性豁免与下沉 C++ 反转条件） |
| [0024](decisions/ADR-0024-编辑页UIKit混合.md) | 编辑页核心三件套采用 UIKit（SwiftUI 外壳混合装配；**原 0022，2026-10-07 撞号让位改号**） |
| [0029](decisions/ADR-0029-双机分工与门禁跑批节奏.md) | 双机分工与门禁跑批节奏（模块归属表 / 开发机编码优先简化档 / 待办池 / 集成机日批；0025~0028 预占素材库多轨，下一号 0030） |
| [0030](decisions/ADR-0030-模块册分册制与阶段批门禁节奏.md) | 模块册分册制与阶段批门禁节奏（调研/任务/进度/测试门禁记录按模块归口；全局册单写者；日批→阶段批，修订 0029） |
| [0031](decisions/ADR-0031-主工程壳化与功能Pod分治.md) | 主工程壳化与功能 Pod 分治（草稿/素材管理/播放器/拍摄/素材导入各自 podspec；基座 SharedUI 瘦身；横向零依赖） |

**规则**：改变既有惯例/架构约束必须新增 ADR；取号前先 `git fetch`（双机并行撞号纪律见 ADR-0019 §4）。

---

## 四、方案与规格（specs/）

`specs/` 内部按前缀分四类，命名 `<域>-<编号>-<标题>.md`：

| 前缀 | 类型 | 文档 |
|---|---|---|
| `ARCH-` | **架构方案** | [ARCH-001 技术方案总纲](specs/ARCH-001-技术方案总纲.md)（主方案）· [ARCH-002 依赖治理](specs/ARCH-002-依赖治理与开源SDK能力管理.md) · [ARCH-003 内核与GPU-Shader策略](specs/ARCH-003-跨平台内核与GPU-Shader策略.md) · [ARCH-004 平台适配矩阵](specs/ARCH-004-平台适配矩阵与Android-HarmonyOS落地.md) · [ARCH-005 UI层策略](specs/ARCH-005-UI层策略与工程结构.md) |
| `<功能域>-` | **功能 Spec** | [CAM-001 相机与首页](specs/CAM-001-相机与首页.md) · [UIA-002 编辑器主框架](specs/UIA-002-编辑器主框架.md) · [UIA-011 相册素材导入](specs/UIA-011-相册素材导入.md) · [UIA-012 相册多选批量导入](specs/UIA-012-相册多选批量导入.md) · [UIA-013 自研相册浏览器](specs/UIA-013-自研相册浏览器.md) · [UIA-019 统一面板框架与四端布局](specs/UIA-019-统一面板框架与四端布局.md) · [AIEDIT-001 智能成片](specs/AIEDIT-001-智能成片.md) |
| `PAL-` | **接口契约** | [PAL-接口契约](specs/PAL-接口契约.md)（§4 = GFX/Media 契约，被 `.ai/modules/pal.md`、`gfx.md`、`media.md` 引用） |
| `AI-ENG-` | **工程方法规范** | [AI-ENG-001](specs/AI-ENG-001.md)（AI 原生研发工作流） |

**规则**：新功能 Spec 用功能域前缀（如 `EXPORT-001`），不新造前缀体系；接口契约改动同步 `.ai/modules/pal.md`。

---

## 五、任务（tasks/）

| 文档 | 角色 |
|---|---|
| [`TASK-BACKLOG.md`](tasks/TASK-BACKLOG.md) | **任务总账**：118 个任务的 DAG，按层分组，含依赖/写集/验收/并行批次/关键路径 |
| `TASK-<ID>.md` | **任务单卡**（按 `.ai/templates/task.md` 生成），进入某任务前建卡 |
| `PLAN-*.md` | **领域规划**：[三线并行](tasks/PLAN-三线并行.md)（双机分工+号段）· [播放器进阶](tasks/PLAN-播放器进阶.md) · [素材库草稿混排多轨](tasks/PLAN-素材库草稿混排多轨.md) · [壳工程与功能Pod](tasks/PLAN-壳工程与功能Pod.md) |
| [`README.md`](tasks/README.md) | **已建卡登记表**（33 张）与建卡流程 |

**规则**：任务事实源 = BACKLOG + 单卡（BACKLOG §8）；完成判定由门禁决定，不由执行者自述。

---

## 六、交接（handoff/）

| 文档 | 覆盖 |
|---|---|
| [HANDOFF-001](handoff/HANDOFF-001-编码阶段会话交接.md) | 方案会话 → 编码会话的切换规则（含开场 prompt 模板，方法论仍有效） |
| [HANDOFF-002](handoff/HANDOFF-002-编码阶段会话交接.md) | 编码阶段交接（历史） |
| [HANDOFF-003](handoff/HANDOFF-003-编码阶段会话交接.md) | 编码阶段交接（历史） |
| [HANDOFF-004-编码阶段会话交接](handoff/HANDOFF-004-编码阶段会话交接.md) | **编辑器线**当前状态（UIA / BIND / MEDIA 线） |
| [HANDOFF-004-相机模块会话交接](handoff/HANDOFF-004-相机模块会话交接.md) | **相机线**当前状态（CAM 线，随 CAM 系列任务持续刷新） |
| [HANDOFF-005-智能成片会话交接](handoff/HANDOFF-005-智能成片会话交接.md) | **智能成片线**当前状态（AIEDIT-000~011 立项轮，RESEARCH-003/ADR-0020/SPEC） |
| [HANDOFF-006-音频线会话交接](handoff/HANDOFF-006-音频线会话交接.md) | **音频线**当前状态（AUDIO-001 已落地：池/环/图骨架；下一步 AUDIO-004 或 PALA-030） |

| [HANDOFF-006-MEDIA播放链路会话交接](handoff/HANDOFF-006-MEDIA播放链路会话交接.md) | **MEDIA 播放链路**当前状态（MEDIA-021/023~027 + CORE-010 日志设施，含真机复现手法） |

**规则**：新交接取下一个编号（下一份 = 007）；双线并行期间允许**同号双卡**（后缀区分主题），
引用时务必带主题（"HANDOFF-004 相机版 §x"）。状态核对必须对着 commit 历史与门禁数字，不照抄上一版（pitfalls E10）。

---

## 七、AI 协作（ai/）

| 文档 | 说明 |
|---|---|
| [`ai/AI-COLLAB-001-上下文工程与Skill体系.md`](ai/AI-COLLAB-001-上下文工程与Skill体系.md) | 上下文分层、项目 Skill、记忆回写规则、多人协作规则 |
| [`ai/AI原生软件工程系统落地记录.md`](ai/AI原生软件工程系统落地记录.md) | 工程方法体系的落地叙事（从根目录归位） |
| `../.ai/modules/*.md` | 18 份模块上下文 |
| `../.ai/memory/*.md` | pitfalls（P 编号，append-only）/ baselines（实测数据）/ env / device-matrix |
| `../.agents/skills/*/SKILL.md` | 8 个项目技能（构建、媒体管线、shader 治理等） |
| `../.ai/source/AGENTS.root.md` | 根规则真源（AGENTS.md/CLAUDE.md 等由 `tools/ai/sync_context.py` 生成，**禁止手改**） |

---

## 八、工程规范与审查（docs/ 根 + reviews/）

- [`BUILD.md`](BUILD.md) — 构建指南（core 门禁命令、Apple 双工程）
- [`COCOAPODS.md`](COCOAPODS.md) — CocoaPods 源码集成说明
- [`CODESTYLE.md`](CODESTYLE.md) — **代码风格唯一标准**（CODE-001 成文，`cq-code-review` skill 据此执行）
- [`reviews/`](reviews/) — 审查记录（如 [REVIEW-2026-10-05 全库风格巡检](reviews/REVIEW-2026-10-05-全库风格巡检.md)、[REVIEW-2026-10-06 MEDIA-027 播放冻结与 jetsam 复盘](reviews/REVIEW-2026-10-06-MEDIA027-播放5秒冻结与jetsam复盘.md)）
- [`../tools/ci/run_gate.sh`](../tools/ci/run_gate.sh) — 统一门禁脚本（本机总门禁入口）
- [`tasks/PLAN-三线并行.md`](tasks/PLAN-三线并行.md) — 相机/编辑器/智能成片三线并行的号段与写集规划

---

## 九、当前状态看哪里

| 想知道 | 看 |
|---|---|
| 项目现在做到哪了 | [`handoff/HANDOFF-004-*`](handoff/) 两份的 §1（对着 commit 核过） |
| 下一个任务是什么 | HANDOFF 的"下一步"节 + [`tasks/TASK-BACKLOG.md`](tasks/TASK-BACKLOG.md) |
| 某模块的接口与约束 | `.ai/modules/<模块>.md` |
| 某个性能数字可不可信 | `.ai/memory/baselines.md`（不在其中 = 估算 [E]） |
| 踩过什么坑 | `.ai/memory/pitfalls.md`（P/E 编号索引表） |
| 工程目录结构 | [ARCH-001 §8](specs/ARCH-001-技术方案总纲.md)（权威） |
