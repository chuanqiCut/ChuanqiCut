# REVIEW-2026-10-07：CAM 撞号归一轮合并守门（流程 A）

> 审查人：集成机（本机）。触发：远端 2 提交合入后按 `cq-code-review` 流程 A 守门；
> 兼作新 TODO「撞号归一轮收尾」TODO-1（构建机门禁复验）的执行。

## 审查范围

- commit：`b134bc6..3163ceb`（`80f1d5a` 撞号裁定归一轮 + `3163ceb` TODO 立项/日志），快进合并无冲突。
- 文件：28 个 —— 相机域 Swift 8（CameraRecorder/Renderer/ViewModel/BeautyKernel/CameraBeauty/FaceMask/FaceMaskTests）、Editor 域 Swift 4（注释）、docs 12、.ai 1、.workbuddy 3。
- 性质：**全部为文档 + 代码注释级改号**，无逻辑改动（逐文件 diff 核过）；core / PAL / 公共头 / 绑定层零触碰。

## 裁定一致性核查（与昨日 UIA 清扫轮 14f9ec9 对照）

| 项 | 结论 | 证据 |
|---|---|---|
| CAM 让位方向 | ✅ 渲染线（先入库+活线）保留 015/016，美颜线（已完结）让位 018/019 —— 先占者留号 + 改动面小者让位，与 UIA 轮同向 | `TASK-CAM-018.md` 头部让位说明、git 考古（9da6270 渲染线先入库） |
| pitfalls P62/P63 双占 | ✅ 处理正确：**老条目原号保留**（P62 App-DEBUG @pitfalls:1003、P63 TaskRunner @:977），美颜线后入库条目改 **P80/P81** 并带"曾号"让位头（@:1308/:1323） | grep 全部 P62/P63 引用无悬空 |
| UIA-032/033 体系 | ✅ 远端采纳，并补齐我留在 Editor 注释里的"UIA-017 再惯例化"让位口径（4 文件） | EditorBottomToolbar/Layout/MediaSheet/TimelineZone diff |
| SPEC 改名 | ✅ `SPEC-CAM-018-019-美颜质量修复与人脸区域化.md`；旧名 3 处引用均带"曾/现名"标注 | grep SPEC-CAM-015-016 全仓 |
| 依赖语义 | ✅ CAM-017/021 的 deps 指向渲染线 CAM-016（方向修复），非美颜线——语义正确 | TASK-CAM-017/021、BACKLOG §9 |
| 号段水位 | ✅ P80/P81、CAM-018/019 取号前空闲（此前 P79 为最高；CAM-017/021 已占） | pitfalls 尾部、BACKLOG §9 |
| 卡数登记 | ✅ tasks/README 62→64 张（+CAM-018/019）；BACKLOG §9 双行撞号注记收敛为终版 | diff |

## 写集越界

归一轮本质 = 跨写集编号清理（与 UIA TODO-1 同性质）：线 B 卡 + 线 A 域 4 个 Editor Swift 注释文件 + SharedUITests 1 + docs。**显式确认合理**——逐文件均为注释/文档级，无行为面。

## 发现

- **P0：0 项**
- **P1：0 项**
- **P2：2 项（均集成机顺手修毕）**
  1. `docs/tasks/PLAN-三线并行.md:37` A 线行：昨日 perl 编辑遗留表格错位（多余空单元格）+ pitfalls 水位陈旧（"新号从 P58 起"）→ 已修为"P58~P81 已用，新号从 P82 起"。
  2. `docs/tasks/README.md:116` 待接手表备注"这三件"措辞过期（现表含撞号归一轮 TODO，且不占 CAM 号）→ 已改为"这些待办不占 UIA/CAM 序列号"。

## 门禁（本机实测）

`tools/ci/run_gate.sh` 全量复验（2026-10-07 14:46 完成）：**PASS=9 / FAIL=0 / SKIP=0**；
core-dbg **45/45**、core-rel **45/45**；apple-swift-bindings 与 apple-sharedui 测试套全过
（日志 `build/gate-logs/*.log`，时间戳 14:46）。对照基线（清扫轮 PASS=9）零回归——
撞号归一轮注释/文档级改动无行为影响，**新 TODO「撞号归一轮收尾」TODO-1（构建机复验）就此关闭**。

## 剩余风险 / 待办

- **TODO-2（撞号归一轮收尾）**：CAM-018/019 真机验收 5 项（磨皮不闪/观感基线/区域化/预览=录制色/引擎激活日志）——需传哲 iPhone，可与播放器 TODO-2 同一趟真机执行。
- 播放器 TODO-2（真机 5 检查点）仍开放。
