# TASK-UIA-046：播放中点选片段也暂停（问卷 D5 裁定的行为变更）

```yaml
id:          TASK-UIA-046
layer:       UI
goal:        播放中在轨道区点选片段时先暂停播放，与"编辑类意图先暂停"合并成一条判定
input:       [QUESTIONNAIRE-UIA-044-045-合并版 的 D5 裁定, TASK-UIA-045 ③④ 段, TrackIntent.isEditing]
output:      [改 TrackInteraction.swift（谓词重命名 + 覆盖选中）, 改 EditorViewController.swift:585 调用点,
              改 TimelineInteractionTests.swift（新增"播放中点选 → isPlaying==false"用例）,
              新的小问卷 QUESTIONNAIRE-UIA-046]
write_set:   ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/TrackInteraction.swift、
             ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorViewController.swift、
             ui/ChuanqiCutEditor/Tests/ChuanqiCutEditorTests/TimelineInteractionTests.swift
read_set:    ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/AppEntry.swift（pausePlayback 只读复用）
deps:        [UIA-044, UIA-045]
acceptance:
  - 播放中点选任一片段后 `viewModel.isPlaying == false`，且预览画面停在**选中前的播放头**（不跳帧）
  - 点空白取消选中是否也暂停 = 本卡唯一的开放子决策，默认**不暂停**（见"实现要点"第 3 条），
    若传哲要"点哪都停"则改判、验收项随之替换
  - 既有 81 条 ChuanqiCutEditor 用例零回归（含 UIA-045 的「编辑类意图先暂停」用例不改判定语义）
  - 双壳构建 BUILD SUCCEEDED（已由门禁 `apple-shells` 步代跑，仍须本机实跑到 rc=0）
verification:
  - cd ui/ChuanqiCutEditor && swift test --disable-sandbox --scratch-path "$ROOT/build/spm/ChuanqiCutEditor"
  - tools/ci/run_gate.sh --fast
  - 真机手感（暂停时机、有无"点了又动"）→ 脚本测不了，归 QUESTIONNAIRE-UIA-046
risk:        `TrackIntent.isEditing` 一旦把选中算进去，名字就成了假话（它不再表示"改模型"）——
             必须重命名，不得保留旧名再让语义漂移；
             暂停时机若落在"选中回灌之后"，可能先闪一帧新位置；实现要"先暂停再 selectClip"
parallel:    false
```

## 背景

合并版问卷 **D5** 问的是：播放中**点选片段**要不要也暂停？原设计答"不"——选中只是 UI 本地态、
不改模型，所以不打断播放。传哲 2026-10-17 裁定反过来了：**点选也暂停**。
理由可以从行为对称性推出来（他没说，这是我的理解）：C7 已经定了"播放中移动片段/拖手柄先暂停"，
点选是同一片段的同一手势族，一个停一个不停在手上是矛盾的。

## 实现要点

1. **改动点是唯一消费处**：`ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorViewController.swift:585`
   的 `if intents.contains(where: \.isEditing)`。`TrackIntent.isEditing` 定义在
   `TrackInteraction.swift:88`，全仓**只有这一处读它**（已核）。
   ⚠️ **取证订正（2026-10-17 13:5x 复核）**：建卡时写的是 **:584**，复核后是 **:585**（差一行，
   `if` 本体在 585）。本卡其余行号已逐条 `grep` 重取。
2. **重命名而不是塞进旧名**：新谓词表达"要不要先暂停"，不表达"改不改模型"。
   `isEditing` 这个名字一旦把选中算进去就成了假话，而**全仓只有 D5 这一处读它**，
   所以直接把 `isEditing` 改成 `pausesPlayback`，并把注释同步改成 D5 口径；
   不要保留旧名再另开一个 `pausesPlayback`——两个名字互相解释不了，下一个人只会挑错一个。
3. **点空白（`selectClip(nil)`）默认不暂停**：D5 说的是"点选片段"，取消选中不是点选。
   要做成"点哪都停"就是把 `if case .selectClip(let id) = self { return id != nil }` 换成 `return true`，
   一行——所以这条**不是架构分叉**，传哲随时可改。
4. **先暂停再选中**：`apply` 里暂停发生在 `TrackIntentApplier.apply` 之前（现在就是这个顺序），
   别调换——调换了会先触发一次 `$timeline` 回灌再停，画面可能闪一帧。
   `pausePlayback()` 已是幂等函数（UIA-045 ③④ 落地的），直接复用，不复制实现。

## 验收

对应 acceptance 逐条：第 1 条由 `TimelineInteractionTests` 新增用例覆盖
（`vm.togglePlayback()` 起播 → `apply([.selectClip(id)])` → 断言 `!vm.isPlaying`）；
第 2 条是决策项，卡面上写死默认值，真机问卷里再问一次手感；
第 3 条跑 `apple-editor` 段（当前 81 例）；第 4 条跑 `--fast` 档（含双壳）。

## 回写

- 行为语义变更（"选中会打断播放"）→ `.ai/modules/ui-apple.md` 模块册 +
  `TrackInteraction.swift` 的类型注释（**注释必须跟着改**，否则下一个人按旧语义读）
- 实测数字 → `.ai/memory/baselines.md`（本卡没有性能主张，只有用例数与双壳结果）
- 踩到的坑 → `.ai/memory/pitfalls.md`
