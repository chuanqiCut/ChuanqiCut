# HANDOFF-026：infra 收尾批收口 + v0.2.0 编辑批开工前置

- 日期：2026-10-17 16:4x（**尾盘 17:2x 追加订正**，见 §一 的 sha 表）
- 交接人：WorkBuddy / Qoder agent（模型，本机 = **集成机**）
- 拍板人：传哲
- 关联：[TASK-INFRA-045](../tasks/TASK-INFRA-045-Draft包进门禁.md)、
  [TASK-INFRA-046](../tasks/TASK-INFRA-046-全库clang-format重排.md)、
  [TASK-INFRA-047](../tasks/TASK-INFRA-047-commitmessage硬线判据.md)、
  [ADR-0046](../decisions/ADR-0046-版本批门禁节奏与单源版本.md)、
  [TODO-POOL](../tasks/TODO-POOL-门禁真机待办池.md)、
  [VERSIONS](../reports/VERSIONS.md)、[.ai/modules/core.md](../../.ai/modules/core.md)
- 本批新增坑号：**P175 ~ P180**（`.ai/memory/pitfalls.md`）
- 本机前提：Intel x86_64 / macOS 26.7.1 / Xcode 26.6 / 无 Homebrew / **无 `gh`**（远端 CI 状态取不到）

---

## 一、状态：infra 这条线**已清空并提交**，工作树干净

> ⚠️ **订正（同日 17:2x，INFRA-047）**：本节原先写 `origin/main = 6f5386f`、
> 「本批两笔 `6fa4309` + `6f5386f`」—— 那是**这份交接自己还没提交时**的状态，
> 且那三笔随后被**改写成短 message 重推**（传哲裁定①「改写成短 message 后强推」），
> 旧 sha 已不存在于 `main` 上。按下表取值。

`origin/main` = **`2b033d0`**（本批三笔，改写后）：

| 任务 | 改写前 | **改写后（现 main）** |
|---|---|---|
| INFRA-045 Draft 进门禁 | `6fa4309` | **`0eba735`** |
| INFRA-046 全库 clang-format 重排 | `6f5386f` | **`2dc4e11`** |
| 本份交接（INFRA-045/046 交接） | `ff1e9d8` | **`2b033d0`** |

树**逐笔不变**（`commit-tree` 重建，`git diff --name-only ff1e9d8 2b033d0` = **0 行**），只换了 message；
形状问题见 [TASK-INFRA-047](../tasks/TASK-INFRA-047-commitmessage硬线判据.md)（旧三笔在 git 里 `%b` 是**空的**）。

- **INFRA-045 ✅**：`ui/ChuanqiCutDraft` 进门禁 = 新增 `apple-draft` 步（使门禁 **18 → 19 步**，
  当时它在末尾第二位；**"第 19 步"是当时的编号速记，不是它在序列里的位置** —— INFRA-047 加到 20 步后
  这个说法就漂了， hence 真源只写「步数以脚本为准」）。收池 **[21]**。
- **INFRA-046 ✅**：全库 clang-format 存量违规 **0/168**（重排 113 个文件）。
- **INFRA-047 ✅（同日尾盘追加）**：commit message 硬线判据 + 本机钩子 + 门禁新增 `commit-msg` 步（**2f**，总数 19 → 20）。
  起因 = 传哲「commit message 又写了作文」；三笔旧提交按裁定①改写完重推（就是上面那张 sha 表）。
  **有意不立 ADR**（下一号仍 0047）：这是提交信息的字数硬线、不是架构约束，落点 = 真源 §提交 + 判据本身；
  沿 INFRA-042 先例（同样只进真源无卡无 ADR）。要翻案就在 v0.2.0 批补一条。
- **v0.1.0 批的 L3 首趟 ✅**（欠账池 **[27]** 关闭）：**19 步 PASS=19 / FAIL=0 / SKIP=0，墙钟 513s**。
  旧推算 `≈344s [E]` **作废**。
- **四条池判定**：[21] 关闭、[27] 关闭、**[25] 📌 挂起**（INFRA-040 不立项）、**[26] 📌 维持现状**。
- `VERSION` **仍为 `0.1.0`，有意不升号**（理由写在 [VERSIONS](../reports/VERSIONS.md) §v0.1.0 那节：
  这趟是 v0.1.0 的第一趟也是唯一一趟，不违反「一号一趟」）。**升 `0.2.0` 必须与那趟 L3 的 PASS/FAIL/SKIP + 墙钟同批落。**

**明确没做、且不要以为做了**：① CI 远端首跑（传哲「本批不管，继续挂着」，本机无 `gh` → 状态取不到）；
② iOS 模拟器切片（池 **[24] ⏸ 冻结**）；③ `CODEOWNERS`（等传哲给用户名）；④ Draft 包在
`.ai/modules/ui-apple.md` 的归属行；⑤ **真机**（本批一行真机都没跑）。

## 二、下一步是谁：传哲先裁定，然后才轮到编码

命题「infra 先搞完再看编辑相关的哪些先放在一个版本中先搞」—— infra 已经搞完，**现在停在编辑批开工前**。
传哲已给的方向（2026-10-17 AskUserQuestion）：**v0.2.0 = B4 导出闭环 + 小料 + PALA-030（B2 收全）**，即

| 卡 | 内容 | 串行理由 |
|---|---|---|
| **CORE-011** | 内核补 `cq_session_set_track_muted` ABI（传哲裁定 E1「先补内核 muted」） | 动 `engine/core/cq/cq_sdk.h` = 高冲突，必须第一个 |
| **UIA-046** | 点选也暂停（裁定 D5）：`TrackIntent.isEditing` **改名** `pausesPlayback` | 与导出抢编辑器文件，排在 CORE-011 后 |
| **EXPORT-001 + `cq_export_*` ABI** | B4 导出闭环的内核与接口面 | 又动公共头 |
| **UIA-007** | 导出闭环的 UI 面 | 吃前三张的产物 |
| **PALA-030** | B2 收尾（多轨剩余） | 与 UIA 线共写 iOS 编辑器文件 |

**开工前三件必须问传哲**（不要自行开工、不要自行跑门禁）：
1. v0.2.0 射程确认（上表是否就这些）；
2. **L3 全量门禁**：一个版本号一趟，只有集成机能跑，且**要他点头**；
3. **真机**：他说过「这次只管门禁，真机不动」——编辑批若要真机，得他重新点头并回收问卷
   （**问卷未回收不得标记完成**，ADR-0034）。

**三件已裁定（同日尾盘，本节到此失效，按下面执行）**：
1. 射程 = **上表五张 + 清欠账**（池 **[28]**：磁盘 137 张卡 vs 表内 91 行，把建卡登记做成机器可判）。
   串行链 = **CORE-011 → EXPORT-001 → UIA-007 → UIA-046 → PALA-030**（前两张动公共头，必须连排；
   UIA-046 虽与内核无冲突，排在导出之后是为了让真机一趟同时收 D5 手感题）。
   EXPORT-001 / UIA-007 / PALA-030 **磁盘无卡**，且 BACKLOG 那三行的写集要点 `core/src/export/*`
   **已过期**（内核真源 = `engine/core/cq/`）→ 先建卡再编码，号段现取现核。
2. L3 = **编码全部闭环后跑一趟**，绿了随批 `VERSION` 0.1.0 → 0.2.0 与数字同部落；中途只跑 `gate_scope.sh` 窄检。
3. 真机 = **UIA-007 导出闭环后上一次** iPhone 17 Pro；`QUESTIONNAIRE-UIA-046` 的手感题**并入那一张**，
   不单发（问卷未回收不得标记完成）。

**同日 20:3x 追加裁定（覆盖上面第 1、3 条，接手以这段为准）**：
1. 射程 = **七张**，链 **CORE-011 ✅ → MODEL-004 → RENDER-011 → EXPORT-001 → UIA-007 → UIA-046 → PALA-030**。
   传哲「把这些都排进来」= 把**多轨画面逻辑**（MODEL-004 轨道变换/层级 → RENDER-011 视频多轨合成）
   从 B4 之后前移到导出之前——顺序是数据依赖决定的：`ChqClip` 现在没有 `transform`/`layer`，
   合成器拿不到"第二轨画什么、画在哪"，先做 RENDER-011 只能空转。
   现状：音频**已是真多轨**（`engine/core/cq/audio/chq_preview_mixer.cpp` 遍历全轨、跳 `!enabled || muted`），
   视频**只取第一条命中的轨**（`engine/core/cq/render/chq_graph_assembler.cpp` 命中第二条即 Warn）。
   **建卡欠账 = 四张**（EXPORT-001 / UIA-007 / PALA-030 / RENDER-011，磁盘无卡且 BACKLOG 写集过期）。
2. 真机 = **不等批末**（2026-10-17 20:3x 已上一次，数字见 `.ai/memory/baselines.md`「真机趟」节）。
   D5 手感题仍并入导出那张问卷，不单发。
   ⚠️ 那次只证明"能装能起能拿日志"，**没拿到多轨画面的取证** → 立为池 **[30]**；
   踩到的 `--console` × `nohup` 互斥记 **P182**。

## 三、接手前必读的三条纪律（本批刚立的）

1. **不知道该跑什么就问脚本**：`tools/ci/gate_scope.sh`（只读，吐该跑的窄检命令 + 理由；判不准自动升一档）。
   **开发会话跑 L3 本身就是违规**。动 `.clang-format` / `.editorconfig` → R12 直接判全量。
2. **引用数字前先套四件**：档位 + 缓存态 + build/ctest 拆分 + 跨趟只用比例（P171）。
   「暖」是状态不是数（P167）；后台任务"完成"通知不可信（P168）。
   现口径 = **20 步**；**513s 那趟是 19 步**（Release 冷态），新增的 2f 步 `commit-msg`
   **只进过 `--fast`、没进过 L3 趟** → 别把 513s 当 20 步的数（拿不到就别拿，标 `[E]`）。
   `--fast` 本批两趟同为 9/0/3：**101s → 38s**（`core-dbg` 88s → 21s，复跑 `Building CXX` = 0）——
   同档同树差 2.7× 全在构建态，报数必须带这两件。
3. **判据要能被自己判红**：反证必须打在**产出这个数字的同一条完整路径**上（P175），
   且"命中 0 个"是与"命中 N 个"同等优先级的测试输入（P178）。
   ⚠️ 批量原地写回（`clang-format -i` 等）前**先列符号链接**、跑完查 `git diff --summary` 的 mode change（P176）。
4. **规矩里每一个维度都得是个数**（P179）：「正文 ≤5 行」只数行数 → 产出每行 47~81 字的
   "合规的作文"；且**标题与正文没有空行时，git 里 `%b` 是空的** —— 肉眼看到的"正文"在机器里不存在。
   取证一律用 `git log -1 --format='%s'` / `'%b'`，不用"我看到的第一行"。
   钩子（`.git/hooks/commit-msg`）只挡本机且 `-n` 能跳，**真正的防线是门禁 2f 步判已入库区间**。

## 四、装配形状速览（动代码前对一眼）

- 门禁 `tools/ci/run_gate.sh` **20 步**，顺序 = deps · headers · hygiene · layer-hygiene · api-doc ·
  ios-compile · **commit-msg** · core-dbg · core-rel · apple-xcframework · apple-prepare ·
  apple-swift-bindings · apple-sharedui · apple-player · apple-camera · apple-import · apple-editor ·
  **apple-draft** · apple-shells · golden。**步数以脚本为准**（真源不写死，见 INFRA-045）。
- 版本真源 = 根 `VERSION`（`0.1.0`），根 `CMakeLists.txt` 与 `run_gate.sh` 都从它读；批账在
  [VERSIONS](../reports/VERSIONS.md)（append-only）。
- ctest **52 例**，`LABELS "heavy"` **14** 例 = Debug 档跳过、Release 档全跑；
  **heavy 的唯一验收覆盖点是 `core-rel`**（和 CI 的 Debug 全跑，但那条防线尚未在远端验证过）。
- 公共头只有 `engine/core/cq/cq_sdk.h`；`api/swift/Sources/ChuanqiCutCore/include/cq_sdk.h` 是它的
  **符号链接**（全仓唯一，别用 `-i` 类工具碰它）。
- SPM 六包：SharedUI 与 ChuanqiCutDraft **无 `Tests/`** → 只能 `swift build`；其余四包有用例。
