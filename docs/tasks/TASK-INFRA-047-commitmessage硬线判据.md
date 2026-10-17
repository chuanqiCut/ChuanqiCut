# TASK-INFRA-047：commit message 硬线判据 + 钩子

> 模板口径见 [`.ai/templates/task.md`](../../.ai/templates/task.md)。
> 起因 = 传哲 2026-10-17：「commit message 又写了作文」。三条裁定（改写完强推 / 判据+钩子 / 每行 ≤40 字·正文 ≤3 行）见 [`LEDGER-W42`](../reports/LEDGER-W42.md) 补记十四。
> 实测数字全在 [`.ai/memory/baselines.md`](../../.ai/memory/baselines.md)，本卡不重复。

```yaml
id:          TASK-INFRA-047
layer:       基建（归口模块册 = .ai/modules/core.md，本仓无 infra.md —— P174）
goal:        把「不写作文」从自律改成能判红的东西；上一批三笔已推送作文改写成短 message
input:       INFRA-042 旧口径只数行数；三笔 %s 折叠后 209/361/274 字、%b 为空
output:      tools/ci/check_commit_msg.py（新）、run_gate.sh 新增 commit-msg 步（2f，总数 19 → 20）、
             本机 .git/hooks/commit-msg（不入库）、AGENTS 真源 §提交 + 5 份生成物
write_set:   上述 + 本卡、TASK-BACKLOG.md、pitfalls.md P179、baselines.md、.ai/modules/core.md、
             LEDGER-W42.md、HANDOFF-026-*.md、.workbuddy/memory/2026-10-17.md、docs/README.md、
             docs/tasks/README.md、TODO-POOL（新开池 [28]）
read_set:    [tools/ci/gate_scope.sh（R8 已覆盖 tools/ci/*，不改）]
deps:        [INFRA-042, INFRA-043]
acceptance:
  - 三笔旧消息原样喂进判据 → rc=1 且 H2 命中；只补空行的变体 → rc=1 且换成 H4/H5 命中
  - `- 实测：` 式带 bullet 的小标题 → rc=1（H7 须先剥 bullet）；剪刀线之下与 `#` 注释不参与判定
  - 改写后三笔 + `--commits=8478c10..HEAD` → rc=0；水位前挪 → rc=1（证明判据在响）
  - 钩子拦下一次真实 `git commit`，合规消息随后提交成功；`run_gate.sh --fast` 含该步
  - `bash -n` rc=0；`sync_context.py --check` 一致
verification:
  - `python3 tools/ci/check_commit_msg.py <消息文件>` / `--commits=8478c10..HEAD` / `--install-hook`
  - `tools/ci/run_gate.sh --fast --batch=INFRA-047`
risk:        ① 硬线拦形状不拦内容：作文拆成三条 40 字短句照样过，"该不该写进提交"仍是 CR 判断；
             ② 字 = Unicode 码点，不按显示宽度折算（档是传哲取的，要的是可判定）；
             ③ 水位 8478c10 之前的作文有意不追溯（sha 已被活文档引用），改水位用 CQ_MSG_WATERMARK；
             ④ 钩子不入库，换机重跑 --install-hook；漏装不影响门禁 2f 步。
```

## 硬线定义

H1 标题 ≤40 字 · H2 标题与正文间必须空行 · H3 正文 ≤3 行 · H4 每行 ≤40 字 · H5 合计 ≤120 字 ·
H6 禁表格符 `|` · H7 禁行内小标题词 · W1 标题不带任务 ID（只 WARN）。
**条文以 [`.ai/source/AGENTS.root.md`](../../.ai/source/AGENTS.root.md) §提交 为准**，实现口径见脚本头注释。

## 为什么"合规"还是作文

INFRA-042 只约束行数、不约束行长 → 标题贴线 40 字、正文每行 47~81 字照样全绿。
更基本的一层：三笔**标题与 bullet 之间没有空行**，git 把整段当同一个段落，`%s` 折叠出 209~361 字、`%b` 为空
⇒「正文最多 5 行」从未被机器满足过，只是肉眼看着像；口径 = `git log -1 --format=%s/%b`。与 P172/P175/P178 同族。

## 自证 / 改写

首版判据被**真实反例**打红两处：H7 未剥 bullet（`- 实测：` 漏判 rc=0）、`cleanup()` 先剔 `#` 注释后认剪刀线
（剪刀线本身带 `#` → 剪不到，其下的 `|` 把合规消息误红 H6）。只跑正例收工，这两个洞会带着"有判据"的错觉入库（同 P175）。
8 条输入-期望-实测在 baselines。
改写 = `git commit-tree "$(git rev-parse <old>^{tree})" -p <前一笔新 sha> -F <消息>`，字段照搬、不碰 index 与工作树；
事后 `git diff --name-only ff1e9d8 <新 tip>` = 0 行、tree 逐笔相同，回退用备份 ref。
**没走"reset 后分组重排"**：三笔写集有一个文件相交（当日日志），拆开要靠 `git add -p`，本 shell 不可用，拆错即真丢内容。

## 回写

真源 §提交 + `sync_context.py` 重刷 5 份生成物 · 坑 **P179**（判据本身）· **P180**（拿 rc 的两处壳陷阱）· 裁定 [LEDGER-W42](../reports/LEDGER-W42.md) 补记十四（append-only）·
[HANDOFF-026](../handoff/HANDOFF-026-infra收尾批与编辑批开工前置.md) 的 sha 与步数按**订正声明**更新 · 建卡登记欠账 → 池 **[28]**。
