# TASK-AIEDIT-010：AI 脚本成片（脚本→分镜→素材匹配→成片）【P1 伞占位】

```yaml
id:          AIEDIT-010
layer:       SDK + UI
goal:        单列入口「AI 脚本成片」：文案/主题 → LLM 生成脚本与分镜表 → 分镜与用户素材库匹配 → 按分镜成片（缺口素材用占位卡，生成式填充仅预留接口）
input:       [SPEC AIEDIT-001 §10(P1), RESEARCH-003 §2.1/§2.4（剪映图文成片、必剪口播成片对标）, ADR-0016 决策 7（无状态多轮）]
output:      [StoryBoard schema（cq.storyboard/1）, 分镜匹配器, 脚本成片向导 UI, 单测]
write_set:   启动时冻结（预计 core/include/cq/ai/storyboard.h(新)、core/src/ai/story/*(新)、
             SharedUI/Sources/SharedUI/SmartCut/Script/*(新)、HomeView.swift(高冲突)）
read_set:    [AIEDIT-001~009 全部产物]
deps:        [AIEDIT-009]
acceptance:
  - 启动拆解时按本模板冻结（契约任务先行：storyboard schema 先于实现）
  - 分镜匹配：给定分镜表（画面描述关键词 + 时长 + 情绪）与 FeatureReport 素材库，匹配结果可解释（每镜给出匹配理由与匹配分）
  - 缺口素材 → 占位卡（时长正确、可后续替换），不阻塞成片
verification:
  - ctest -R storyboard；swift test（Script 向导）
risk:        范围膨胀（生成式视频/TTS/数字人诱惑）→ 本期严格"素材匹配 + 占位"；生成式仅留 extensions 接口
parallel:    false（P1 单独批次）
```

## 背景

用户命题的扩展线："可以制作成脚本，然后分镜头制作，可以单列入口"。对标剪映图文成片（脚本→配音→素材匹配→成片）与必剪口播成片，但不绑素材库生态——匹配范围是用户本机素材库。

## 实现要点（启动拆解时细化）

1. StoryBoard 与 EditPlan 的关系：storyboard 是"意图层"（镜号/描述/时长/情绪/旁白），成片时编译为 EditPlan——复用 001 契约与 006 执行器，不另起执行通道。
2. 旁白/TTS 是 P1 内的独立决策点（依赖音频域进度），进启动拆解。
3. 生成式填充（Runway/即梦类）只留 `gap_fill_policy` 扩展字段（ADR-0016 反转条件之外的新能力，届时另立 ADR）。

## 回写

启动时新增 SPEC（AIEDIT-002 号段）而非塞进本卡。
