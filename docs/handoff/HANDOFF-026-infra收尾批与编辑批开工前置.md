# HANDOFF-026：infra 收尾批收口 + v0.2.0 编辑批开工前置

- 日期：2026-10-17 16:4x
- 交接人：WorkBuddy（模型，本机 = **集成机**）
- 拍板人：传哲
- 关联：[TASK-INFRA-045](../tasks/TASK-INFRA-045-Draft包进门禁.md)、
  [TASK-INFRA-046](../tasks/TASK-INFRA-046-全库clang-format重排.md)、
  [ADR-0046](../decisions/ADR-0046-版本批门禁节奏与单源版本.md)、
  [TODO-POOL](../tasks/TODO-POOL-门禁真机待办池.md)、
  [VERSIONS](../reports/VERSIONS.md)、[.ai/modules/core.md](../../.ai/modules/core.md)
- 本批新增坑号：**P175 ~ P178**（`.ai/memory/pitfalls.md`）
- 本机前提：Intel x86_64 / macOS 26.7.1 / Xcode 26.6 / 无 Homebrew / **无 `gh`**（远端 CI 状态取不到）

---

## 一、状态：infra 这条线**已清空并提交**，工作树干净

`origin/main` = **`6f5386f`**（本批两笔：`6fa4309` INFRA-045 + `6f5386f` INFRA-046），
tracked **892**，`git status --porcelain` **0 行**。

- **INFRA-045 ✅**：`ui/ChuanqiCutDraft` 进门禁 = **第 19 步 `apple-draft`**（`swift build`）。收池 **[21]**。
- **INFRA-046 ✅**：全库 clang-format 存量违规 **0/168**（重排 113 个文件）。
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

## 三、接手前必读的三条纪律（本批刚立的）

1. **不知道该跑什么就问脚本**：`tools/ci/gate_scope.sh`（只读，吐该跑的窄检命令 + 理由；判不准自动升一档）。
   **开发会话跑 L3 本身就是违规**。动 `.clang-format` / `.editorconfig` → R12 直接判全量。
2. **引用数字前先套四件**：档位 + 缓存态 + build/ctest 拆分 + 跨趟只用比例（P171）。
   「暖」是状态不是数（P167）；后台任务"完成"通知不可信（P168）。现口径 **19 步 / 513s（Release 冷态）**。
3. **判据要能被自己判红**：反证必须打在**产出这个数字的同一条完整路径**上（P175），
   且"命中 0 个"是与"命中 N 个"同等优先级的测试输入（P178）。
   ⚠️ 批量原地写回（`clang-format -i` 等）前**先列符号链接**、跑完查 `git diff --summary` 的 mode change（P176）。

## 四、装配形状速览（动代码前对一眼）

- 门禁 `tools/ci/run_gate.sh` **19 步**，顺序 = deps · headers · hygiene · layer-hygiene · api-doc ·
  ios-compile · core-dbg · core-rel · apple-xcframework · apple-prepare · apple-swift-bindings ·
  apple-sharedui · apple-player · apple-camera · apple-import · apple-editor · **apple-draft** · apple-shells · golden。
- 版本真源 = 根 `VERSION`（`0.1.0`），根 `CMakeLists.txt` 与 `run_gate.sh` 都从它读；批账在
  [VERSIONS](../reports/VERSIONS.md)（append-only）。
- ctest **52 例**，`LABELS "heavy"` **14** 例 = Debug 档跳过、Release 档全跑；
  **heavy 的唯一验收覆盖点是 `core-rel`**（和 CI 的 Debug 全跑，但那条防线尚未在远端验证过）。
- 公共头只有 `engine/core/cq/cq_sdk.h`；`api/swift/Sources/ChuanqiCutCore/include/cq_sdk.h` 是它的
  **符号链接**（全仓唯一，别用 `-i` 类工具碰它）。
- SPM 六包：SharedUI 与 ChuanqiCutDraft **无 `Tests/`** → 只能 `swift build`；其余四包有用例。
