---
name: cq-code-review
description: 代码审查。三种场景：①合并其他开发机的代码之后跑合并快检（窄检必做，全量门禁按 ADR-0030 阶段批触发；远端门禁不可信）；②本机任务收尾、commit 之前自审；③定期全库风格/命名巡检。产出带 file:line 证据的审查报告与本机实测验证数字，发现项分级 P0/P1/P2。
---

# 代码审查（合并守门 / 提交自审 / 风格巡检）

## 触发

| 场景 | 触发时机 | 审查对象 |
|---|---|---|
| A 合并守门 | 其他开发机的代码 merge 进来之后（**本机是唯一真构建机**，远端只有 -parse / 未编译的 Swift 是有案底的常态）；**快检窄集每次必跑，全量门禁按 ADR-0030 阶段批触发**（PLAN 阶段收尾 / 一批任务卡闭环 / 真机单攒齐 / 周度兜底） | merge 引入的 diff |
| B 提交自审 | 本机任务收尾、commit 之前 | 本任务 write_set |
| C 风格巡检 | 定期（建议每周）或接手陌生模块前 | 全库或指定模块 |

## 原则

- **门禁口径以本机为准**：远端声称"已验证"一律按未验证处理，门禁在本机重跑。
- **每条发现必须带证据**（file:line + 1~2 行摘录），不接受"整体没问题"。
- **先报告后动手**：A/C 场景发现的问题先分级——P0（阻断合并，修复前不推送）/
  P1（本轮顺手修）/ P2（挂任务卡）。B 场景的 P0/P1 自己修完再提交。
- **风格判定的唯一标准是 `docs/CODESTYLE.md`**；架构红线以 AGENTS.md 十条为准。
- 双机/三线并行时，pitfalls P 号、任务 ID、ADR 号**取号前必须 `git fetch` 核对
  远端已用号**（编号纪律，MEMORY.md 有撞号案底）。

## 流程 A：合并守门（默认场景）

1. **固定审查范围**：`git fetch --all` → `git log <merge-base>..<合并后HEAD> --oneline`
   列出来源 commit；`git diff <merge-base>..<合并后HEAD> --stat` 列改动文件。
   凭印象审 = 漏审。
2. **写集越界检查**：对照来源任务卡（docs/tasks/TASK-*.md）声明的 write_set，
   列出越界改动的文件（越界≠必须回滚，但必须显式确认）。
3. **门禁全量重跑（本机）**：`tools/ci/run_gate.sh`，或按 cq-build-test 分步跑。
   任一不过 → 停，先修复再收尾。
4. **远端薄弱点专项**（有 pitfalls 案底，新会话容易再踩）：
   - Swift 相机/相册文件必须过 `xcrun -sdk iphonesimulator swiftc -typecheck`
     全量检查（远端只 -parse，P46/P48 两次放行真错误）；
   - Swift 6 发送域错误、async 上下文调 `RunLoop.main.run`（P45）、
     类型重复声明（MediaGridCell 案底）；
   - C++ 看是否真开了 `-Werror`（远端工具链旧）。
5. **架构红线按 diff 面过一遍**：PAL 头零平台类型（`tools/pal/check_pal_headers.py`）、
   公共头零第三方类型、UI 不直改模型（走 Command）、无浮点秒、无异常/无裸
   `new`（内核 `-fno-exceptions` + nothrow 约定）、时间一律 RationalTime。
6. **风格 diff 审查**：按 `docs/CODESTYLE.md` 速查表逐条对照改动文件。
7. 产出报告（见下）；新踩的坑按编号纪律写进 `.ai/memory/pitfalls.md`。

## 流程 B：提交前自审

1. `git diff` 自己的 write_set，按"流程 A"第 5~6 步的两张清单自查。
2. 跑最窄相关测试 → 全量门禁（cq-build-test：先窄后宽）。
3. 确认 AGENTS.md「任务结束必须同步上下文」8 项已逐项落盘。

## 流程 C：风格巡检

1. 按 `docs/CODESTYLE.md` 逐节扫，可派只读子 agent 分层并行
   （C++ 内核 / Swift 层 / 工具链与命名冲突），子 agent 只回结论+证据。
2. 与上一份巡检报告（docs/reviews/）diff：旧发现是否收敛、有无新增。
3. 报告落 `docs/reviews/REVIEW-<日期>-<主题>.md`，P2 项登记进 TASK-BACKLOG。

## 检查清单

- [ ] 审查范围用 commit 列表 + diff --stat 固定，不是凭印象
- [ ] 门禁数字是本机实测（Debug x/x、Release x/x、swift x/x、SharedUI x/x）
- [ ] 写集越界已检查并列出
- [ ] 架构红线 10 条按 diff 面过完
- [ ] 风格偏离每条带 file:line 证据
- [ ] 发现项已分级 P0/P1/P2，P0 已修或已阻断推送
- [ ] 新坑已写进 pitfalls（取号前 fetch 核号）

## 报告格式（必须）

落盘 `docs/reviews/REVIEW-<日期>-<主题>.md`，对话里给摘要：

```
审查范围：<commit 区间 / 文件清单>
门禁（本机实测）：<Debug x/x、Release x/x、swift x/x、SharedUI x/x>
发现：P0 x 项 / P1 x 项 / P2 x 项（明细见报告，每条带 file:line）
写集越界：<无 / 文件列表>
剩余风险 / 挂卡任务 ID：
```

**禁止**只说"审查过了，没问题"而不给范围、数字与证据。
