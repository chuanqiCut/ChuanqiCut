# TASK-CORE-011：轨道静音写路径（`ChqSetTrackMutedCommand` + `cq_session_set_track_muted`）

> 由合并版问卷 **E1** 裁定立项（传哲 2026-10-17：「先补内核 muted ABI」——
> 不做假开关，也不接受"回弹观感可接受"这条退路）。关池 **[19]** 的"待决策"状态。
> **高冲突面**：本卡动 `engine/core/cq/cq_sdk.h`（红线：热点文件归集成机串行），
> 所以由本机发号并执行，开发机不得认领。

```yaml
id:          TASK-CORE-011
layer:       SDK
goal:        给"轨道静音"补一条可撤销的内核写路径，并让 Swift 侧与轨道适配层能穿透它
input:       [池[19] 全文, ADR-0034（不做假功能）, ADR-0042（内核唯一真源/灌入-回写方向）,
              现成范式 ChqSetCanvasCommand（chq_command.h:223 / chq_command.cpp:246）]
output:      [ChqTimeline::SetTrackMuted, ChqSetTrackMutedCommand, cq_session_set_track_muted,
              Swift Session.setTrackMuted + EditorViewModel.setTrackMuted,
              EditorTimelineKitView 的 .setTrackMuted 映射（去掉回滚）,
              单测（command/session/abi 三处）, docs/api/engine-api.md 重生成]
write_set:   engine/core/cq/cq_sdk.h、engine/core/cq/cq_sdk.cpp、
             engine/core/cq/model/chq_timeline.{h,cpp}、engine/core/cq/command/chq_command.{h,cpp}、
             engine/core/cq/session/chq_editor_session.{h,cpp}、
             tests/unit/command/test_model_command.cpp、tests/unit/session/、tests/unit/abi/test_c_abi.c、
             api/swift/Sources/ChuanqiCut/{Timeline,Session}.swift、
             ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/{AppEntry,UIKit/EditorTimelineKitView}.swift、
             docs/api/engine-api.md
read_set:    engine/core/cq/model/chq_editor_model_state.cpp、engine/core/cq/audio/chq_preview_mixer.cpp
             （两处消费 `muted`，本卡**不改**其行为，只确认写后能被它们读到）
deps:        []
blocked_by:  []
acceptance:
  - `cq_session_set_track_muted(session, track_id, muted)` 返回码：命中轨 0 / 未知 track_id 走
    `kInvalidArgument`（不静默成功）
  - **可撤销**：设置 → 撤销 → 回读 `CQTrackInfo.muted` 回到旧值；重做再回新值（进 CommandHistory，
    不是绕过 history 的裸写）
  - 消费侧**已经存在**（不是待建）：`engine/core/cq/audio/chq_preview_mixer.cpp:446`
    就是 `if (!track.enabled || track.muted) { ...跳过该轨... }`，`chq_editor_model_state.cpp:94`
    也按 `track.muted` 混。所以写路径一通，预览混音**理论上**立刻按轨静音 ——
    但本卡不宣称这一点为"已验证"，需要一条真机/单测口径（听感或取样能量）才能写进 baselines；
    卡面只保证"写得进去、撤销得了、读得回来"
  - 轨道适配层：`TimelineCommand.setTrackMuted` 从 `handle(command:)` 的 `default`（回滚）
    移到显式 `case`，**其余不可翻译命令仍一律回滚**（ADR-0042 不变）
  - 三处单测新增且通过；ctest 用例名不新增文件级漂移（52 例 → 53 例只允许在 command/session 内加断言，
    若新增用例需在卡面登记新数）
  - `gen_api_reference.py --check` 绿（符号 103 → 104，文档重生成）
  - 全量门禁 `run_gate.sh` PASS=18 / FAIL=0 / SKIP=0 + 双壳 BUILD SUCCEEDED
verification:
  - tools/build/build_core.sh --platform=apple --config=Debug --test
  - ctest --test-dir build -R "command|session|abi"  # 实为 ctest -R 正则，跑前按用例名核一次
  - "${PYTHON_BIN:-python3}" tools/docs/gen_api_reference.py   # 重生成，然后 --check 应绿
  - cd api/swift && swift build（+ 现有 bindings 用例 26 例）
  - tools/ci/run_gate.sh --fast
risk:        ① 动 `cq_sdk.h` = 全平台契约，Android/HarmonyOS 侧将来要同一签名 —— 命名与参数顺序
               现在就定死：`(session, uint64_t track_id, int32_t muted)`，`muted` 用 int32 承载 0/1
               （与 `cq_session_set_clip_effect_enabled` 的 bool→int32 口径一致），**不用 bool 过 C ABI**；
             ② 快照观察者：静音变更必须触发 `cq_session_set_observer` 的回灌，否则 iOS 轨道区
               显示旧态（`refreshFromKernel` 依赖它）；
             ③ 组件侧 `showsTrackHeader=false` 仍隐藏轨道头 → 本卡落地后 iOS 上**看不到** M 按钮，
               这是刻意的（见"射程边界"），不要为了"看得见"顺手把 header 打开——那会同时露出
               锁定与长按排序两个仍然假的开关。
parallel:    false
```

## 背景与现状取证（本机 2026-10-17 复核）

- 读路径在：`cq_sdk.cpp` 填 `out->muted = t.muted ? 1 : 0;`；模型侧 `ChqTrack::muted`
  默认 `false`（`chq_timeline.h:72`），消费方 `chq_editor_model_state.cpp:94`、
  `chq_preview_mixer.cpp:446`。
- 写路径**确实不存在**：全仓搜不到 `cq_session_set_track_muted`，也没有任何 Command 改 `ChqTrack::muted`。
- 时间线对象只暴露 const 访问器（`FindTrack` / `Tracks()`，`chq_timeline.h:83-84`）——
  所以要新增 `ChqStatus SetTrackMuted(uint64_t track_id, bool muted)`，与
  `SetCanvas`（`:119`）同形，而不是把 `tracks_` 开放成可写引用。
- **池 [19] 里有两处过期指针，本卡按实测订正**：
  1. 原写"UI 侧 disabled 只读态在 `TimelineContentView.buildTrackHeaders`"——该文件已随旧自绘
     轨道区在 UIA-044（`5cfcdcb`）删除。今天的落点是 `EditorTimelineKitView.swift:270`
     的 `showsTrackHeader: false`（整个轨道头不创建）。
  2. 原写"组件侧点按会回滚，需要组件加回调"——**组件早就有**：`TimelineStore` 有
     `.setTrackMuted(id:muted:)`（`Core/TimelineStore.swift:27/316`），`TimelineView.swift:614`
     与 `TimelineClipView.swift:257` 会发它。缺的只有内核。
     → **本卡零改仓库外的 TimelineKit**（池 [20] 的资产风险不被触发）。

## 实现要点（照 `SetCanvas` 那条链一比一拓）

1. `ChqTimeline::SetTrackMuted(track_id, muted)`：找不到轨返回 `kInvalidArgument`。
2. `ChqSetTrackMutedCommand`：`Do` 先捕获 `old_muted_` 再写，`Undo` 回写；`Name()` = `"set-track-muted"`。
   命令对象按值携带 `uint64_t + bool`，异步提交安全（无指针跨线程）。
3. `ChqEditorSession::SubmitSetTrackMuted(name, track_id, muted)` 走既有 `Submit(...)`，
   因此自动进 CommandHistory。
4. `cq_sdk.h` + `cq_sdk.cpp`：`int32_t cq_session_set_track_muted(CQSession*, uint64_t track_id, int32_t muted)`，
   紧挨 `cq_session_set_canvas`（`:216`）放，注释写清算 0/1 语义。
5. Swift：`Timeline.swift` 加 `setTrackMuted(trackId:muted:)`（与 `setCanvas`（`:195`）同段落），
   `AppEntry.swift` 的 `EditorViewModel` 加同名方法 → 触发 observer → `refreshFromKernel`。
6. 适配层 `EditorTimelineKitView.handle(command:)`：新增 `case .setTrackMuted`，
   把 Kit 的 `"cq-t-<id>"` 反解回 `track_id`（复用既有 ID 反解函数），调 VM，**然后交给既有的
   "提交后强制重灌"路径**，不要在 case 里自己 reload（会重建两遍，见该文件 417 行注释）。

## 射程边界（明确本卡不做）

- **轨道 `enabled` 的写路径**：池 [19] 第 4 条要求"同期评估"。本卡**只做 muted**，
  但取证订正一句：`ChqTrack` 的 `enabled`/`muted` 是**同一消费点**的两个独立布尔
  （`engine/core/cq/audio/chq_preview_mixer.cpp:446` = `if (!track.enabled || track.muted)`），
  所以补了 muted 之后 `enabled` 就是一比一拓的第二个命令，成本极低、且现在仍是"只能显示不能点"。
  ⚠️ 池 [19] 原文把它与"268 个效果开关"混谈了 —— 效果开关是 `ChqEffectBinding::enabled`
  （走 `cq_session_set_clip_effect_enabled`，`cq_sdk.h:268`），与轨道 enabled **不是一个东西**。
  是否同批补 `SetTrackEnabled` 由传哲一句话决定，不在本卡射程。
- **混音/导出是否真的跳过静音轨**：不改 `chq_preview_mixer.cpp`。写通之后，
  B4「导出不含静音轨」才有落点，那是导出线的卡。
- **iOS 轨道头重新显示**：等锁定/排序也补齐或组件支持"只显示 M"的粒度，另议。

## 回写

- `.ai/modules/core.md`（命令表新增一条 + 接口面）、`.ai/modules/session.md`、
  `.ai/modules/model.md`、`.ai/modules/bindings.md`、`.ai/modules/ui-apple.md`（适配层去回滚）、
  `docs/specs/AIEDIT-001` 无关；**池 [19] 关闭**（✅ + 门禁数字）；
  `docs/tasks/TASK-BACKLOG.md` §16 行状态；实测数字进 `.ai/memory/baselines.md`。
