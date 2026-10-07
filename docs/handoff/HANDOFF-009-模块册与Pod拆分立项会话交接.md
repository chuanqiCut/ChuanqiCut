# HANDOFF-009：模块册分册制 + 阶段批节奏 + 壳工程/Pod 立项（会话交接）

> 2026-10-07 晚。纯流程/规划轮（零代码、零 core 触碰）。传哲三拍板：①调研/任务/进度/
> 测试门禁记录**按模块统一管理**、记忆与进度更新防撞车；②主工程壳化，草稿/素材管理/
> 播放器/拍摄/素材导入**各自 podspec**；③门禁与真机**阶段性去跑**，不每日空跑。
> 决策 = [ADR-0030](../decisions/ADR-0030-模块册分册制与阶段批门禁节奏.md) +
> [ADR-0031](../decisions/ADR-0031-主工程壳化与功能Pod分治.md)。

## 下一个会话（本机，集成机）怎么接手

1. **合并快检（每次拉远端必做）**：`build_core.sh` + SharedUI `swift test` + 冲突标记/
   旧号扫描；**全量门禁 + 真机 = 阶段触发**（PLAN 阶段收尾 / 一批任务卡闭环 / 池里真机单
   攒齐 / 周度兜底）——不再每日空跑。
2. **池消化**：[docs/tasks/TODO-POOL-门禁真机待办池.md](../tasks/TODO-POOL-门禁真机待办池.md)
   在飞 [1] 播放器真机 5 检查点、[2] CAM-018/019 真机 5 项（同一趟执行）。
3. **Pod 拆分开工顺序**：[PLAN-壳工程与功能Pod](../tasks/PLAN-壳工程与功能Pod.md)
   阶段 0 = INFRA-013（壳改造）+014（SharedUI 瘦身基座）；之后逐域迁移
   （Player→Import→Assets→Camera→Editor+Draft），**每阶段收尾即一个阶段批门禁点**。
   热点文件全部集成机动手；同域业务任务与迁移不并行。
4. **记录归口（ADR-0030）**：进度/测试记录写 `.ai/modules/<模块>.md`「模块册」；
   BACKLOG/README/pitfalls/baselines/PLAN/ADR = 全局册，**只集成机写**；开发机过程记录
   在自己模块册 + 池条目，不写共享当日日志。
5. 发号水位：ADR 下一号 **0032**（0025~0028 预占素材库多轨）；pitfalls 下一号 **P83**；
   INFRA 已登记 013~020（BACKLOG §14）。

## 坑与注意

- `ChuanqiCutCamera` 迁移最大风险 = **metallib 构建链**（ADR-0021：`-fcikernel` 编 +
  `xcrun metallib` 链 + resource_bundles 下发；验收必查符号+大小防空壳）。
- Pod 依赖 Pod 时 `CChuanqiCut` module 可见性要从 user_target_xcconfig 改
  pod_target_xcconfig 链（podspec 头注释有案底）。
- ios/mac 双工程**同改同验**（Podfile/project.yml 改一漏一 = 门禁才炸）。

## 验证

零代码轮：未跑 `run_gate.sh`；`linkcheck_docs.py` ✅（见当日日志）；真源改动经
`tools/ai/sync_context.py` 重出五份生成物。
