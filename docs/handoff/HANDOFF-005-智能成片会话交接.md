# HANDOFF-005：智能成片（AIEDIT）立项交接

> 日期：2026-10-04
> 性质：**调研 + 技术方案 + 任务拆解批次**（纯文档，零代码改动）
> 下一会话：从 `TASK-AIEDIT-001`（契约冻结）开工；开工前照例读 AGENTS 真源 + `.ai/modules/ai.md` + 本文件。

## 1. 本轮做了什么

用户命题：首页加「智能成片」入口——导入素材 → 本地提取特征 → 大模型产出处理决策 → 本地 SDK 执行剪辑 → 直接导出或进二次编辑；保留对话框（语音 + 文字）持续调整；扩展"脚本→分镜"单列入口。要求：调研市面 → 技术方案 → 任务拆分。

产出（全部已落盘）：

| 文件 | 内容 |
|---|---|
| `docs/research/RESEARCH-003-智能成片竞品调研.md` | 剪映/CapCut、iMovie Magic Movie、GoPro Quik、必剪、Opus/Vizard/Gling、Descript、端侧模型现状（Apple FM/Gemini Nano）；能力矩阵 + 取长补短 8 条 + 差异化定位 |
| `docs/decisions/ADR-0020-智能成片与大模型接入边界.md` | 7 条决策：素材不出设备 / 分层边界 / EditPlan 契约 / 全 Command 化 / 供应商可插拔 / 离线降级 / 会话无状态化；3 条反转条件 |
| `docs/specs/AIEDIT-001-智能成片.md` | 技术方案：架构与数据流 / FeatureReport schema / EditPlan schema（8 动词）/ 校验与修复 / 执行器映射 / UI 流程 / 三阶段 / 非目标 / 可机判验收 / 6 条开放问题 |
| `docs/tasks/TASK-AIEDIT-000~011.md`（12 张卡） | 伞卡（DAG/批次/关键路径）+ 11 张实施卡（YAML 全字段：写集/依赖/验收/验证命令/风险） |
| `docs/tasks/TASK-BACKLOG.md` §10 | 批次登记表 |
| `.ai/modules/ai.md` 增补 | 智能成片管线分层图 + 5 条硬规则 |
| `.ai/modules/ui-apple.md` 增补 | SmartCut/ 前端域形状 |

## 2. 装配形状（一分钟版）

```
SwiftUI(HomeView 入口卡→向导→对话框)  ──C ABI cq_ai_*──▶  core/src/ai/*
  特征: analysis(视觉) + audio_analysis(音频) → FeatureReport(纯统计,KB级)
  决策: plan_pipeline(Prompt→ILlmClient→校验修复→降级) → EditPlan(cq.editplan/1, 8动词)
  执行: plan_executor → ICommand 批次 → cq_session_submit（与人手编辑同一撤销栈）
  传输: pal/apple/net(URLSession+SSE, 零三方) ← OpenAI-compatible 协议
  降级: ai/fallback 规则引擎（断网/无key/三连失败 → 同 schema 合法 plan）
```

## 3. 关键决策与理由（防新会话重新发明）

1. **上云的只有特征摘要**（ADR-0020 决策 1）——与剪映上传素材的差异即隐私卖点；端侧无可用的多模态视频理解模型（RESEARCH-003 §2.7），"理解"必须上云，但可以只理解特征。
2. **EditPlan 是 action 列表不是时间线**（决策 3）——有界、可校验、可增量 diff、可逐条接受/拒绝（学 Opus 决策透明）。
3. **AI 全走 Command**（决策 4）——"AI 改错了"一键撤销；复用 ADR-0012 线程模型。
4. **离线降级是产品能力不是兜底补丁**（决策 6）——对标 iMovie 的完全离线可用；规则引擎输出同 schema，下游无感。
5. **P0 导出置灰**——`core/src/export/` 不存在（EXPORT-001 未做），主出口是"进编辑器精修"（同一 Session），闭环价值不受损。

## 4. 执行顺序（新会话从这里继续）

```
批次1  AIEDIT-001 契约冻结（串行先行，校验器 golden ≥40 例）
批次2  002 视觉特征 ∥ 003 音频特征 ∥ 004 网络传输 ∥ 006 执行器+新命令 ∥ 011 规则引擎
批次3  005 Prompt 管线
批次4  007 C ABI（cq_sdk.h 高冲突，独占）
批次5  008 向导 UI（HomeView.swift 高冲突，独占）
批次6  009 对话+语音（project.yml info 高冲突）
P1     010 脚本成片（启动时先拆 Spec/契约）
```
关键路径 `001→005→007→008→009`；003/011 晚到不阻塞（007 对未就绪能力返回 UNAVAILABLE）。

## 5. 坑与注意（开工前必读）

1. **cq_sdk.h / command.h / HomeView.swift / project.yml(info) / manifest.toml 全是高冲突文件**——各卡写集已声明独占批次，不要并行碰。
2. **FFmpeg 加 decode 档是依赖变更**：AIEDIT-003 必须跑 cq-dependency-governance（LGPL 档位不变，decode 不引 GPL 组件；体积增量实测入 baselines）。
3. **时间字段浮点秒一律非法**（红线 4 的 EditPlan 版）：校验器拒绝，测试断言覆盖。
4. **新 Swift 文件后必须 pod install**（pitfalls P34）。
5. **本机门禁现状**：Swift 工具链拒跑（pitfalls P39）+ 本机非构建机——所有 swift test / xcodebuild 验收在真实构建机执行；core 单测可在任一机器跑（cmake 环境变量见 MEMORY.md 构建环境约定）。
6. **音视频分析全程后台 + 可取消**（红线 8 主线程零阻塞）；Seek/内存分析挂 cq-media-pipeline（002/003 卡内已挂）。

## 6. 待传哲拍板（开放问题，AI 不得代决）

1. **默认 LLM 供应商与 key 分发**（国内豆包/通义/月之暗面 vs 海外 Gemini/Claude vs 自建代理）——影响 P0 联调对象；P0 可先用假服务联调。
2. **调用成本承担**（免费额度/限免/会员）。
3. **隐私合规申报**：App Store 标签 +《生成式 AI 服务管理暂行办法》备案是否适用——上线前法务确认。
4. **纯特征决策质量的门槛**：10 组真实素材人工评测可用率 ≥60% [E] 继续，不达标启用"授权帧描述"增强（需过隐私评审）。

## 7. 状态核对（对 commit 历史）

本轮零代码提交，全部为文档新增/追加（`docs/research/`、`docs/specs/AIEDIT-001`、`docs/decisions/ADR-0020`、`docs/tasks/TASK-AIEDIT-000~011`、backlog §10、`.ai/modules/{ai,ui-apple}.md`、`.workbuddy` 日志）。HEAD = `be90dff`（UIA-013 v1.1）。性能/成本数字全部 [E]，baselines.md 未动（无实测）。
