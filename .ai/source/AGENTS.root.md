# ChuanqiCut — Agent 根规则（真源）

> 本文件是**真源**。仓库根的 `AGENTS.md` / `CLAUDE.md` / `.cursorrules` / `.github/copilot-instructions.md` / `.windsurfrules` 由 `tools/ai/sync_context.py` 生成，**禁止手改**。

## Mission

ChuanqiCut 是**跨平台视频编辑 SDK + 各端原生 App**：
- `core/` = C++20 共享内核（引擎、算法、模型、序列化），对外纯 C ABI
- `pal/<platform>/` = 平台适配（Apple / Android / HarmonyOS）
- `apps/<platform>/` = 各端原生 UI（SwiftUI / Compose / ArkUI）

目标：iOS + macOS（P0）→ Android（P1）→ HarmonyOS（P2，本期仅预留）。

## 架构红线（违反即 PR 驳回）

1. **除 UI 之外的一切下沉 C++。** 业务逻辑不得在 Swift/Kotlin/ArkTS 中实现。
2. **PAL 头文件零平台类型。** `CVPixelBuffer`、`AHardwareBuffer`、`VkImage` 等一律不得出现在 `core/` 可见的头文件中；跨层用 opaque 句柄。
3. **能力必须运行时查询，不得编译期推断。** 禁止用 `#if __APPLE__` 推断功能可用性，一律走 `cq_query_capability()`。
4. **时间一律用有理数 `RationalTime{value, timescale}`**，禁止浮点秒。项目 timescale = 60000。
5. **UI 不得直接改模型。** 所有变更走 `Command`，这是 Undo/Redo 与三端一致性的前提。
6. **Shader 双层**：`shaders/src/*.glsl` 是 Portable 层（跨平台基线，**禁止平台扩展**，经 SPIR-V 生成）；平台特化只在 `pal/<platform>/shaders/`（Platform-Native 层，可用满平台特性）。**Platform-Native 永远可选**，必须先有 Portable 实现，且收益 < 20% 不予合入。
7. **第三方类型不得出现在公共头文件**。公共头 `core/include/cq/cq_sdk.h` 只有 C 类型 + opaque 句柄。
8. **主线程零阻塞**；音频线程无锁、无分配。
9. **预览与导出走同一张 RenderGraph**，只换输出目标与时钟源。
10. **依赖变更必须走 `third_party/manifest.toml`**，禁止直接把代码拷进仓库。

## 平台优先级与性能基线

- **iOS / macOS 是重点支持平台**；Android 次之；HarmonyOS 仅预留。架构按三端设计，但人力与优化优先保障 Apple 端。
- **性能基线 = 高端满足、中端可用、明确不适配低端机**（RAM ≥ 6GB、GLES 3.1 为门槛，以下明确提示不支持）。
- 不为低端机写专用降级路径。**但能力缺失降级仍要做**（无硬解→软解、无 compute→fragment）—— 中端机也可能缺某项能力，这不是低端适配。

## 数字纪律

- 引用性能数字前先查 `.ai/memory/baselines.md`；那里没有的就是估算。
- 调研文档里的数字一律是估算 [E]，不得作为验收阈值。
- 未验证的推测必须标 `hypothesis`。

## 动手之前

0. 文档地图与分层规则：`docs/README.md` + `ADR-0019`（六层结构、根目录不放内容文档、legacy 只读、编号纪律）。
1. 读 `.ai/modules/<你负责的模块>.md`（模块归属哪条线：`docs/tasks/PLAN-三线并行.md` §1a）。
2. 读你的 `docs/tasks/TASK-<ID>.md`（若无，先跑 `cq-task-planning` 生成）。
3. 读相关 `docs/decisions/ADR-*.md`。
4. **声明要改的文件（write_set）与验证命令**，然后才动手。

## 写集规则

- 一个任务一个写集，两个任务的 write_set 不得相交。
- 高冲突文件串行修改：`CMakeLists.txt`、`cq_sdk.h`、`*.pbxproj`、`build.gradle.kts`、`manifest.toml`。
- 不得改动其他任务的文件；共享文件交给 Integrator。

## 双机分工与门禁节奏（2026-10-07，ADR-0029/0030）

- 本仓库**双机并行开发**：本机 = **集成机**（唯一发号器、全量门禁与真机的唯一验收口径、
  高冲突文件守门）；其他设备 = **开发机**，按 `docs/tasks/PLAN-三线并行.md` §1a 的
  **模块归属表**分线开发，各模块归属另见 `.ai/modules/*.md` 头部归属行。
- **一机同一时间只待一条线**；跨线需求拆卡或走集成机，禁止跨写集直改。
- **模块册 = 模块级管理归口（ADR-0030）**：调研/任务/进度/测试及门禁记录统一记在
  `.ai/modules/<模块>.md` 末尾「模块册」节（任务与进度 / 测试与门禁记录 / 调研·决策·池
  指针），由**归属线**更新；新 RESEARCH/SPEC/REVIEW 落 `docs/` 原位（ADR-0019 分层不变），
  但必须在归属模块册登记指针。
- **全局册单写者 = 集成机（ADR-0030）**：`TASK-BACKLOG.md`、两份 README、
  `pitfalls.md`、`baselines.md`、`PLAN-*.md`、ADR、workbuddy/MEMORY——开发机**零直写**，
  要改走池条目或提案；开发机过程记录写**自己模块册** + 池条目，不写共享当日日志。
- **开发机（简化档，编码优先）**：优先完成编码任务，不为等门禁阻塞。自查只需模块级
  （编译 + 相关单测；Swift 必须 `-typecheck`，`-parse` 绿不是绿）。**全量门禁与真机不由
  开发机承担**——收工把待验项登记进 `docs/tasks/TODO-POOL-门禁真机待办池.md`
  （**append-only**，格式照池文件），推送即收工。
- **集成机（阶段批，ADR-0030 修订 ADR-0029 的日批）**：**合并快检必做**——拉远端后跑
  `build_core.sh` + SharedUI `swift test` 窄检 + 冲突标记/旧号扫描（远端"已验证"按未验证
  处理）；**全量门禁与真机按阶段跑**：一个 PLAN 阶段收尾 / 一批任务卡闭环 / 真机单攒齐
  一趟 / 周度兜底，不每日空跑。池的清扫/关闭/编号改动只归集成机（pitfalls P82）。
- 热点文件（`cq_sdk.h`、CMakeLists、podspec、Podfile、project.yml、构建脚本、真源、CI）
  与 ABI/依赖变更**不受简化档豁免**，仍须先提案给集成机。

## 验证

完成 = 门禁通过，不是自述完成。**口径分级（ADR-0029）**：验收性完成 = 集成机全量门禁 +
真机；开发机完成 = 编码 + 模块级自查 + 待办池登记 + 推送，验收数字一律以集成机日志为准。至少：

```bash
tools/build/build_core.sh --platform=<apple|android>   # 编译，-Werror
ctest --test-dir build -R <相关模块>                    # 单测
tools/qa/golden_compare.sh --case=<case>                # golden 对比（渲染/导出相关）
```

必须报告：**执行了什么命令、通过/失败、跳过了什么、剩余风险**。

## 委托与并行

- 适合并行：只读探索、文档检索、测试设计、日志分析、独立审查、写集不相交的模块实现。
- 禁止并行：架构决策、共享接口设计、同一文件改写、高冲突文件、需共享模拟器/设备状态的 E2E。
- 子 Agent 只返回摘要、证据路径、结论、待决策项，**不要把完整日志倒灌回主线程**。

## 提交

- 分支 `<person>/<task-id>-<slug>`；一个任务一个 PR。
- 禁止提交：密钥、签名凭证、生成媒体、用户数据、shader 生成产物、构建产物。
  **例外**：`tests/golden/frames/` 下已登记在 `tests/golden/manifest.toml` 中的测试夹具**必须提交** —— 它是比对基准，不是构建产物。总体积控制在 10MB 以内，超出才讨论 Git LFS。
- PR 必须链接 Spec/Task/ADR，并附机器验证证据。

## 任务结束必须同步上下文（逐项勾完才能说"完成"）

> 这一节原本只有 4 条泛泛的条目，结果是**连续两轮没被执行**
> （2026-10-02 BIND-003 子步骤 4/5 都漏了 `.ai/modules/` 与 ADR）。
> 模糊的"要回写"等于没写 —— 故改成下面的**逐项清单**，每项都要在本次会话里
> 真实落盘（不是"我在回复里提到了"）。

收工前逐项自检，**任一项没做就不算完成**：

| # | 位置 | 写什么 | 判定 |
|---|---|---|---|
| 1 | `.ai/modules/<模块>.md` | 接口新增/变更、分层调整、装配形状 | 存在对应段落；新模块要新建文件 |
| 2 | `docs/decisions/ADR-*.md` | **改变了既有惯例/架构约束**时必须新增 | 有 ADR 编号并被任务卡引用 |
| 3 | `docs/tasks/TASK-<ID>.md` | 子步骤进度表、写集、新增文件清单 | 状态与实际一致 |
| 4 | `docs/handoff/HANDOFF-*.md` | 下一步是谁、装配形状、坑 | 新会话照它能接手 |
| 5 | `.ai/memory/pitfalls.md` | 本轮踩的坑（日期+来源+**验证状态**） | 有条目，不是只在回复里说 |
| 6 | `.ai/memory/baselines.md` | 实测数据，**替换估算数字** | 无实测就明确写"未实测" |
| 7 | `.workbuddy/memory/YYYY-MM-DD.md` | 当日工作日志（append-only） | 有本轮记录 |
| 8 | `.workbuddy/memory/MEMORY.md` | **新确立的长期约定/硬规则** | 规则类内容不留在日志里 |

补充要求：

- 门禁状态要写**具体数字**（如 `Debug 34/34、Release 34/34`），不写"全绿"。
- 剩余风险与"本期明确不支持"要写进头文件/文档，**不要只在对话里说** ——
  对话会丢，代码注释和文档不会。
- 交接文档里的任务状态要**对着 commit 历史核**，不能照抄上一版
  （已发生过：HANDOFF-003 把 PALA-002 早已做完的子步骤 3 标成"下一步"）。

## 交付格式

结尾给出：摘要 / 改动文件 / 验证证据 / 剩余风险 / 后续任务 ID。
