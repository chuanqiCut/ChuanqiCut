# TASK-UIA-040：面板分级 + 画布 + 多轨操作（对标 App对齐第二批，RESEARCH-008/010 落地）

- **状态**：✅ 编码 + 本机验证完成（2026-10-12）；已提交
- **批次**：RESEARCH-008 范式①⑤（单焦点+抽屉 / 底部整体替换）+ RESEARCH-010 缺口清单
  的「比例/画布/背景」「多轨/画中画」两项；内核依赖 EDIT-007/008 ✅
- **写集**：`engine/core/cq/{model,command,session}` + `cq_sdk.*` + 三处内核测试、
  `engine/bindings/swift/Sources/ChuanqiCut/Timeline.swift`、
  `apps/apple/packages/ChuanqiCutEditor/**`（8 源文件 + 测试）

## 交付面（对照对标 App的三块）

### 1. 操作面板分级（RESEARCH-008 ①⑤，双端同语义）
- `EditorToolbarMode = primary / clipSelected / drawer(kind)`，单一真源 =
  `EditorViewModel.toolbarMode`（UI 状态）；UIKit/SwiftUI 两侧按模式**整条重建**。
- primary：撤销/重做 + 媒体/**画中画**/音频/文字/特效/**比例**（音频/文字/特效从
  「死置灰」升级为抽屉入口）。
- clipSelected：返回/分割/删除 + 音量/变速占位（MODEL-003 落地后接真）。
- drawer：音频（音乐/音效/录音/提取）、文字（新建文字/识别字幕/花字）、
  特效（画面/人物/滤镜）= 入口形状占位；**比例 = 真实能力**（9:16/16:9/1:1/4:3/3:4 →
  setCanvas）。关闭替换条 = 单焦点回落（有选中回选中条，否则回一级）。

### 2. 画布（内核 + UI 全链）
- 内核：`ChqTimeline` 画布属性（默认 1080×1920，取值 (0,8192]，指纹纳入）、
  `ChqSetCanvasCommand`（可撤销）、C ABI `cq_session_set_canvas / get_canvas`。
- 预览：VM 检测画布变化 → **渲染目标 resize**（长边 1280 按比例）——杜绝
  「16:9 目标里装 9:16 画布」的假适配；UIKit MTK 宽度钳「高×画布比」居中留黑边，
  SwiftUI 预览槽 `.aspectRatio`。预览即画布。

### 3. 多轨操作（内核 + UI 全链）
- 内核：`ChqTimeline::MoveClipToTrack`（id 不变；类型匹配 + 目标轨重叠校验 +
  同轨退化等价 MoveClip）、`ChqMoveClipToTrackCommand`、C ABI
  `cq_session_move_clip_to_track`。
- UI：一级「画中画」= addTrack（视频轨）；**跨轨拖拽**——`ClipDrag.dropTrackRow`
  纯函数（Δy 按行距取整夹取）、`rect(rowOverride:)` 只对被拖片段生效、双端手势
  Δy 驱动、提交走 moveClipToTrack（类型不匹配/重叠由内核拒绝 → 回真值）。

## 内核语义决策
1. 画布是**项目结构属性**，改动进撤销栈、指纹纳入（digest 驱动 UI 刷新与撤销判定）。
2. 跨轨移动**保 id**（历史里后续命令的引用不失效——与 Restore 系同一纪律）。
3. 跨轨到类型不匹配轨 = 内核拒绝（UI 不预判，诚实回真值）；画中画轨暂无独立
   混合语义（渲染合成归 RENDER-001/B0）。

## 验证（本机实测，2026-10-12）
| 命令 | 结果 |
|---|---|
| `build_core.sh --platform=apple` + 窄检 `ctest -R "model_timeline\|model_command\|c_abi_edit\|^c_abi$"` | ✅ 4/4（首跑抓出跨轨 moved 未带新起点——P119 同族第三击，candidate/moved 双变量又取错；已修） |
| `ctest` 全量 | ✅ **48/48** |
| `build_core_apple.sh --config=Release` + `prepare.sh` | ✅（绑定变更后重建） |
| Editor `swift test` | ✅ **65/65**（61 + 4 新增：落点行数学/rowOverride 语义/面板状态机/画布跨轨 e2e） |
| `xcodebuild -scheme ChuanqiCutEditor -sdk iphonesimulator build` | ✅ **BUILD SUCCEEDED** |

## 剩余风险与后续
- 音频/文字/特效抽屉是入口占位（B2/B6 批接真）；音量/变速挂 MODEL-003。
- 跨轨拖拽到**音频轨放视频片段**被内核拒绝后整条拖拽作废（含位移）——手感可优化为
  「只换轨失败保留位移」，登记后续。
- 背景占位未做（画布背景色/模糊 = 渲染能力，归 B0 后）。
- iOS 模拟器**全壳**构建仍被池 [16]（相机 MetalFX）挡，与本卡无关。
