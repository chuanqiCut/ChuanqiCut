# TASK-UIA-039：分割 / 删除 / 左缘裁剪接进轨道区（B1 收口，EDIT-007/008 的 UI 面）

- **状态**：✅ 编码 + 本机验证完成（2026-10-12）；未提交 → 本批已提交（见 HANDOFF-022）
- **写集**：`engine/bindings/swift/Sources/ChuanqiCut/Timeline.swift`、
  `apps/apple/packages/ChuanqiCutEditor/Sources/**`（7 文件）、
  `Tests/ChuanqiCutEditorTests/TimelineInteractionTests.swift`
- **依赖**：EDIT-007/008 ✅（内核 C ABI 已在 main）

## 范围（四命令 × 三入口面）

| 层 | 新增 |
|---|---|
| 绑定 | `Session.splitClip(clipId:at:)` / `trimClipIn(clipId:start:)` / `removeClip(clipId:)` / `removeTrack(trackId:)` |
| 纯逻辑 | `ClipHitRegion.trimStart`（左右缘各 8pt 手柄，窄片段 <2×手柄回退 move）+ `TimelineLayout.isStrictlyInside`（分割可用性，开区间，与内核同语义）+ `ClipDrag` trimStart 预览（右缘恒定不变式） |
| ViewModel | 选中态 `selectedClipId`（UI 本地态；applySnapshot / refreshFromKernel 双路径清失效）+ `canSplitSelected` + `splitSelectedAtPlayhead` / `deleteSelectedClip`（动作内含 refreshFromKernel）+ 四命令直通包装 |
| SwiftUI | Canvas 选中白描边（对标 App范式⑤）+ onTapGesture 点选 + commit 分支 trimStart→trimClipIn + 底栏分割/删除按钮（按可用性置灰） |
| UIKit | 工具栏同两按钮 + 时间线 UITapGestureRecognizer 点选 + 层描边 `setSelectedClip` + commitDrag trimStart 分支 + **零位移提交跳过**（点选不再给撤销栈塞同值垃圾命令；此前注释声称「内核拒绝」，实测同值变更返回 Ok，已在 UI 侧挡） |
| 测试 | +5：trimStart 命中区 / 窄片段回退 move / 右缘恒定夹取 / isStrictlyInside 开区间 / VM 端到端 split+delete 穿内核 |

## 关键语义决策

1. **分割靶子 = 播放头**（对标 App语义）：按钮可用性 = 选中片段严格包含播放头；分割后左半
   保留原 id，选中态自然延续。
2. **选中态不入内核**：纯 UI 状态，快照回流时片段消失即清除（删除/撤销两条路径都兜）。
3. **零位移不提交**：修掉「点按=同值 move 入撤销栈」的隐性污染（与文件头「无撤销污染」
   的既有意图对齐，实现从未兑现）。
4. **对标 App范式⑤的完整形态（选中态二级替换条）不在本卡**：本批以常驻位+置灰收口，
   交互语义（点选→动作）完整；替换条另立卡。

## 验证

- 改动前基线：Editor swift test **57/57 绿**（UIA-037/038 首验，池 [6] 第一项完成）
- 本卡验证（2026-10-12 本机实测）：
  - `build_core_apple.sh --config=Release` + `prepare.sh`：三切片 XCFramework 重建 ✅
    （`nm` 核 `cq_session_split_clip / trim_clip_in / remove_track` 3/3 在）
  - Editor `swift test`：**61/61 绿**（57 存量 + 4 新增；首跑抓出 trimStart 夹取缺陷——
    左缘拖过右缘时预览未锚住右缘，已修 `ClipDrag.previewStart` 上限夹取，防复发规则同 P119）
  - `xcodebuild -scheme ChuanqiCutEditor -sdk iphonesimulator build`：**BUILD SUCCEEDED**
    （UIKit 三件 `#if os(iOS)` 编译覆盖；构建图含 ChuanqiCutEditor/ChuanqiCutEngine 源码编译）
- iOS 模拟器**全壳**构建红（相机包 MetalFX，池 [16]），与本卡无关

## 剩余风险

- removeTrack 已绑定为 Session API 但 UI 无入口（多轨未做，删除轨道入口随多轨卡）。
- 左缘向左扩展（吃素材余量）内核会按 source_in<0 拒绝，UI 预览如实显示扩展后由
  refreshFromKernel 回真值 —— 手感待真机走查（池登记）。
- MetalFXScaler 使 iOS 模拟器全壳构建红（fdb4e97 起），阶段批门禁会挡 —— 归相机线修。
